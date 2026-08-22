import XCTest
@testable import UsageInk

final class AutomatedRefreshRuntimeTests: XCTestCase {
    private let desk = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

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

    func testIndependentStaleCrossingPollsOnceAndKeepsOtherSourceFresh() throws {
        let controller = AutomatedPollController()
        let harness = try AutomatedRefreshHarness(controller: controller, accountAge: 19 * 60, localEnabled: false)
        startAndAssumePanel(harness)
        let baselineWrites = refreshWrites(harness.radio).count

        controller.pause()
        harness.clock.advance(42)
        settle()
        XCTAssertEqual(controller.starts, 0)
        XCTAssertEqual(harness.box.snapshot?.account.availability, .fresh)
        XCTAssertEqual(harness.box.snapshot?.localActivity.availability, .fresh)
        harness.clock.advance(1)
        waitUntil { controller.starts == 1 }
        waitUntil { harness.box.snapshot?.account.availability == .stale }
        XCTAssertEqual(harness.box.snapshot?.localActivity.availability, .fresh)
        XCTAssertEqual(refreshWrites(harness.radio).count, baselineWrites)

        controller.completeNext(.success(AutomatedPollController.snapshot(percent: 13)))
        waitUntil { self.refreshWrites(harness.radio).count == baselineWrites + 1 }
        harness.clock.advance(15)
        waitUntil { harness.box.snapshot?.panelTrust == .assumed }
        let pollsAfterCrossing = controller.starts
        let writesAfterCrossing = refreshWrites(harness.radio).count
        harness.clock.advance(5 * 60)
        settle()
        XCTAssertEqual(controller.starts, pollsAfterCrossing)
        XCTAssertEqual(refreshWrites(harness.radio).count, writesAfterCrossing)
        XCTAssertEqual(harness.box.snapshot?.localActivity.availability, .fresh)
        XCTAssertNotEqual(harness.box.snapshot?.account.availability, .unknown)
    }

    func testAutomaticIdenticalFrameSkipsButInvalidTrustForcesFullTransfer() throws {
        let controller = AutomatedPollController()
        let harness = try AutomatedRefreshHarness(controller: controller, localEnabled: false)
        startAndAssumePanel(harness)
        harness.runtime.submit(.refreshNow)
        waitUntil { controller.starts == 1 }
        waitUntil { self.refreshWrites(harness.radio).count == 2 }
        harness.clock.advance(15)
        waitUntil { self.loadedState(harness).refreshRecord.lastSuccessfulRefreshAt == Int(harness.clock.date.timeIntervalSince1970) }
        let record = loadedState(harness).refreshRecord
        let writesAfterSuccess = harness.radio.writes.count

        harness.clock.advance(15 * 60)
        waitUntil { controller.starts == 2 }
        settle()
        XCTAssertEqual(harness.radio.writes.count, writesAfterSuccess)
        XCTAssertEqual(loadedState(harness).refreshRecord, record)
        XCTAssertTrue(loadedState(harness).setupDone)
        XCTAssertEqual(harness.box.snapshot?.panelTrust, .assumed)

        harness.runtime.submit(.hostWillSleep)
        settle()
        harness.runtime.submit(.hostDidWake)
        harness.clock.advance(2)
        waitUntil { self.refreshWrites(harness.radio).count == 3 }
        XCTAssertEqual(harness.box.snapshot?.panelTrust, .invalid)
        harness.clock.advance(15)
        waitUntil { harness.box.snapshot?.panelTrust == .assumed }
        XCTAssertTrue(loadedState(harness).setupDone)
    }

    func testSettingsBatchKeepsInFlightFrameAndRunsOneLaterAutomaticTransfer() throws {
        let controller = AutomatedPollController()
        let harness = try AutomatedRefreshHarness(controller: controller, localEnabled: false)
        startAndAssumePanel(harness)
        harness.runtime.submit(.refreshNow)
        waitUntil { controller.starts == 1 }
        waitUntil { self.refreshWrites(harness.radio).count == 2 }
        let inFlightFingerprint = try XCTUnwrap(harness.runtime.inFlightFrame?.fingerprint)
        let writesBeforeSettings = harness.radio.writes.count
        var preferences = DisplayPreferences.default
        preferences.title = "FIRST"
        harness.runtime.submit(.savePreferences(preferences))
        harness.runtime.submit(.setDisplayStyle(.activityFocus))
        settle()
        XCTAssertEqual(harness.runtime.inFlightFrame?.fingerprint, inFlightFingerprint)
        XCTAssertEqual(harness.radio.writes.count, writesBeforeSettings)
        XCTAssertEqual(harness.runtime.pendingAutomaticInput?.preferences.displayStyle, .activityFocus)
        harness.clock.advance(15)
        waitUntil { self.refreshWrites(harness.radio).count == 3 }
        XCTAssertNotEqual(harness.runtime.inFlightFrame?.fingerprint, inFlightFingerprint)
        harness.clock.advance(15)
        settle()
        XCTAssertEqual(refreshWrites(harness.radio).count, 3)
    }

