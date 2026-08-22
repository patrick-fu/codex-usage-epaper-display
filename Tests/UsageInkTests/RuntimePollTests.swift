import XCTest
@testable import UsageInk

final class RuntimePollTests: XCTestCase {
    func testRefreshPublishesDynamicWindowsAndRetainsLastValidOnFailure() throws {
        let factory = ScriptedCodexFactory()
        let clock = ManualCodexClock()
        let queue = DispatchQueue(label: "test.runtime.poll")
        let client = CodexAppServerClient(factory: factory, clock: clock, jitter: { 1 }, queue: queue)
        var windowPayloads = [oneWindowResult(), twoWindowResult()]
        factory.next = {
            let session = ScriptedCodexSession()
            session.onSend = { object in
                if object["method"] as? String == "initialize" {
                    session.respondJSON(jsonRPCResult(id: 1, result: initializeResult()))
                } else if object["method"] as? String == "account/read" {
                    let payload = windowPayloads.isEmpty ? oneWindowResult() : windowPayloads.removeFirst()
                    session.respondJSON(jsonRPCResult(id: 2, result: proAccountResult()))
                    session.respondJSON(jsonRPCResult(id: 3, result: payload))
                }
            }
            return session
        }

        let root = try makeRoot()
        let box = PollSnapshotBox()
        let runtime = UsageInkRuntime(
            language: .english,
            store: PersistenceStore(root: root),
            makeCodex: { _ in
                CodexPollingDependencies(
                    isEnabled: true,
                    appVersion: "0.1.0",
                    now: { Date(timeIntervalSince1970: 1_700_000_000) },
                    resolve: { _ in
                        .success(CodexResolvedBinary(path: "/tmp/fake-codex", version: .minimum))
                    },
                    poll: { executable, version, completion in
                        XCTAssertEqual(executable, "/tmp/fake-codex")
                        client.poll(executable: executable, appVersion: version, completion: completion)
                    }
                )
            }
        ) { snapshot in
            box.consume(snapshot)
        }

        let first = box.expect("one window") { $0.account.windows.count == 1 && $0.account.availability == .fresh }
        runtime.start()
        wait(for: [first], timeout: 1.0)
        XCTAssertEqual(box.snapshot?.statusSummary, "— · Local activity unknown")
        XCTAssertEqual(box.snapshot?.account.planType, "pro")
        XCTAssertEqual(box.snapshot?.account.windows.first?.windowDurationMins, 10080)
        try assertFrame(from: box.snapshot, expectedWindows: 1)

        let second = box.expect("two windows") { $0.account.windows.count == 2 }
        runtime.submit(.refreshNow)
        wait(for: [second], timeout: 1.0)
        try assertFrame(from: box.snapshot, expectedWindows: 2)

        factory.next = {
            let session = ScriptedCodexSession()
            session.onSend = { object in
                if object["method"] as? String == "initialize" {
                    session.respondJSON(jsonRPCResult(id: 1, result: initializeResult()))
                } else if object["method"] as? String == "account/read" {
                    session.respondJSON(jsonRPCError(id: 2, code: -32603))
                    session.respondJSON(jsonRPCResult(id: 3, result: oneWindowResult()))
                }
            }
            return session
        }
        let failed = box.expect("retain") {
            $0.account.failure == "unknown" && $0.account.windows.count == 2
        }
        runtime.submit(.refreshNow)
        wait(for: [failed], timeout: 1.0)
        XCTAssertEqual(box.snapshot?.account.availability, .unavailable)
        XCTAssertEqual(box.snapshot?.account.planType, "pro")
        XCTAssertEqual(box.snapshot?.account.windows.count, 2)
        try assertFrame(from: box.snapshot, expectedWindows: 2)
        let json = try String(contentsOf: root.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("user@example.com"))
        XCTAssertFalse(json.contains("codexHome"))
        XCTAssertFalse(json.contains("/tmp/does-not-get-recorded"))
        XCTAssertFalse(json.contains("chatgpt"))
    }

