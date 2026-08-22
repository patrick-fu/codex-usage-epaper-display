import XCTest
@testable import UsageInk

final class DisconnectSleepRecoveryTests: XCTestCase {
    private let desk = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    func testRecoveryWaitsTwoSecondsThenScansConnectsAndRequiresFreshMTU() {
        let harness = CoordinatorHarness()
        harness.radio.peripherals[desk] = FakePeripheralSpec()
        harness.coordinator.attach()
        harness.coordinator.confirmBoundIdentity(desk)
        harness.coordinator.recover(identifier: desk)
        XCTAssertEqual(harness.link, .disconnected)
        XCTAssertEqual(harness.radio.connectCount, 0)
        XCTAssertEqual(harness.clock.scheduledDelay(id: "recovery"), 2)
        harness.clock.advance(2)
        XCTAssertEqual(harness.link, .ready)
        XCTAssertEqual(harness.radio.scanCount, 1)
        XCTAssertEqual(harness.radio.connectCount, 1)
        XCTAssertEqual(harness.radio.writes.map(\.data), [Data([DisplayLinkUUIDs.initOpcode])])
        XCTAssertEqual(harness.session?.mtu, 185)
    }

    func testRecoveryBudgetIsExactlyFiveSerialAttemptsThenUnreachable() {
        let harness = CoordinatorHarness()
        var spec = FakePeripheralSpec()
        spec.connectHangs = true
        harness.radio.peripherals[desk] = spec
        harness.coordinator.attach()
        harness.coordinator.confirmBoundIdentity(desk)
        harness.coordinator.recover(identifier: desk)

        let postFailureWaits: [TimeInterval] = [5, 15, 45, 90]
        harness.clock.advance(2)
        XCTAssertEqual(harness.radio.connectCount, 1)
        XCTAssertEqual(harness.link, .connecting)
        for (index, wait) in postFailureWaits.enumerated() {
            harness.clock.advance(10)
            XCTAssertEqual(harness.classification, .connectFailed)
            XCTAssertEqual(harness.link, .disconnected)
            XCTAssertEqual(harness.clock.scheduledDelay(id: "recovery"), wait)
            harness.clock.advance(wait)
            XCTAssertEqual(harness.radio.connectCount, index + 2)
            XCTAssertEqual(harness.link, .connecting)
        }
        harness.clock.advance(10)
        XCTAssertEqual(harness.radio.connectCount, 5)
        XCTAssertEqual(harness.link, .unreachable)
        XCTAssertEqual(harness.classification, .retryExhausted)
        harness.clock.advance(90)
        XCTAssertEqual(harness.radio.connectCount, 5)
        harness.coordinator.recover(identifier: desk, resetBudget: false)
        harness.clock.advance(90)
        XCTAssertEqual(harness.radio.connectCount, 5)
        XCTAssertEqual(harness.link, .unreachable)

        spec.connectHangs = false
        harness.radio.peripherals[desk] = spec
        harness.coordinator.recover(identifier: desk, resetBudget: true)
        XCTAssertEqual(harness.link, .disconnected)
        harness.clock.advance(2)
        XCTAssertEqual(harness.link, .ready)
        XCTAssertEqual(harness.radio.connectCount, 6)
    }

    func testRecoveryScanTimeoutUsesStageTimeoutAndCountsAsAnAttempt() {
        let harness = CoordinatorHarness()
        harness.radio.peripherals[desk] = FakePeripheralSpec()
        harness.radio.advertiseOnScan = false
        harness.coordinator.attach()
        harness.coordinator.confirmBoundIdentity(desk)
        harness.coordinator.recover(identifier: desk)
        harness.clock.advance(2)
        XCTAssertEqual(harness.link, .scanning)
        XCTAssertEqual(harness.radio.scanCount, 1)
        harness.clock.advance(15)
        XCTAssertEqual(harness.classification, .boundDisplayNotFound)
        XCTAssertEqual(harness.link, .disconnected)
        XCTAssertEqual(harness.clock.scheduledDelay(id: "recovery"), 5)
        harness.clock.advance(5)
        XCTAssertEqual(harness.link, .scanning)
        XCTAssertEqual(harness.radio.scanCount, 2)
    }