    func testElapsedTimeDoesNotCreateTransferWhileSourcesStayFresh() throws {
        let controller = AutomatedPollController()
        let harness = try AutomatedRefreshHarness(controller: controller, localEnabled: false)
        startAndAssumePanel(harness)
        let writes = harness.radio.writes.count
        harness.clock.advance(10 * 60)
        settle()
        XCTAssertEqual(harness.radio.writes.count, writes)
        XCTAssertEqual(controller.starts, 0)
        XCTAssertEqual(harness.box.snapshot?.panelTrust, .assumed)
    }

    func testManualDuringAutomaticPollJoinsOnePollAndQueuesOneTransferAtATime() throws {
        let controller = AutomatedPollController()
        let harness = try AutomatedRefreshHarness(controller: controller, localEnabled: false)
        startAndAssumePanel(harness)
        controller.pause()
        harness.runtime.submit(.refreshNow)
        waitUntil { controller.starts == 1 }
        harness.runtime.submit(.refreshNow)
        harness.runtime.submit(.refreshNow)
        settle()
        XCTAssertEqual(controller.starts, 1)
        XCTAssertEqual(controller.maximumConcurrent, 1)
        controller.completeNext(.success(AutomatedPollController.snapshot(percent: 12)))
        waitUntil { self.refreshWrites(harness.radio).count == 2 }
        let writesDuringFirst = harness.radio.writes.count
        harness.runtime.submit(.refreshNow)
        settle()
        XCTAssertEqual(harness.radio.writes.count, writesDuringFirst)
        XCTAssertEqual(controller.starts, 1)
        controller.resume()
        harness.clock.advance(15)
        waitUntil { self.refreshWrites(harness.radio).count == 3 }
        XCTAssertEqual(controller.starts, 2)
        harness.clock.advance(15)
        waitUntil { harness.box.snapshot?.panelTrust == .assumed }
        XCTAssertEqual(controller.maximumConcurrent, 1)
    }

    private func startAndAssumePanel(_ harness: AutomatedRefreshHarness) {
        harness.runtime.start()
        waitUntil { harness.box.snapshot?.binding == .bound }
        harness.clock.advance(2)
        waitUntil { self.refreshWrites(harness.radio).count == 1 }
        harness.clock.advance(15)
        waitUntil { harness.box.snapshot?.panelTrust == .assumed }
    }

    private func refreshWrites(_ radio: FakeRadio) -> [BLEWriteRecord] {
        radio.writes.filter { $0.opcode == DisplayLinkUUIDs.refreshOpcode }
    }

    private func loadedState(_ harness: AutomatedRefreshHarness) -> ProductState {
        switch PersistenceStore(root: harness.root).load() {
        case .loaded(let state): return state
        default:
            XCTFail("expected persisted state")
            return .default
        }
    }

    private func makeRuntime(clock: ManualDisplayClock, counter: PollCounter) throws -> UsageInkRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usageink-automated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return UsageInkRuntime(language: .english, store: PersistenceStore(root: root), now: { clock.date }, clock: clock, makeCodex: { _ in
            CodexPollingDependencies(isEnabled: true, appVersion: "0.1.0", now: { clock.date }, resolve: { _ in .success(CodexResolvedBinary(path: "/tmp/fake-codex", version: .minimum)) }, poll: { _, _, completion in
                counter.increment()
                completion(.success(CodexUsageSnapshot(planType: "pro", windows: [])))
            })
        }) { _ in }
    }

    private func waitUntil(_ file: StaticString = #filePath, line: UInt = #line, _ predicate: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("condition not met", file: file, line: line)
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
}

private final class AutomatedRefreshHarness {
    let root: URL
    let home: URL
    let radio = FakeRadio()
    let clock = ManualDisplayClock(origin: Date(timeIntervalSince1970: 1_700_000_000))
    let box = AutomatedSnapshotProbe()
    let runtime: UsageInkRuntime

