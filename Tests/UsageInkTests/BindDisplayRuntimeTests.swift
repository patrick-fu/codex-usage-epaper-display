import XCTest
@testable import UsageInk

final class BindDisplayRuntimeTests: XCTestCase {
    private let desk = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    func testScanDoesNotRequireCodexAndDoesNotPersistRSSI() throws {
        let harness = try RuntimeHarness()
        waitStart(harness)
        XCTAssertEqual(harness.box.snapshot?.binding, .unbound)

        harness.radio.peripherals[desk] = FakePeripheralSpec(name: "UsageInk-Desk", rssi: -38)
        waitForScan(harness)

        let candidate = try XCTUnwrap(harness.box.snapshot?.bindCandidates.first)
        XCTAssertEqual(candidate.advertisedName, "UsageInk-Desk")
        XCTAssertEqual(candidate.rssi, -38)
        XCTAssertEqual(candidate.shortIdentifier, "6E5F")
        XCTAssertEqual(harness.box.snapshot?.binding, .unbound)
        switch PersistenceStore(root: harness.root).load() {
        case .missing:
            break
        case .loaded(let state) where state.boundDisplay == nil:
            break
        default:
            XCTFail("scan must not persist a Bound Display or RSSI")
        }
    }

    func testCompatibleBindPersistsStableIdentityAndReadySession() throws {
        let harness = try RuntimeHarness()
        waitStart(harness)
        harness.radio.peripherals[desk] = FakePeripheralSpec(name: "UsageInk-Desk\n", rssi: -12)
        waitForScan(harness)
        let ready = waitFor(harness, "ready") { $0.bleLink == .ready && $0.binding == .bound && $0.hasReadyWakeupConfiguration }
        harness.runtime.submit(.bindDisplay(desk))
        wait(for: [ready], timeout: 1.0)

        let snapshot = try XCTUnwrap(harness.box.snapshot)
        XCTAssertEqual(snapshot.binding, .bound)
        XCTAssertEqual(snapshot.bleLink, .ready)
        XCTAssertTrue(snapshot.hasReadyWakeupConfiguration)
        XCTAssertEqual(snapshot.panelTrust, .invalid)

        switch PersistenceStore(root: harness.root).load() {
        case .loaded(let state):
            XCTAssertEqual(state.boundDisplay?.identifier, desk.uuidString)
            XCTAssertEqual(state.boundDisplay?.displayName, "UsageInk-Desk")
            let json = try String(contentsOf: harness.root.appendingPathComponent("state.json"), encoding: .utf8)
            XCTAssertFalse(json.contains("-12"))
            XCTAssertFalse(json.contains("rssi"))
        default:
            XCTFail("compatible bind must persist")
        }
        XCTAssertEqual(harness.radio.writes.first?.data, Data([0x01]))
    }

    func testIncompatibleFirmwareDoesNotPersistBinding() throws {
        let harness = try RuntimeHarness()
        waitStart(harness)
        var spec = FakePeripheralSpec()
        spec.versionByte = 0x15
        harness.radio.peripherals[desk] = spec
        waitForScan(harness)
        let failed = waitFor(harness, "firmware") { $0.lastBLEClassification == .firmwareIncompatible }
        harness.runtime.submit(.bindDisplay(desk))
        wait(for: [failed], timeout: 1.0)
        XCTAssertEqual(harness.box.snapshot?.binding, .unbound)
        XCTAssertFalse(harness.box.snapshot?.hasReadyWakeupConfiguration ?? true)
        XCTAssertTrue(harness.box.snapshot?.statusSummary.contains("Display firmware incompatible") ?? false)
        switch PersistenceStore(root: harness.root).load() {
        case .missing:
            break
        case .loaded(let state) where state.boundDisplay == nil:
            break
        default:
            XCTFail("incompatible firmware must not bind")
        }
        XCTAssertTrue(harness.radio.writes.isEmpty)
    }