    func testDisconnectDuringEachPlaneRequiresFullResendNotOffsetResume() {
        for stage in [PlaneStage.black, .red, .refresh] {
            assertFullRecoveryAfterDisconnect(during: stage)
        }
    }

    func testCallbackAmbiguityNeverUsesSessionRetry() {
        let harness = CoordinatorHarness()
        var spec = FakePeripheralSpec()
        spec.autoConfig = nil
        harness.radio.peripherals[desk] = spec
        harness.coordinator.attach()
        harness.coordinator.confirmBoundIdentity(desk)
        harness.coordinator.recover(identifier: desk)
        harness.clock.advance(2)
        XCTAssertEqual(harness.link, .awaitingConfig)
        harness.radio.emitValue(identifier: desk, characteristic: DisplayLinkUUIDs.data, value: Data([0x00]))
        XCTAssertEqual(harness.classification, .callbackAmbiguous)
        XCTAssertNotEqual(harness.link, .ready)
        XCTAssertEqual(harness.clock.scheduledDelay(id: "recovery"), 5)
        XCTAssertFalse(harness.radio.writes.contains { $0.opcode == DisplayLinkUUIDs.writeImageOpcode })
    }

    func testStillConnectedRefreshTimeoutUsesOneSameSessionRetryThenFullRecovery() {
        let harness = TransferHarness()
        harness.radio.maximumWriteWithoutResponse = 20
        harness.radio.maximumWriteWithResponse = 20
        bindReady(harness)
        harness.radio.holdWriteAcknowledgements = true
        XCTAssertTrue(
            harness.coordinator.transferDisplayFrame(
                blackPlane: Data(repeating: 0x00, count: 15_000),
                redPlane: Data(repeating: 0xFF, count: 15_000),
                sessionGeneration: harness.session!.generation
            )
        )
        var safety = 0
        while harness.radio.writes.last?.opcode != DisplayLinkUUIDs.refreshOpcode {
            harness.radio.acknowledgeNextWrite()
            safety += 1
            XCTAssertLessThan(safety, 8)
        }
        let writesBeforeTimeout = harness.radio.writes.count
        harness.clock.advance(30)
        XCTAssertEqual(harness.link, .initializing)
        XCTAssertEqual(harness.classification, .refreshTimeout)
        XCTAssertEqual(harness.radio.writes.last?.data, Data([DisplayLinkUUIDs.initOpcode]))
        harness.radio.acknowledgeNextWrite()
        harness.radio.emitValue(
            identifier: desk,
            characteristic: DisplayLinkUUIDs.data,
            value: Data("mtu=185".utf8)
        )
        XCTAssertEqual(harness.link, .ready)
        XCTAssertTrue(
            harness.radio.writes.dropFirst(writesBeforeTimeout + 1).contains {
                $0.opcode == DisplayLinkUUIDs.writeImageOpcode
            }
        )
        while harness.radio.writes.last?.opcode != DisplayLinkUUIDs.refreshOpcode {
            harness.radio.acknowledgeNextWrite()
            safety += 1
            XCTAssertLessThan(safety, 16)
        }
        harness.radio.dropDeferredWriteAcknowledgements()
        harness.clock.advance(30)
        XCTAssertEqual(harness.failed, .refreshTimeout)
        XCTAssertNotEqual(harness.link, .ready)
        XCTAssertFalse(harness.completed)
    }