    func testAuthRequiredAndMissingBinaryDegradeMenuAndFrameWithoutZeroPercent() throws {
        let factory = ScriptedCodexFactory()
        let queue = DispatchQueue(label: "test.runtime.degraded")
        let client = CodexAppServerClient(factory: factory, clock: ManualCodexClock(), jitter: { 1 }, queue: queue)
        factory.next = {
            let session = ScriptedCodexSession()
            session.onSend = { object in
                if object["method"] as? String == "initialize" {
                    session.respondJSON(jsonRPCResult(id: 1, result: initializeResult()))
                } else if object["method"] as? String == "account/read" {
                    session.respondJSON(jsonRPCResult(id: 2, result: [
                        "account": NSNull(),
                        "requiresOpenaiAuth": true,
                    ]))
                    session.respondJSON(jsonRPCResult(id: 3, result: oneWindowResult()))
                }
            }
            return session
        }

        let box = PollSnapshotBox()
        let runtime = UsageInkRuntime(
            language: .english,
            store: PersistenceStore(root: try makeRoot()),
            makeCodex: { _ in
                CodexPollingDependencies(
                    isEnabled: true,
                    appVersion: "0.1.0",
                    now: Date.init,
                    resolve: { _ in
                        .success(CodexResolvedBinary(path: "/tmp/fake-codex", version: .minimum))
                    },
                    poll: { executable, version, completion in
                        client.poll(executable: executable, appVersion: version, completion: completion)
                    }
                )
            }
        ) { snapshot in
            box.consume(snapshot)
        }
        let signedOut = box.expect("auth") { $0.account.failure == "authRequired" }
        runtime.start()
        wait(for: [signedOut], timeout: 1.0)
        XCTAssertEqual(box.snapshot?.statusSummary, "Sign in to Codex · Local activity unknown")
        let menu = MenuBuilder.items(from: try XCTUnwrap(box.snapshot))
        XCTAssertEqual(menu[0].title, "Sign in to Codex · Local activity unknown")
        let authInput = DisplayFrameInput(
            preferences: quotaOnlyPreferences(),
            account: try XCTUnwrap(box.snapshot?.account),
            localActivity: .unknown,
            composedAt: Date(timeIntervalSince1970: 1_704_067_200),
            calendar: DisplayFrameFixtures.calendar,
            timeZone: DisplayFrameFixtures.timeZone,
            preferredLanguages: ["en-US"]
        )
        let frame = try DisplayFrameComposer.compose(authInput)
        XCTAssertEqual(QuotaFocusModelBuilder.build(authInput).unavailableMark, DisplayCopy.emDash)
        XCTAssertEqual(frame.blackPlane.count, 15_000)
        _ = frame

        let missingBox = PollSnapshotBox()
        let missing = UsageInkRuntime(
            language: .english,
            store: PersistenceStore(root: try makeRoot()),
            makeCodex: { _ in
                CodexPollingDependencies(
                    isEnabled: true,
                    appVersion: "0.1.0",
                    now: Date.init,
                    resolve: { _ in .failure(.binaryMissing) },
                    poll: { _, _, _ in
                        XCTFail("must not launch a process when discovery fails")
                    }
                )
            }
        ) { snapshot in
            missingBox.consume(snapshot)
        }
        let notFound = missingBox.expect("missing") { $0.account.failure == "binaryMissing" }
        missing.start()
        wait(for: [notFound], timeout: 1.0)
        XCTAssertEqual(missingBox.snapshot?.statusSummary, "Codex not found · Local activity unknown")
        XCTAssertEqual(missingBox.snapshot?.account.windows, [])
        let missingModel = QuotaFocusModelBuilder.build(
            DisplayFrameInput(
                preferences: quotaOnlyPreferences(),
                account: try XCTUnwrap(missingBox.snapshot?.account),
                localActivity: .unknown,
                composedAt: Date(timeIntervalSince1970: 1_704_067_200),
                calendar: DisplayFrameFixtures.calendar,
                timeZone: DisplayFrameFixtures.timeZone,
                preferredLanguages: ["en-US"]
            )
        )
        XCTAssertEqual(missingModel.unavailableMark, DisplayCopy.emDash)
        XCTAssertNotEqual(missingModel.hero?.displayedValue, "0%")
    }

    func testVersionProbeDoesNotBlockRuntimeOwnerQueue() throws {
        let probeQueue = DispatchQueue(label: "test.codex.probe")
        let gate = DispatchSemaphore(value: 0)
        let enteredProbe = expectation(description: "probe")
        let box = PollSnapshotBox()
        let runtime = UsageInkRuntime(
            language: .english,
            store: PersistenceStore(root: try makeRoot()),
            makeCodex: { ownerQueue in
                XCTAssertEqual(ownerQueue.label, UsageInkRuntime.queueLabel)
                return CodexPollingDependencies(
                    isEnabled: true,
                    appVersion: "0.1.0",
                    now: Date.init,
                    resolve: { _ in
                        XCTAssertNotEqual(
                            String(cString: __dispatch_queue_get_label(nil)),
                            UsageInkRuntime.queueLabel
                        )
                        enteredProbe.fulfill()
                        gate.wait()
                        return .failure(.binaryMissing)
                    },
                    poll: { _, _, _ in
                        XCTFail("poll must wait for the worker probe")
                    },
                    probeQueue: probeQueue
                )
            }
        ) { snapshot in
            box.consume(snapshot)
        }
        runtime.start()
        wait(for: [enteredProbe], timeout: 1.0)
        let styleChanged = box.expect("style") { $0.displayStyle == .balanced }
        runtime.submit(.setDisplayStyle(.balanced))
        wait(for: [styleChanged], timeout: 1.0)
        XCTAssertEqual(box.snapshot?.displayStyle, .balanced)
        let missing = box.expect("missing") { $0.account.failure == "binaryMissing" }
        gate.signal()
        wait(for: [missing], timeout: 1.0)
        XCTAssertEqual(box.snapshot?.statusSummary, "Codex not found · Local activity unknown")
    }

