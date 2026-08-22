import XCTest
@testable import UsageInk

final class ManualRefreshRuntimeTests: XCTestCase {
    private let desk = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    func testManualRefreshTransfersEvenWhenFingerprintIsUnchangedAndRecordsSuccessAfterObservation() throws {
        let harness = try RefreshRuntimeHarness()
        waitStart(harness)
        bindReady(harness)
        XCTAssertEqual(harness.radio.writes.map(\.data), [Data([DisplayLinkUUIDs.initOpcode])])
        XCTAssertEqual(harness.box.snapshot?.panelTrust, .invalid)

        let firstTrust = waitFor(harness, "first success") { $0.panelTrust == .assumed }
        harness.runtime.submit(.refreshNow)
        waitUntilWritesIncludeRefresh(harness)
        harness.clock.advance(15)
        wait(for: [firstTrust], timeout: 1.0)

        let firstFingerprint = try XCTUnwrap(loadedState(harness).refreshRecord.lastSucceededFingerprint)
        XCTAssertTrue(loadedState(harness).setupDone)
        XCTAssertNotNil(loadedState(harness).refreshRecord.lastSuccessfulRefreshAt)
        XCTAssertEqual(harness.box.snapshot?.panelTrust, .assumed)
        let writesAfterFirst = harness.radio.writes.count

        harness.runtime.submit(.refreshNow)
        waitUntilWritesIncludeRefresh(harness, minimumWriteCount: writesAfterFirst + 2)
        XCTAssertGreaterThan(harness.radio.writes.count, writesAfterFirst)
        harness.clock.advance(15)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(loadedState(harness).refreshRecord.lastSucceededFingerprint, firstFingerprint)
        XCTAssertTrue(loadedState(harness).setupDone)
        XCTAssertEqual(harness.box.snapshot?.panelTrust, .assumed)
        assertNoForbiddenOpcodes(harness.radio.writes)
    }

    func testDisconnectDuringObservationKeepsLastSuccessfulFrameAndInvalidatesTrust() throws {
        let harness = try RefreshRuntimeHarness()
        waitStart(harness)
        bindReady(harness)
        let first = waitFor(harness, "assumed") { $0.panelTrust == .assumed }
        harness.runtime.submit(.refreshNow)
        waitUntilWritesIncludeRefresh(harness)
        harness.clock.advance(15)
        wait(for: [first], timeout: 1.0)
        let record = loadedState(harness).refreshRecord

        let invalidated = waitFor(harness, "invalid") { $0.panelTrust == .invalid }
        harness.runtime.submit(.refreshNow)
        waitUntilWritesIncludeRefresh(harness, minimumWriteCount: 3)
        harness.radio.emitDisconnect(desk)
        wait(for: [invalidated], timeout: 1.0)
        harness.clock.advance(15)
        XCTAssertEqual(harness.box.snapshot?.panelTrust, .invalid)
        let after = loadedState(harness)
        XCTAssertEqual(after.refreshRecord.lastSucceededFingerprint, record.lastSucceededFingerprint)
        XCTAssertEqual(after.refreshRecord.lastSuccessfulRefreshAt, record.lastSuccessfulRefreshAt)
        XCTAssertTrue(after.setupDone)
    }

    func testSourceFailureStillComposesAnHonestDegradedFrameWithoutFabricatingZero() throws {
        let harness = try RefreshRuntimeHarness(codex: .authRequired)
        waitStart(harness)
        bindReady(harness)
        harness.runtime.submit(.refreshNow)
        waitUntilWritesIncludeRefresh(harness)
        let frame = try XCTUnwrap(harness.runtime.inFlightFrame)
        XCTAssertEqual(frame.blackPlane.count, 15_000)
        XCTAssertEqual(frame.redPlane.count, 15_000)
        let snapshot = try XCTUnwrap(harness.box.snapshot)
        XCTAssertNotEqual(snapshot.account.availability, .fresh)
        let input = DisplayFrameInput(
            preferences: snapshot.preferences,
            account: snapshot.account,
            localActivity: snapshot.localActivity,
            composedAt: Date(timeIntervalSince1970: 1_704_067_200),
            calendar: DisplayFrameFixtures.calendar,
            timeZone: DisplayFrameFixtures.timeZone,
            preferredLanguages: ["en-US"]
        )
        let model = QuotaFocusModelBuilder.build(input)
        XCTAssertNotEqual(model.hero?.displayedValue, "0%")
        XCTAssertNotEqual(model.hero?.displayedValue, "0")
    }

    func testManualRefreshJoinsActivePollBeforeTransfer() throws {
        let gate = DispatchSemaphore(value: 0)
        let harness = try RefreshRuntimeHarness(codex: .hangThenPro(gate: gate))
        waitStart(harness)
        bindReady(harness)
        XCTAssertEqual(harness.radio.writes.map(\.data), [Data([DisplayLinkUUIDs.initOpcode])])
        harness.runtime.submit(.refreshNow)
        XCTAssertEqual(harness.radio.writes.map(\.data), [Data([DisplayLinkUUIDs.initOpcode])])
        let assumed = waitFor(harness, "after poll") { $0.panelTrust == .assumed }
        gate.signal()
        waitUntilWritesIncludeRefresh(harness)
        harness.clock.advance(15)
        wait(for: [assumed], timeout: 1.0)
        XCTAssertTrue(loadedState(harness).setupDone)
    }