    func testHostSleepThenWakeStartsNewBudgetWithoutReplayingBacklog() throws {
        let harness = try RecoveryRuntimeHarness()
        startBound(harness)
        let firstRefresh = harness.radio.writes.filter { $0.opcode == DisplayLinkUUIDs.refreshOpcode }.count
        XCTAssertEqual(firstRefresh, 1)
        let record = loadedState(harness).refreshRecord
        harness.runtime.submit(.hostWillSleep)
        waitUntil { harness.box.snapshot?.panelTrust == .invalid }
        let pollsBeforeSleep = harness.codex.polls
        harness.clock.advance(45 * 60)
        XCTAssertEqual(
            harness.radio.writes.filter { $0.opcode == DisplayLinkUUIDs.refreshOpcode }.count,
            firstRefresh
        )
        harness.runtime.submit(.hostDidWake)
        waitUntil { harness.clock.scheduledDelay(id: "recovery") != nil || self.refreshCount(harness) == 2 }
        if let delay = harness.clock.scheduledDelay(id: "recovery") {
            harness.clock.advance(delay)
        }
        waitUntil { self.refreshCount(harness) == 2 }
        XCTAssertEqual(harness.codex.polls, pollsBeforeSleep + 1)
        XCTAssertEqual(loadedState(harness).refreshRecord.lastSucceededFingerprint, record.lastSucceededFingerprint)
        harness.clock.advance(15)
        waitUntil { harness.box.snapshot?.panelTrust == .assumed }
        XCTAssertNotNil(loadedState(harness).refreshRecord.lastSucceededFingerprint)
        XCTAssertNotNil(loadedState(harness).refreshRecord.lastSuccessfulRefreshAt)
    }

    func testRuntimeRetryExhaustionShowsDisplayUnavailableWithoutSelfLoop() throws {
        let harness = try RecoveryRuntimeHarness(connectHangs: true)
        harness.runtime.start()
        waitUntil { harness.box.snapshot != nil }
        waitUntil { harness.clock.scheduledDelay(id: "recovery") != nil || harness.radio.connectCount >= 1 }
        if let delay = harness.clock.scheduledDelay(id: "recovery") {
            harness.clock.advance(delay)
        }
        waitUntil { harness.radio.connectCount == 1 }
        let waits: [TimeInterval] = [5, 15, 45, 90]
        for (index, wait) in waits.enumerated() {
            harness.clock.advance(10)
            waitUntil { harness.box.snapshot?.bleLink == .disconnected || harness.box.snapshot?.bleLink == .unreachable }
            if index < waits.count {
                harness.clock.advance(wait)
                waitUntil { harness.radio.connectCount == index + 2 }
            }
        }
        harness.clock.advance(10)
        waitUntil { harness.box.snapshot?.bleLink == .unreachable }
        XCTAssertEqual(harness.radio.connectCount, 5)
        XCTAssertTrue(harness.box.snapshot?.statusSummary.contains("Display unavailable") ?? false)
        let connects = harness.radio.connectCount
        harness.clock.advance(90)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(harness.radio.connectCount, connects)
        XCTAssertEqual(harness.box.snapshot?.bleLink, .unreachable)
        XCTAssertEqual(loadedState(harness).refreshRecord.lastSuccessfulRefreshAt, nil)
    }

    func testPoweredOnStartsANewRecoveryBudget() throws {
        let harness = try RecoveryRuntimeHarness()
        startBound(harness)
        harness.radio.setAvailability(.unavailable)
        waitUntil { harness.box.snapshot?.panelTrust == .invalid }
        harness.radio.peripherals[desk] = FakePeripheralSpec(name: "UsageInk-Desk", rssi: -12)
        harness.radio.setAvailability(.poweredOn)
        waitUntil { harness.clock.scheduledDelay(id: "recovery") != nil || harness.box.snapshot?.bleLink == .ready }
        if let delay = harness.clock.scheduledDelay(id: "recovery") {
            harness.clock.advance(delay)
        }
        waitUntil { harness.box.snapshot?.bleLink == .ready }
        waitUntil { self.refreshCount(harness) >= 2 }
    }

