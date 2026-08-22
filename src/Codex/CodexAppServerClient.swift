import Foundation

struct CodexUsageSnapshot: Sendable, Equatable {
    var planType: String?
    var windows: [UsageWindowObservation]
}

protocol CodexScheduling: AnyObject {
    var now: TimeInterval { get }
    func schedule(id: String, after: TimeInterval, _ body: @escaping () -> Void)
    func cancel(id: String)
    func cancelAll()
}

protocol CodexStdioSession: AnyObject {
    var outputHandler: ((Data) -> Void)? { get set }
    var exitHandler: ((Int32) -> Void)? { get set }
    func start() throws
    func send(_ data: Data)
    func closeInput()
    func abort()
}

protocol CodexSessionFactory {
    func openAppServer(executable: String) throws -> CodexStdioSession
}

final class CodexAppServerClient {
    static let initializeTimeout: TimeInterval = 5
    static let readTimeout: TimeInterval = 10
    static let overloadWindow: TimeInterval = 30
    static let maxOverloadRetries = 3

    private let factory: CodexSessionFactory
    private let clock: CodexScheduling
    private let jitter: @Sendable () -> Double
    private let queue: DispatchQueue
    private static let queueKey = DispatchSpecificKey<UInt8>()

    init(
        factory: CodexSessionFactory,
        clock: CodexScheduling,
        jitter: @escaping @Sendable () -> Double = { 1 },
        queue: DispatchQueue
    ) {
        self.factory = factory
        self.clock = clock
        self.jitter = jitter
        self.queue = queue
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    func poll(
        executable: String,
        appVersion: String,
        completion: @escaping (Result<CodexUsageSnapshot, CodexFailure>) -> Void
    ) {
        queue.async { [self] in
            Attempt(
                factory: factory,
                clock: clock,
                jitter: jitter,
                queue: queue,
                executable: executable,
                appVersion: appVersion,
                completion: completion
            ).start(ordinaryRetryRemaining: true)
        }
    }

    private final class Attempt {
        let factory: CodexSessionFactory
        let clock: CodexScheduling
        let jitter: @Sendable () -> Double
        let queue: DispatchQueue
        let executable: String
        let appVersion: String
        let completion: (Result<CodexUsageSnapshot, CodexFailure>) -> Void

        private var session: CodexStdioSession?
        private var framer = CodexJSONLFramer()
        private var finished = false
        private var closedInput = false
        private var sentInitialized = false
        private var accountResult: Any?
        private var accountFailure: CodexFailure?
        private var rateLimitsResult: Any?
        private var rateLimitsFailure: CodexFailure?
        private var overloadRetries = 0
        private var pollStartedAt: TimeInterval = 0
        private var hangingMethod: String?
        private var ordinaryRetryRemaining = false

        init(
            factory: CodexSessionFactory,
            clock: CodexScheduling,
            jitter: @escaping @Sendable () -> Double,
            queue: DispatchQueue,
            executable: String,
            appVersion: String,
            completion: @escaping (Result<CodexUsageSnapshot, CodexFailure>) -> Void
        ) {
            self.factory = factory
            self.clock = clock
            self.jitter = jitter
            self.queue = queue
            self.executable = executable
            self.appVersion = appVersion
            self.completion = completion
        }

        func start(ordinaryRetryRemaining: Bool) {
            self.ordinaryRetryRemaining = ordinaryRetryRemaining
            pollStartedAt = clock.now
            do {
                let session = try factory.openAppServer(executable: executable)
                self.session = session
                session.outputHandler = { [self] data in
                    let run = { self.ingest(data) }
                    if DispatchQueue.getSpecific(key: CodexAppServerClient.queueKey) != nil {
                        run()
                    } else {
                        self.queue.async(execute: run)
                    }
                }
                session.exitHandler = { [self] status in
                    let run = { self.handleExit(status) }
                    if DispatchQueue.getSpecific(key: CodexAppServerClient.queueKey) != nil {
                        run()
                    } else {
                        self.queue.async(execute: run)
                    }
                }
                try session.start()
            } catch {
                finishOrdinary(.failure(.transportStart))
                return
            }
            sendInitialize()
        }

        private func sendInitialize() {
            let payload: [String: Any] = [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "usageink",
                        "title": "UsageInk",
                        "version": appVersion,
                    ]
                ],
            ]
            sendJSON(payload)
            hangingMethod = "initialize"
            clock.schedule(id: "initialize", after: CodexAppServerClient.initializeTimeout) { [self] in
                self.failCurrent(.timeout)
            }
        }