    private func waitStart(_ harness: RefreshRuntimeHarness) {
        let started = waitFor(harness, "start") { $0.binding == .unbound }
        harness.runtime.start()
        wait(for: [started], timeout: 1.0)
    }

    private func bindReady(_ harness: RefreshRuntimeHarness) {
        harness.radio.peripherals[desk] = FakePeripheralSpec(name: "UsageInk-Desk", rssi: -12)
        let scanning = waitFor(harness, "scan") { $0.bleLink == .scanning && !$0.bindCandidates.isEmpty }
        harness.runtime.submit(.findAndBindDisplay)
        wait(for: [scanning], timeout: 1.0)
        let ready = waitFor(harness, "ready") { $0.bleLink == .ready && $0.binding == .bound }
        harness.runtime.submit(.bindDisplay(desk))
        wait(for: [ready], timeout: 1.0)
        XCTAssertEqual(harness.radio.writes.map(\.data), [Data([DisplayLinkUUIDs.initOpcode])])
    }

    private func waitUntilWritesIncludeRefresh(
        _ harness: RefreshRuntimeHarness,
        minimumWriteCount: Int = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if harness.radio.writes.contains(where: { $0.opcode == DisplayLinkUUIDs.refreshOpcode }),
               harness.radio.writes.count >= minimumWriteCount {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("missing refresh opcode writes=\(harness.radio.writes.map(\.data))", file: file, line: line)
    }

    private func loadedState(_ harness: RefreshRuntimeHarness) -> ProductState {
        switch PersistenceStore(root: harness.root).load() {
        case .loaded(let state):
            return state
        default:
            XCTFail("expected loaded state")
            return .default
        }
    }

    private func waitFor(
        _ harness: RefreshRuntimeHarness,
        _ name: String,
        _ matcher: @escaping (RuntimeSnapshot) -> Bool
    ) -> XCTestExpectation {
        let exp = expectation(description: name)
        harness.box.match(exp, matcher)
        return exp
    }

    private func assertNoForbiddenOpcodes(_ writes: [BLEWriteRecord]) {
        for write in writes {
            if let opcode = write.opcode {
                XCTAssertFalse(DisplayLinkUUIDs.forbiddenOpcodes.contains(opcode))
            }
        }
    }
}

private enum RefreshCodex {
    case disabled
    case authRequired
    case hangThenPro(gate: DispatchSemaphore)
}

private final class RefreshRuntimeHarness {
    let root: URL
    let radio = FakeRadio()
    let clock = ManualDisplayClock()
    let box = RefreshSnapshotProbe()
    let runtime: UsageInkRuntime

    init(codex: RefreshCodex = .disabled) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageink-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let radio = self.radio
        let clock = self.clock
        let box = self.box
        runtime = UsageInkRuntime(
            language: .english,
            store: PersistenceStore(root: root),
            makeLink: { queue in
                radio.queue = queue
                clock.queue = queue
                return ReadySessionCoordinator(radio: radio, clock: clock)
            },
            makeCodex: { queue in
                RefreshRuntimeHarness.makeCodex(codex, queue: queue)
            }
        ) { snapshot in
            box.consume(snapshot)
        }
    }

    private static func makeCodex(_ kind: RefreshCodex, queue: DispatchQueue) -> CodexPollingDependencies {
        switch kind {
        case .disabled:
            return .disabled()
        case .authRequired:
            return CodexPollingDependencies(
                isEnabled: true,
                appVersion: "0.1.0",
                now: Date.init,
                resolve: { _ in
                    .success(CodexResolvedBinary(path: "/tmp/fake-codex", version: .minimum))
                },
                poll: { _, _, completion in
                    queue.async {
                        completion(.failure(.authRequired))
                    }
                }
            )
        case .hangThenPro(let gate):
            _ = queue
            return CodexPollingDependencies(
                isEnabled: true,
                appVersion: "0.1.0",
                now: Date.init,
                resolve: { _ in
                    .success(CodexResolvedBinary(path: "/tmp/fake-codex", version: .minimum))
                },
                poll: { _, _, completion in
                    DispatchQueue.global(qos: .userInitiated).async {
                        gate.wait()
                        completion(
                            .success(
                                CodexUsageSnapshot(
                                    planType: "pro",
                                    windows: [
                                        UsageWindowObservation(
                                            slot: .primary,
                                            usedPercent: 12,
                                            windowDurationMins: 10080,
                                            resetsAt: 1_800_000_000
                                        )
                                    ]
                                )
                            )
                        )
                    }
                }
            )
        }
    }
}

private final class RefreshSnapshotProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: RuntimeSnapshot?
    private var matcher: ((RuntimeSnapshot) -> Bool)?
    private var pending: XCTestExpectation?

    var snapshot: RuntimeSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return _snapshot
    }

    func match(_ expectation: XCTestExpectation, _ matcher: @escaping (RuntimeSnapshot) -> Bool) {
        lock.lock()
        pending = expectation
        self.matcher = matcher
        let current = _snapshot
        lock.unlock()
        if let current, matcher(current) {
            fulfill(expectation)
        }
    }

    func consume(_ snapshot: RuntimeSnapshot) {
        lock.lock()
        _snapshot = snapshot
        let matcher = self.matcher
        let pending = self.pending
        lock.unlock()
        if let pending, matcher?(snapshot) == true {
            fulfill(pending)
        }
    }

    private func fulfill(_ expectation: XCTestExpectation) {
        lock.lock()
        matcher = nil
        pending = nil
        lock.unlock()
        expectation.fulfill()
    }
}