    func testDisconnectDuringTransferPreservesLastSuccessfulRecordAndResendsFullFrame() throws {
        let harness = try RecoveryRuntimeHarness()
        startBound(harness)
        let record = loadedState(harness).refreshRecord
        XCTAssertNotNil(record.lastSucceededFingerprint)
        harness.radio.emitDisconnect(desk)
        waitUntil { harness.box.snapshot?.panelTrust == .invalid }
        XCTAssertEqual(loadedState(harness).refreshRecord.lastSucceededFingerprint, record.lastSucceededFingerprint)
        XCTAssertNotEqual(harness.box.snapshot?.bleLink, .ready)
    }

    func testStaleDegradedFrameIsStillSentAfterRecovery() throws {
        let harness = try RecoveryRuntimeHarness(accountFailure: true)
        harness.runtime.start()
        waitUntil { harness.box.snapshot != nil }
        waitUntil { harness.clock.scheduledDelay(id: "recovery") != nil || self.refreshCount(harness) == 1 }
        if let delay = harness.clock.scheduledDelay(id: "recovery") {
            harness.clock.advance(delay)
        }
        waitUntil { self.refreshCount(harness) == 1 }
        XCTAssertEqual(harness.box.snapshot?.account.availability, .authRequired)
        XCTAssertTrue(harness.radio.writes.contains { $0.opcode == DisplayLinkUUIDs.refreshOpcode })
    }

    private enum PlaneStage {
        case black, red, refresh
    }

    private func assertFullRecoveryAfterDisconnect(during stage: PlaneStage) {
        let harness = TransferHarness()
        harness.radio.maximumWriteWithoutResponse = 20
        harness.radio.maximumWriteWithResponse = 20
        bindReady(harness)
        harness.coordinator.confirmBoundIdentity(desk)
        harness.radio.holdWriteAcknowledgements = true
        XCTAssertTrue(
            harness.coordinator.transferDisplayFrame(
                blackPlane: Data(repeating: 0x00, count: 15_000),
                redPlane: Data(repeating: 0xFF, count: 15_000),
                sessionGeneration: harness.session!.generation
            )
        )
        switch stage {
        case .black:
            XCTAssertTrue(harness.radio.writes.contains { $0.opcode == DisplayLinkUUIDs.writeImageOpcode })
        case .red:
            while !(harness.radio.writes.last?.data.dropFirst().first.map { $0 & DisplayLinkUUIDs.writeImageFlagRed != 0 } ?? false) {
                harness.radio.acknowledgeNextWrite()
            }
        case .refresh:
            while harness.radio.writes.last?.opcode != DisplayLinkUUIDs.refreshOpcode {
                harness.radio.acknowledgeNextWrite()
            }
        }
        let writesBeforeDisconnect = harness.radio.writes.count
        harness.radio.emitDisconnect(desk)
        XCTAssertEqual(harness.failed, .disconnected)
        XCTAssertFalse(harness.completed)
        XCTAssertEqual(harness.link, .disconnected)
        harness.radio.holdWriteAcknowledgements = false
        harness.coordinator.recover(identifier: desk)
        harness.clock.advance(2)
        XCTAssertEqual(harness.link, .ready)
        let afterReconnect = Array(harness.radio.writes.dropFirst(writesBeforeDisconnect))
        XCTAssertEqual(afterReconnect.first?.data, Data([DisplayLinkUUIDs.initOpcode]))
        XCTAssertTrue(
            harness.coordinator.transferDisplayFrame(
                blackPlane: Data(repeating: 0x00, count: 15_000),
                redPlane: Data(repeating: 0xFF, count: 15_000),
                sessionGeneration: harness.session!.generation
            )
        )
        XCTAssertEqual(harness.radio.writes.last?.opcode, DisplayLinkUUIDs.refreshOpcode)
        let resent = Array(harness.radio.writes.dropFirst(writesBeforeDisconnect))
        let resentImage = resent.filter { $0.opcode == DisplayLinkUUIDs.writeImageOpcode }
        XCTAssertTrue(resentImage.contains { $0.data.count > 1 && $0.data[1] & DisplayLinkUUIDs.writeImageFlagRed == 0 })
        XCTAssertTrue(resentImage.contains { $0.data.count > 1 && $0.data[1] & DisplayLinkUUIDs.writeImageFlagRed != 0 })
        harness.clock.advance(15)
        XCTAssertTrue(harness.completed)
    }