    func testRestartRestoresBindingWithoutLiveSessionOrTrust() throws {
        let harness = try RuntimeHarness()
        waitStart(harness)
        harness.radio.peripherals[desk] = FakePeripheralSpec(name: "Desk")
        waitForScan(harness)
        let ready = waitFor(harness, "ready") { $0.bleLink == .ready && $0.hasReadyWakeupConfiguration }
        harness.runtime.submit(.bindDisplay(desk))
        wait(for: [ready], timeout: 1.0)

        let restarted = expectation(description: "restart")
        let secondBox = SnapshotProbe()
        let secondRadio = FakeRadio()
        let second = UsageInkRuntime(
            language: .english,
            store: PersistenceStore(root: harness.root),
            makeLink: { queue in
                secondRadio.queue = queue
                return ReadySessionCoordinator(radio: secondRadio, clock: ManualDisplayClock())
            }
        ) { snapshot in
            secondBox.consume(snapshot)
        }
        secondBox.match(restarted) { $0.binding == .bound }
        second.start()
        wait(for: [restarted], timeout: 1.0)
        XCTAssertEqual(secondBox.snapshot?.binding, .bound)
        XCTAssertEqual(secondBox.snapshot?.bleLink, .disconnected)
        XCTAssertEqual(secondBox.snapshot?.panelTrust, .invalid)
        XCTAssertFalse(secondBox.snapshot?.hasReadyWakeupConfiguration ?? true)
        XCTAssertNil(secondBox.snapshot?.lastBLEClassification)
    }

    func testUnbindClearsBindingAndKeepsPreferences() throws {
        let harness = try RuntimeHarness()
        waitStart(harness)
        let styled = waitFor(harness, "style") { $0.displayStyle == .balanced }
        harness.runtime.submit(.setDisplayStyle(.balanced))
        wait(for: [styled], timeout: 1.0)

        harness.radio.peripherals[desk] = FakePeripheralSpec()
        waitForScan(harness)
        let ready = waitFor(harness, "ready") { $0.bleLink == .ready && $0.hasReadyWakeupConfiguration }
        harness.runtime.submit(.bindDisplay(desk))
        wait(for: [ready], timeout: 1.0)

        let unbound = waitFor(harness, "unbind") { $0.binding == .unbound }
        harness.runtime.submit(.unbindDisplay)
        wait(for: [unbound], timeout: 1.0)
        XCTAssertEqual(harness.box.snapshot?.displayStyle, .balanced)
        XCTAssertEqual(harness.box.snapshot?.bleLink, .unbound)
        XCTAssertFalse(harness.box.snapshot?.hasReadyWakeupConfiguration ?? true)
        switch PersistenceStore(root: harness.root).load() {
        case .loaded(let state):
            XCTAssertNil(state.boundDisplay)
            XCTAssertFalse(state.setupDone)
            XCTAssertEqual(state.preferences.displayStyle, .balanced)
        default:
            XCTFail("unbind should keep preferences")
        }
    }

    func testDenialKeepsPersistedBindingAndReEnableRecoversReadySession() throws {
        let harness = try RuntimeHarness()
        waitStart(harness)
        harness.radio.peripherals[desk] = FakePeripheralSpec()
        waitForScan(harness)
        let ready = waitFor(harness, "ready") { $0.bleLink == .ready && $0.hasReadyWakeupConfiguration }
        harness.runtime.submit(.bindDisplay(desk))
        wait(for: [ready], timeout: 1.0)

        let denied = waitFor(harness, "denied") { $0.bleLink == .unavailable }
        harness.radio.setAvailability(.unauthorized)
        wait(for: [denied], timeout: 1.0)
        XCTAssertEqual(harness.box.snapshot?.binding, .bound)
        XCTAssertEqual(harness.box.snapshot?.lastBLEClassification, .bluetoothUnauthorized)
        XCTAssertFalse(harness.box.snapshot?.hasReadyWakeupConfiguration ?? true)

        let recovered = waitFor(harness, "recovered") { $0.bleLink == .ready && $0.hasReadyWakeupConfiguration }
        harness.radio.setAvailability(.poweredOn)
        wait(for: [recovered], timeout: 1.0)
        XCTAssertEqual(harness.box.snapshot?.binding, .bound)
        XCTAssertTrue(harness.box.snapshot?.hasReadyWakeupConfiguration ?? false)
    }


    func testSaveFailureCancelsReadySessionAndDoesNotGhostRecover() throws {
        let harness = try RuntimeHarness(simulatedSaveError: .writeFailed)
        waitStart(harness)
        harness.radio.peripherals[desk] = FakePeripheralSpec()
        waitForScan(harness)
        let failed = waitFor(harness, "save-failed") {
            $0.storageClassification == .stateWriteFailed && $0.binding == .unbound && $0.bleLink != .ready
        }
        harness.runtime.submit(.bindDisplay(desk))
        wait(for: [failed], timeout: 1.0)
        XCTAssertEqual(harness.box.snapshot?.binding, .unbound)
        XCTAssertEqual(harness.box.snapshot?.panelTrust, .invalid)
        XCTAssertFalse(harness.box.snapshot?.hasReadyWakeupConfiguration ?? true)
        XCTAssertNotEqual(harness.box.snapshot?.bleLink, .ready)
        let initWrites = harness.radio.writes.count

        harness.radio.setAvailability(.unauthorized)
        let denied = waitFor(harness, "denied-unbound") { $0.bleLink == .unavailable || $0.lastBLEClassification == .bluetoothUnauthorized }
        wait(for: [denied], timeout: 1.0)
        let ghost = waitFor(harness, "no-ghost") { $0.bleLink == .ready }
        ghost.isInverted = true
        harness.radio.setAvailability(.poweredOn)
        wait(for: [ghost], timeout: 0.2)
        XCTAssertNotEqual(harness.box.snapshot?.bleLink, .ready)
        XCTAssertEqual(harness.box.snapshot?.binding, .unbound)
        XCTAssertEqual(harness.radio.writes.count, initWrites)
        switch PersistenceStore(root: harness.root).load() {
        case .missing:
            break
        case .loaded(let state) where state.boundDisplay == nil:
            break
        default:
            XCTFail("failed save must not leave a durable binding")
        }
    }