    init(controller: AutomatedPollController, accountAge: Int = 0, localAge: Int = 0, localEnabled: Bool = true) throws {
        root = try ActivityFixtures.makeStoreRoot()
        home = try ActivityFixtures.makeHome()
        let now = Int(clock.date.timeIntervalSince1970)
        try ActivityFixtures.writeRollout(home: home, layer: .sessions, basename: ActivityFixtures.rolloutName(timestamp: "2023-11-14T22-13-20-"), lines: [ActivityFixtures.tokenLine(timestamp: ActivityFixtures.isoUTC(now), input: 10, output: 2)])
        _ = ActivityFixtures.ingest(home: home, root: root, now: clock.date)
        let store = PersistenceStore(root: root)
        var state = ProductState.default
        if !localEnabled {
            state.preferences.modules.today = false
            state.preferences.modules.weekTokens = false
            state.preferences.modules.cache = false
            state.preferences.modules.tps = false
        }
        state.boundDisplay = BoundDisplayRecord(identifier: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", displayName: "UsageInk-Desk")
        state.account = AccountSourceRecord(lastSuccessfulObservationAt: now - accountAge, availability: .fresh, failure: nil, planType: "pro", windows: [UsageWindowRecord(slot: "primary", usedPercent: 12, windowDurationMins: 10_080, resetsAt: 1_800_000_000)])
        state.localActivity = LocalActivitySourceRecord(lastSuccessfulObservationAt: now - localAge, availability: .fresh, failure: nil)
        try store.save(state)
        radio.peripherals[UUID(uuidString: state.boundDisplay!.identifier)!] = FakePeripheralSpec(name: "UsageInk-Desk", rssi: -12)
        let radio = self.radio
        let clock = self.clock
        let box = self.box
        runtime = UsageInkRuntime(language: .english, store: store, activityStore: ActivityStore(root: root), codexHome: home, now: { clock.date }, clock: clock, makeLink: { queue in
            radio.queue = queue
            clock.queue = queue
            return ReadySessionCoordinator(radio: radio, clock: clock)
        }, makeCodex: { _ in controller.dependencies(now: { clock.date }) }) { snapshot in
            box.consume(snapshot)
        }
    }
}

private final class AutomatedPollController: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var pending: [((Result<CodexUsageSnapshot, CodexFailure>) -> Void)] = []
    private var _starts = 0
    private var active = 0
    private var _maximumConcurrent = 0
    var starts: Int { locked { _starts } }
    var maximumConcurrent: Int { locked { _maximumConcurrent } }
    func pause() { locked { paused = true } }
    func resume() { locked { paused = false } }
    func dependencies(now: @escaping () -> Date) -> CodexPollingDependencies {
        CodexPollingDependencies(isEnabled: true, appVersion: "0.1.0", now: now, resolve: { _ in .success(CodexResolvedBinary(path: "/tmp/fake-codex", version: .minimum)) }, poll: { [weak self] _, _, completion in self?.start(completion) })
    }
    func completeNext(_ result: Result<CodexUsageSnapshot, CodexFailure>) {
        let completion: ((Result<CodexUsageSnapshot, CodexFailure>) -> Void)? = locked {
            guard !pending.isEmpty else { return nil }
            active -= 1
            return pending.removeFirst()
        }
        completion?(result)
    }
    static func snapshot(percent: Double) -> CodexUsageSnapshot {
        CodexUsageSnapshot(planType: "pro", windows: [UsageWindowObservation(slot: .primary, usedPercent: percent, windowDurationMins: 10_080, resetsAt: 1_800_000_000)])
    }
    private func start(_ completion: @escaping (Result<CodexUsageSnapshot, CodexFailure>) -> Void) {
        let immediate: Bool = locked {
            _starts += 1
            active += 1
            _maximumConcurrent = max(_maximumConcurrent, active)
            if paused { pending.append(completion); return false }
            active -= 1
            return true
        }
        if immediate { completion(.success(Self.snapshot(percent: 12))) }
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

private final class AutomatedSnapshotProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: RuntimeSnapshot?
    var snapshot: RuntimeSnapshot? { lock.lock(); defer { lock.unlock() }; return _snapshot }
    func consume(_ snapshot: RuntimeSnapshot) { lock.lock(); _snapshot = snapshot; lock.unlock() }
}

private final class PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
