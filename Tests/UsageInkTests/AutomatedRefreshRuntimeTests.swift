import XCTest
@testable import UsageInk

final class AutomatedRefreshRuntimeTests: XCTestCase {
    func testPollCadenceUsesPriorStartAndWakeRunsOneCatchUp() throws {
        let clock = ManualDisplayClock(origin: Date(timeIntervalSince1970: 1_700_000_000))
        let counter = PollCounter()
        let runtime = try makeRuntime(clock: clock, counter: counter)

        runtime.start()
        waitUntil { counter.value == 1 }

        clock.advance(14 * 60 + 59)
        settle()
        XCTAssertEqual(counter.value, 1)
        clock.advance(1)
        waitUntil { counter.value == 2 }

        runtime.submit(.hostWillSleep)
        settle()
        clock.advance(45 * 60)
        settle()
        XCTAssertEqual(counter.value, 2)

        runtime.submit(.hostDidWake)
        waitUntil { counter.value == 3 }
        settle()
        XCTAssertEqual(counter.value, 3)
    }

    func testManualClickResetsScheduledDeadlineWithoutAnExtraPoll() throws {
        let clock = ManualDisplayClock(origin: Date(timeIntervalSince1970: 1_700_000_000))
        let counter = PollCounter()
        let runtime = try makeRuntime(clock: clock, counter: counter)

        runtime.start()
        waitUntil { counter.value == 1 }
        clock.advance(14 * 60 + 59)
        runtime.submit(.refreshNow)
        waitUntil { counter.value == 2 }

        clock.advance(14 * 60 + 59)
        settle()
        XCTAssertEqual(counter.value, 2)
        clock.advance(1)
        waitUntil { counter.value == 3 }
    }

    private func makeRuntime(clock: ManualDisplayClock, counter: PollCounter) throws -> UsageInkRuntime {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageink-automated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return UsageInkRuntime(
            language: .english,
            store: PersistenceStore(root: root),
            now: { clock.date },
            clock: clock,
            makeCodex: { _ in
                CodexPollingDependencies(
                    isEnabled: true,
                    appVersion: "0.1.0",
                    now: { clock.date },
                    resolve: { _ in .success(CodexResolvedBinary(path: "/tmp/fake-codex", version: .minimum)) },
                    poll: { _, _, completion in
                        counter.increment()
                        completion(.success(CodexUsageSnapshot(planType: "pro", windows: [])))
                    }
                )
            }
        ) { _ in }
    }

    private func waitUntil(
        _ file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("condition not met", file: file, line: line)
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }
}

private final class PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