    func testBoundDisplayRejectsASecondIdentity() throws {
        let shelf = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let harness = try RuntimeHarness()
        waitStart(harness)
        harness.radio.peripherals[desk] = FakePeripheralSpec(name: "Desk")
        harness.radio.peripherals[shelf] = FakePeripheralSpec(name: "Shelf")
        waitForScan(harness)
        let ready = waitFor(harness, "ready") { $0.bleLink == .ready && $0.hasReadyWakeupConfiguration }
        harness.runtime.submit(.bindDisplay(desk))
        wait(for: [ready], timeout: 1.0)
        let writes = harness.radio.writes.count
        harness.runtime.submit(.bindDisplay(shelf))
        let unchanged = waitFor(harness, "still-desk") { $0.bleLink == .ready && $0.binding == .bound }
        unchanged.isInverted = false
        wait(for: [unchanged], timeout: 0.2)
        XCTAssertEqual(harness.box.snapshot?.bleLink, .ready)
        XCTAssertEqual(harness.radio.writes.count, writes)
        switch PersistenceStore(root: harness.root).load() {
        case .loaded(let state):
            XCTAssertEqual(state.boundDisplay?.identifier, desk.uuidString)
        default:
            XCTFail("original Bound Display must remain")
        }
    }

    func testDisconnectKeepsDurableBindingWithoutLiveSession() throws {
        let harness = try RuntimeHarness()
        waitStart(harness)
        harness.radio.peripherals[desk] = FakePeripheralSpec()
        waitForScan(harness)
        let ready = waitFor(harness, "ready") { $0.bleLink == .ready && $0.hasReadyWakeupConfiguration }
        harness.runtime.submit(.bindDisplay(desk))
        wait(for: [ready], timeout: 1.0)
        let dropped = waitFor(harness, "dropped") {
            $0.bleLink == .disconnected && $0.binding == .bound && $0.hasReadyWakeupConfiguration == false
        }
        harness.radio.emitDisconnect(desk)
        wait(for: [dropped], timeout: 1.0)
        XCTAssertEqual(harness.box.snapshot?.panelTrust, .invalid)
    }

    private func waitStart(_ harness: RuntimeHarness) {
        let started = waitFor(harness, "start") { _ in true }
        harness.runtime.start()
        wait(for: [started], timeout: 1.0)
    }

    private func waitForScan(_ harness: RuntimeHarness) {
        let scanning = waitFor(harness, "scan") { $0.bleLink == .scanning && !$0.bindCandidates.isEmpty }
        harness.runtime.submit(.findAndBindDisplay)
        wait(for: [scanning], timeout: 1.0)
    }

    @discardableResult
    private func waitFor(
        _ harness: RuntimeHarness,
        _ name: String,
        _ matcher: @escaping (RuntimeSnapshot) -> Bool
    ) -> XCTestExpectation {
        let exp = expectation(description: name)
        harness.box.match(exp, matcher)
        return exp
    }
}

private final class RuntimeHarness {
    let root: URL
    let radio = FakeRadio()
    let clock = ManualDisplayClock()
    let box = SnapshotProbe()
    let runtime: UsageInkRuntime

    init(simulatedSaveError: PersistenceError? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageink-bind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let radio = self.radio
        let clock = self.clock
        let box = self.box
        runtime = UsageInkRuntime(
            language: .english,
            store: PersistenceStore(root: root, simulatedSaveError: simulatedSaveError),
            makeLink: { queue in
                radio.queue = queue
                clock.queue = queue
                return ReadySessionCoordinator(radio: radio, clock: clock)
            }
        ) { snapshot in
            box.consume(snapshot)
        }
    }
}

private final class SnapshotProbe: @unchecked Sendable {
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
