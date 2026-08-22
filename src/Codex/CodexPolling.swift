import Foundation

struct CodexPollingDependencies {
    var isEnabled: Bool
    var appVersion: String
    var now: () -> Date
    var resolve: (String?) -> Result<CodexResolvedBinary, CodexFailure>
    var poll: (String, String, @escaping (Result<CodexUsageSnapshot, CodexFailure>) -> Void) -> Void
    // Runtime invalidates completions after sleep; live polling has no stronger cancellation primitive.
    var cancel: () -> Void = {}
    var probeQueue: DispatchQueue = DispatchQueue(label: "com.patrickfu.UsageInk.codex.probe", qos: .utility)

    static func disabled(now: @escaping () -> Date = Date.init) -> CodexPollingDependencies {
        CodexPollingDependencies(
            isEnabled: false,
            appVersion: "0.1.0",
            now: now,
            resolve: { _ in .failure(.binaryMissing) },
            poll: { _, _, _ in }
        )
    }

    static func live(queue: DispatchQueue) -> CodexPollingDependencies {
        let discovery = CodexDiscovery(
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"] ?? "",
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            runVersion: CodexVersionProbe.run(executable:)
        )
        let client = CodexAppServerClient(
            factory: ProcessCodexSessionFactory(),
            clock: DispatchCodexClock(queue: queue),
            queue: queue
        )
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return CodexPollingDependencies(
            isEnabled: true,
            appVersion: version,
            now: Date.init,
            resolve: { discovery.resolve(explicitPath: $0) },
            poll: { executable, appVersion, completion in
                client.poll(executable: executable, appVersion: appVersion, completion: completion)
            }
        )
    }
}

final class DispatchCodexClock: CodexScheduling {
    private let queue: DispatchQueue
    private var workItems: [String: DispatchWorkItem] = [:]
    private let lock = NSLock()

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var now: TimeInterval {
        Date().timeIntervalSince1970
    }

    func schedule(id: String, after: TimeInterval, _ body: @escaping () -> Void) {
        let item = DispatchWorkItem(block: body)
        lock.lock()
        workItems[id]?.cancel()
        workItems[id] = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + after, execute: item)
    }

    func cancel(id: String) {
        lock.lock()
        workItems[id]?.cancel()
        workItems[id] = nil
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        for item in workItems.values {
            item.cancel()
        }
        workItems.removeAll()
        lock.unlock()
    }
}