    private func bindReady(_ harness: TransferHarness) {
        var spec = FakePeripheralSpec()
        spec.autoMTUText = "mtu=185"
        harness.radio.peripherals[desk] = spec
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.coordinator.bind(identifier: desk)
        XCTAssertEqual(harness.link, .ready)
    }

    private func startBound(_ harness: RecoveryRuntimeHarness) {
        harness.runtime.start()
        waitUntil { harness.box.snapshot != nil }
        waitUntil {
            harness.clock.scheduledDelay(id: "recovery") != nil
                || harness.box.snapshot?.bleLink == .ready
                || harness.box.snapshot?.bleLink == .scanning
                || harness.box.snapshot?.bleLink == .connecting
        }
        if let delay = harness.clock.scheduledDelay(id: "recovery") {
            harness.clock.advance(delay)
        } else {
            harness.clock.advance(2)
        }
        waitUntil { harness.box.snapshot?.bleLink == .ready }
        waitUntil { self.refreshCount(harness) == 1 }
        harness.clock.advance(15)
        waitUntil { harness.box.snapshot?.panelTrust == .assumed }
    }

    private func refreshCount(_ harness: RecoveryRuntimeHarness) -> Int {
        harness.radio.writes.filter { $0.opcode == DisplayLinkUUIDs.refreshOpcode }.count
    }

    private func loadedState(_ harness: RecoveryRuntimeHarness) -> ProductState {
        switch PersistenceStore(root: harness.root).load() {
        case .loaded(let state):
            return state
        default:
            XCTFail("expected loaded state")
            return .default
        }
    }

    private func waitUntil(
        _ file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if condition() {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("condition not met", file: file, line: line)
    }
}

private final class TransferHarness: DisplayLinkDelegate {
    let radio = FakeRadio()
    let clock = ManualDisplayClock()
    let coordinator: ReadySessionCoordinator
    var link: BLELinkState = .unbound
    var session: ReadyBLESession?
    var completed = false
    var failed: BLEClassification?
    var classification: BLEClassification?

    init() {
        coordinator = ReadySessionCoordinator(radio: radio, clock: clock)
        coordinator.delegate = self
    }

    func displayLinkDidChangeAvailability(_ availability: RadioAvailability) {}
    func displayLinkDidUpdateLink(_ state: BLELinkState) { link = state }
    func displayLinkDidUpdateCandidates(_ candidates: [BindCandidate]) {}
    func displayLinkDidClassify(_ classification: BLEClassification) { self.classification = classification }
    func displayLinkDidBecomeReady(_ session: ReadyBLESession) { self.session = session }
    func displayLinkDidDisconnect() {}
    func displayLinkDidUpdateReadyConfig(_ config: EPDConfig) { session?.config = config }
    func displayLinkDidFinishConfigWrite(succeeded: Bool) {}
    func displayLinkDidCompleteRefresh() { completed = true }
    func displayLinkDidFailRefresh(_ classification: BLEClassification) { failed = classification }
}

private final class CoordinatorHarness: DisplayLinkDelegate {
    let radio = FakeRadio()
    let clock = ManualDisplayClock()
    let coordinator: ReadySessionCoordinator
    var link: BLELinkState = .unbound
    var classification: BLEClassification?
    var session: ReadyBLESession?

    init() {
        coordinator = ReadySessionCoordinator(radio: radio, clock: clock)
        coordinator.delegate = self
    }