        private func sendReads() {
            sendJSON([
                "method": "account/read",
                "id": 2,
                "params": [
                    "refreshToken": false,
                ],
            ])
            sendJSON([
                "method": "account/rateLimits/read",
                "id": 3,
            ])
            hangingMethod = "reads"
            clock.schedule(id: "account", after: CodexAppServerClient.readTimeout) { [self] in
                self.failRead(isAccount: true, .timeout)
            }
            clock.schedule(id: "rateLimits", after: CodexAppServerClient.readTimeout) { [self] in
                self.failRead(isAccount: false, .timeout)
            }
        }

        private func ingest(_ data: Data) {
            guard !finished else {
                return
            }
            for event in framer.ingest(data) {
                switch event {
                case .invalidJSON:
                    failCurrent(.invalidJSON)
                    return
                case .schemaInvalid:
                    failCurrent(.schemaInvalid)
                    return
                case .line(let line):
                    handleLine(line)
                    if finished {
                        return
                    }
                }
            }
        }

        private func handleLine(_ line: Data) {
            guard !line.isEmpty else {
                return
            }
            let json: Any
            do {
                json = try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])
            } catch {
                failCurrent(.invalidJSON)
                return
            }
            guard let object = json as? [String: Any] else {
                failCurrent(.invalidJSON)
                return
            }
            if let method = object["method"] as? String, object["id"] == nil {
                if method == "account/rateLimits/updated" {
                    return
                }
                return
            }
            guard let id = jsonInt(object["id"]) else {
                failCurrent(.schemaInvalid)
                return
            }
            if let error = object["error"] as? [String: Any] {
                handleRPCError(id: id, error: error)
                return
            }
            guard object.keys.contains("result") else {
                failCurrent(.schemaInvalid)
                return
            }
            handleResult(id: id, result: object["result"] as Any)
        }

        private func handleResult(id: Int, result: Any) {
            switch id {
            case 1:
                clock.cancel(id: "initialize")
                hangingMethod = nil
                switch validateInitialize(result) {
                case .failure(let failure):
                    failCurrent(failure)
                case .success:
                    if !sentInitialized {
                        sentInitialized = true
                        sendJSON([
                            "method": "initialized",
                            "params": [String: Any](),
                        ])
                        sendReads()
                    }
                }
            case 2:
                clock.cancel(id: "account")
                accountResult = result
                accountFailure = nil
                if let failure = validateAccountResult(result) {
                    accountFailure = failure
                }
                publishIfTerminal()
            case 3:
                clock.cancel(id: "rateLimits")
                rateLimitsResult = result
                rateLimitsFailure = nil
                if case .failure(let failure) = CodexUsageNormalizer.windows(from: result) {
                    rateLimitsFailure = failure
                }
                publishIfTerminal()
            default:
                break
            }
        }

        private func handleRPCError(id: Int, error: [String: Any]) {
            let failure = classifyRPCError(error)
            if failure == .overloaded {
                retryOverload(id: id)
                return
            }
            switch id {
            case 1:
                clock.cancel(id: "initialize")
                failCurrent(failure)
            case 2:
                clock.cancel(id: "account")
                accountFailure = failure
                accountResult = NSNull()
                publishIfTerminal()
            case 3:
                clock.cancel(id: "rateLimits")
                rateLimitsFailure = failure
                rateLimitsResult = NSNull()
                publishIfTerminal()
            default:
                break
            }
        }

        private func retryOverload(id: Int) {
            switch id {
            case 1:
                clock.cancel(id: "initialize")
            case 2:
                clock.cancel(id: "account")
            case 3:
                clock.cancel(id: "rateLimits")
            default:
                break
            }
            guard overloadRetries < CodexAppServerClient.maxOverloadRetries else {
                failCurrent(.overloaded)
                return
            }
            let elapsed = clock.now - pollStartedAt
            guard elapsed < CodexAppServerClient.overloadWindow else {
                failCurrent(.overloaded)
                return
            }
            overloadRetries += 1
            let delay = overloadDelay(retry: overloadRetries)
            if elapsed + delay >= CodexAppServerClient.overloadWindow {
                failCurrent(.overloaded)
                return
            }
            clock.schedule(id: "overload-\(id)-\(overloadRetries)", after: delay) { [self] in
                self.resend(id: id)
            }
        }

        private func overloadDelay(retry: Int) -> TimeInterval {
            let factor = 0.5 + 0.5 * min(max(jitter(), 0), 1)
            return pow(2.0, Double(retry - 1)) * 0.5 * factor
        }

        private func resend(id: Int) {
            guard !finished else {
                return
            }
            switch id {
            case 1:
                sendInitialize()
            case 2:
                sendJSON([
                    "method": "account/read",
                    "id": 2,
                    "params": [
                        "refreshToken": false,
                    ],
                ])
                clock.schedule(id: "account", after: CodexAppServerClient.readTimeout) { [self] in
                    self.failRead(isAccount: true, .timeout)
                }
            case 3:
                sendJSON([
                    "method": "account/rateLimits/read",
                    "id": 3,
                ])
                clock.schedule(id: "rateLimits", after: CodexAppServerClient.readTimeout) { [self] in
                    self.failRead(isAccount: false, .timeout)
                }
            default:
                break
            }
        }

        private func validateInitialize(_ result: Any) -> Result<Void, CodexFailure> {
            guard let object = result as? [String: Any] else {
                return .failure(.schemaInvalid)
            }
            for key in ["userAgent", "codexHome", "platformFamily", "platformOs"] {
                guard object[key] is String else {
                    return .failure(.schemaInvalid)
                }
            }
            return .success(())
        }

        private func validateAccountResult(_ result: Any) -> CodexFailure? {
            switch CodexUsageNormalizer.account(from: result) {
            case .failure(let failure):
                return failure
            case .success:
                return nil
            }
        }

        private func publishIfTerminal() {
            let accountTerminal = accountResult != nil || accountFailure != nil
            let rateTerminal = rateLimitsResult != nil || rateLimitsFailure != nil
            guard accountTerminal && rateTerminal else {
                return
            }
            if let accountFailure, accountFailure == .authRequired {
                finishCurrent(.failure(.authRequired))
                return
            }
            if let accountFailure {
                finishCurrent(.failure(accountFailure))
                return
            }
            if let rateLimitsFailure {
                finishCurrent(.failure(rateLimitsFailure))
                return
            }
            guard let accountResult else {
                finishCurrent(.failure(.unknown))
                return
            }
            switch CodexUsageNormalizer.account(from: accountResult) {
            case .failure(let failure):
                finishCurrent(.failure(failure))
            case .success(let account):
                switch CodexUsageNormalizer.windows(from: rateLimitsResult as Any) {
                case .failure(let failure):
                    finishCurrent(.failure(failure))
                case .success(let windows):
                    finishCurrent(.success(CodexUsageSnapshot(planType: account.planType, windows: windows)))
                }
            }
        }

        private func failRead(isAccount: Bool, _ failure: CodexFailure) {
            guard !finished else {
                return
            }
            if isAccount {
                clock.cancel(id: "account")
                accountFailure = failure
                accountResult = NSNull()
            } else {
                clock.cancel(id: "rateLimits")
                rateLimitsFailure = failure
                rateLimitsResult = NSNull()
            }
            if failure == .timeout && (accountFailure == .timeout || rateLimitsFailure == .timeout) {
                // Keep waiting for the other read unless both are terminal.
            }
            publishIfTerminal()
            if accountFailure == .timeout || rateLimitsFailure == .timeout {
                if (accountResult != nil || accountFailure != nil) && (rateLimitsResult != nil || rateLimitsFailure != nil) {
                    return
                }
            }
        }

        private func failCurrent(_ failure: CodexFailure) {
            finishOrdinary(.failure(failure))
        }

        private func handleExit(_ status: Int32) {
            guard !finished else {
                return
            }
            if closedInput {
                return
            }
            finishOrdinary(.failure(.transportExit))
        }

        private func finishOrdinary(_ result: Result<CodexUsageSnapshot, CodexFailure>) {
            if case .failure(let failure) = result,
               ordinaryRetryRemaining,
               Self.ordinaryRetryable.contains(failure) {
                ordinaryRetryRemaining = false
                tearDown(abort: true)
                resetSessionState()
                start(ordinaryRetryRemaining: false)
                return
            }
            finishCurrent(result)
        }

        private static let ordinaryRetryable: Set<CodexFailure> = [
            .transportStart, .transportExit, .invalidJSON, .timeout,
        ]

        private func finishCurrent(_ result: Result<CodexUsageSnapshot, CodexFailure>) {
            guard !finished else {
                return
            }
            finished = true
            clock.cancelAll()
            if case .success = result {
                closedInput = true
                session?.closeInput()
            } else {
                session?.abort()
            }
            session?.outputHandler = nil
            session?.exitHandler = nil
            session = nil
            completion(result)
        }

        private func tearDown(abort: Bool) {
            clock.cancelAll()
            if abort {
                session?.abort()
            } else {
                session?.closeInput()
            }
            session?.outputHandler = nil
            session?.exitHandler = nil
            session = nil
        }

        private func resetSessionState() {
            framer = CodexJSONLFramer()
            finished = false
            closedInput = false
            sentInitialized = false
            accountResult = nil
            accountFailure = nil
            rateLimitsResult = nil
            rateLimitsFailure = nil
            overloadRetries = 0
            hangingMethod = nil
        }

        private func sendJSON(_ object: [String: Any]) {
            guard let session, let data = try? JSONSerialization.data(withJSONObject: object) else {
                failCurrent(.unknown)
                return
            }
            var line = data
            line.append(0x0a)
            session.send(line)
        }
    }
}