    func testManualRefreshJoinsInFlightPollInsteadOfStartingASecondProcess() throws {
        let factory = ScriptedCodexFactory()
        let queue = DispatchQueue(label: "test.runtime.join")
        let client = CodexAppServerClient(factory: factory, clock: ManualCodexClock(), jitter: { 1 }, queue: queue)
        let gate = DispatchSemaphore(value: 0)
        factory.next = {
            let session = ScriptedCodexSession()
            session.onSend = { object in
                if object["method"] as? String == "initialize" {
                    session.respondJSON(jsonRPCResult(id: 1, result: initializeResult()))
                } else if object["method"] as? String == "account/read" {
                    gate.wait()
                    session.respondJSON(jsonRPCResult(id: 2, result: proAccountResult()))
                    session.respondJSON(jsonRPCResult(id: 3, result: oneWindowResult()))
                }
            }
            return session
        }
        let box = PollSnapshotBox()
        let runtime = UsageInkRuntime(
            language: .english,
            store: PersistenceStore(root: try makeRoot()),
            makeCodex: { _ in
                CodexPollingDependencies(
                    isEnabled: true,
                    appVersion: "0.1.0",
                    now: Date.init,
                    resolve: { _ in
                        .success(CodexResolvedBinary(path: "/tmp/fake-codex", version: .minimum))
                    },
                    poll: { executable, version, completion in
                        client.poll(executable: executable, appVersion: version, completion: completion)
                    }
                )
            }
        ) { snapshot in
            box.consume(snapshot)
        }
        runtime.start()
        runtime.submit(.refreshNow)
        runtime.submit(.refreshNow)
        gate.signal()
        let done = box.expect("joined") { $0.account.availability == .fresh }
        wait(for: [done], timeout: 1.0)
        XCTAssertEqual(factory.sessions.count, 1)
    }

    private func quotaOnlyPreferences() -> DisplayPreferences {
        var preferences = DisplayPreferences.default
        preferences.modules.today = false
        preferences.modules.weekTokens = false
        preferences.modules.cache = false
        preferences.modules.tps = false
        return preferences
    }

    private func assertFrame(from snapshot: RuntimeSnapshot?, expectedWindows: Int) throws {
        let snapshot = try XCTUnwrap(snapshot)
        XCTAssertEqual(snapshot.account.windows.count, expectedWindows)
        let input = DisplayFrameInput(
            preferences: snapshot.preferences,
            account: snapshot.account,
            localActivity: .unknown,
            composedAt: Date(timeIntervalSince1970: 1_704_067_200),
            calendar: DisplayFrameFixtures.calendar,
            timeZone: DisplayFrameFixtures.timeZone,
            preferredLanguages: ["en-US"]
        )
        let model = QuotaFocusModelBuilder.build(input)
        if expectedWindows == 0 {
            XCTAssertEqual(model.unavailableMark, DisplayCopy.emDash)
        } else {
            XCTAssertNotNil(model.hero)
            XCTAssertNotEqual(model.hero?.displayedValue, "0%")
        }
        _ = try DisplayFrameComposer.compose(input)
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageink-poll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private final class PollSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: RuntimeSnapshot?
    private var pending: (XCTestExpectation, (RuntimeSnapshot) -> Bool)?

    var snapshot: RuntimeSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return _snapshot
    }

    func expect(_ name: String, _ matcher: @escaping (RuntimeSnapshot) -> Bool) -> XCTestExpectation {
        let exp = XCTestExpectation(description: name)
        lock.lock()
        pending = (exp, matcher)
        let current = _snapshot
        lock.unlock()
        if let current, matcher(current) {
            exp.fulfill()
        }
        return exp
    }

    func consume(_ snapshot: RuntimeSnapshot) {
        lock.lock()
        _snapshot = snapshot
        let pending = self.pending
        lock.unlock()
        if let pending, pending.1(snapshot) {
            pending.0.fulfill()
        }
    }
}