    func displayLinkDidChangeAvailability(_ availability: RadioAvailability) {}
    func displayLinkDidUpdateLink(_ state: BLELinkState) { link = state }
    func displayLinkDidUpdateCandidates(_ candidates: [BindCandidate]) {}
    func displayLinkDidClassify(_ classification: BLEClassification) { self.classification = classification }
    func displayLinkDidBecomeReady(_ session: ReadyBLESession) { self.session = session }
    func displayLinkDidDisconnect() {}
    func displayLinkDidUpdateReadyConfig(_ config: EPDConfig) { session?.config = config }
    func displayLinkDidFinishConfigWrite(succeeded: Bool) {}
}

private final class RecoveryRuntimeHarness {
    let root: URL
    let store: PersistenceStore
    let radio = FakeRadio()
    let clock = ManualDisplayClock()
    let box = RecoverySnapshotProbe()
    let runtime: UsageInkRuntime
    let codex: RecoveryPollCounter

    init(connectHangs: Bool = false, accountFailure: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageink-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = PersistenceStore(root: root)
        var state = ProductState.default
        state.boundDisplay = BoundDisplayRecord(
            identifier: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            displayName: "UsageInk-Desk"
        )
        let now = Int(clock.date.timeIntervalSince1970)
        state.preferences.modules.today = false
        state.preferences.modules.weekTokens = false
        state.preferences.modules.cache = false
        state.preferences.modules.tps = false
        if accountFailure {
        } else {
            state.account = AccountSourceRecord(
                lastSuccessfulObservationAt: now,
                availability: .fresh,
                failure: nil,
                planType: "pro",
                windows: [
                    UsageWindowRecord(
                        slot: "primary",
                        usedPercent: 12,
                        windowDurationMins: 10_080,
                        resetsAt: 1_800_000_000
                    )
                ]
            )
            state.localActivity = LocalActivitySourceRecord(
                lastSuccessfulObservationAt: now,
                availability: .fresh,
                failure: nil
            )
        }
        try store.save(state)
        var spec = FakePeripheralSpec(name: "UsageInk-Desk", rssi: -12)
        spec.connectHangs = connectHangs
        radio.peripherals[UUID(uuidString: state.boundDisplay!.identifier)!] = spec
        let radio = self.radio
        let clock = self.clock
        let box = self.box
        let store = self.store
        let counter = RecoveryPollCounter()
        self.codex = counter
        runtime = UsageInkRuntime(
            language: .english,
            store: store,
            now: { clock.date },
            clock: clock,
            makeLink: { queue in
                radio.queue = queue
                clock.queue = queue
                return ReadySessionCoordinator(radio: radio, clock: clock)
            },
            makeCodex: { queue in
                CodexPollingDependencies(
                    isEnabled: true,
                    appVersion: "0.1.0",
                    now: { clock.date },
                    resolve: { _ in
                        .success(CodexResolvedBinary(path: "/tmp/fake-codex", version: .minimum))
                    },
                    poll: { _, _, completion in
                        counter.increment()
                        queue.async {
                            if accountFailure {
                                completion(.failure(.authRequired))
                            } else {
                                completion(
                                    .success(
                                        CodexUsageSnapshot(
                                            planType: "pro",
                                            windows: [
                                                UsageWindowObservation(
                                                    slot: .primary,
                                                    usedPercent: 12,
                                                    windowDurationMins: 10_080,
                                                    resetsAt: 1_800_000_000
                                                )
                                            ]
                                        )
                                    )
                                )
                            }
                        }
                    }
                )
            }
        ) { snapshot in
            box.consume(snapshot)
        }
    }
}

private final class RecoveryPollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
    var polls: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class RecoverySnapshotProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: RuntimeSnapshot?

    var snapshot: RuntimeSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return _snapshot
    }

    func consume(_ snapshot: RuntimeSnapshot) {
        lock.lock()
        _snapshot = snapshot
        lock.unlock()
    }
}