private func jsonInt(_ raw: Any?) -> Int? {
    if let int = raw as? Int {
        return int
    }
    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        return nil
    }
    return number.intValue
}

private func classifyRPCError(_ error: [String: Any]) -> CodexFailure {
    if let code = jsonInt(error["code"]) {
        if code == -32001 {
            return .overloaded
        }
        if code == -32600 || code == -32601 || code == -32602 {
            return .protocolIncompatible
        }
        if code == -32700 {
            return .invalidJSON
        }
    }
    if let status = extractHTTPStatus(error["data"]) {
        if status == 401 {
            return .backendUnauthorized
        }
        if status == 403 {
            return .backendForbidden
        }
    }
    return .unknown
}

private func extractHTTPStatus(_ raw: Any?) -> Int? {
    guard let raw else {
        return nil
    }
    if let number = jsonInt(raw) {
        return number
    }
    guard let object = raw as? [String: Any] else {
        if let array = raw as? [Any] {
            for item in array {
                if let status = extractHTTPStatus(item) {
                    return status
                }
            }
        }
        return nil
    }
    for key in ["httpStatusCode", "httpStatus", "status"] {
        if let status = jsonInt(object[key]) {
            return status
        }
    }
    if let type = object["type"] as? String, type == "unauthorized" || type == "Unauthorized" {
        return 401
    }
    for value in object.values {
        if let status = extractHTTPStatus(value) {
            return status
        }
    }
    return nil
}
