import AppKit
import XCTest
@testable import UsageInk

final class WakeupPinConsentTests: XCTestCase {
    private let desk = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    func testParserAndBilingualConfirmationShowOldAndNewValues() {
        XCTAssertEqual(WakeupPin.parse("12"), 12)
        XCTAssertEqual(WakeupPin.parse("0"), 0)
        XCTAssertEqual(WakeupPin.parse("31"), 31)
        XCTAssertEqual(WakeupPin.parse("disabled"), WakeupPin.disabled)
        XCTAssertEqual(WakeupPin.parse(" 0xFF "), WakeupPin.disabled)
        XCTAssertEqual(WakeupPin.parse("禁用"), WakeupPin.disabled)
        XCTAssertNil(WakeupPin.parse(""))
        XCTAssertNil(WakeupPin.parse("   "))
        XCTAssertNil(WakeupPin.parse("\n\t"))
        XCTAssertNil(WakeupPin.parse("ff"))
        XCTAssertNil(WakeupPin.parse("32"))
        XCTAssertNil(WakeupPin.parse("0xFE"))
        XCTAssertNil(WakeupPin.parse("abc"))
        XCTAssertFalse(WakeupPin.isAllowed(32))
        XCTAssertFalse(WakeupPin.isAllowed(0xFE))

        let copy = WakeupPinCopy.confirmationInformation(from: 0xFF, to: 12)
        XCTAssertTrue(copy.contains("Disabled"))
        XCTAssertTrue(copy.contains("12"))
        XCTAssertTrue(copy.contains("已禁用"))
        XCTAssertTrue(copy.contains("将唤醒引脚"))
        XCTAssertTrue(WakeupPinCopy.confirmationMessage.contains("Configure Wakeup Pin"))
        XCTAssertTrue(WakeupPinCopy.confirmationMessage.contains("配置唤醒引脚"))
    }

    func testReadySessionWriteSendsOnlyWakeupByteAndLeavesBinding() throws {
        let harness = try RuntimeHarness()
        let session = try becomeReady(harness)
        XCTAssertEqual(session.pin, 0xFF)
        let before = harness.radio.writes

        let done = waitFor(harness, "written") { $0.wakeupConfiguration?.pin == 12 }
        harness.runtime.submit(
            .configureWakeupPin(
                WakeupPinWriteRequest(pin: 12, sessionGeneration: session.sessionGeneration, configDigest: session.configDigest)
            )
        )
        wait(for: [done], timeout: 1.0)

        let snapshot = try XCTUnwrap(harness.box.snapshot)
        XCTAssertEqual(snapshot.binding, .bound)
        XCTAssertEqual(snapshot.bleLink, .ready)
        XCTAssertEqual(snapshot.wakeupConfiguration?.pin, 12)
        XCTAssertTrue(snapshot.hasReadyWakeupConfiguration)

        let added = Array(harness.radio.writes.dropFirst(before.count))
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added[0].opcode, DisplayLinkUUIDs.setConfigOpcode)
        XCTAssertEqual(added[0].withResponse, true)
        XCTAssertEqual(added[0].data.count, 14)
        XCTAssertEqual(Array(added[0].data), [0x90, 8, 7, 6, 5, 4, 3, 2, 1, 12, 0, 1, 0, 1])
        XCTAssertFalse(harness.radio.writes.contains { DisplayLinkUUIDs.forbiddenOpcodes.contains($0.opcode ?? 255) })
        XCTAssertEqual(
            harness.radio.writes.map(\.opcode),
            [DisplayLinkUUIDs.initOpcode, DisplayLinkUUIDs.setConfigOpcode]
        )

        let json = try String(contentsOf: harness.root.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(json.lowercased().contains("wakeup"))
        XCTAssertFalse(json.lowercased().contains("consent"))
        XCTAssertTrue(json.contains(desk.uuidString))
    }

    func testDisabledPinAndInvalidInputDoNotWriteForbiddenOpcodes() throws {
        let harness = try RuntimeHarness()
        var spec = FakePeripheralSpec()
        spec.autoConfig = Data([8, 7, 6, 5, 4, 3, 2, 1, 12, 0, 1, 0, 1])
        harness.radio.peripherals[desk] = spec
        waitStart(harness)
        waitForScan(harness)
        let ready = waitFor(harness, "ready") { $0.bleLink == .ready && $0.hasReadyWakeupConfiguration }
        harness.runtime.submit(.bindDisplay(desk))
        wait(for: [ready], timeout: 1.0)
        let session = try XCTUnwrap(harness.box.snapshot?.wakeupConfiguration)
        let before = harness.radio.writes.count

        harness.runtime.submit(
            .configureWakeupPin(
                WakeupPinWriteRequest(pin: 32, sessionGeneration: session.sessionGeneration, configDigest: session.configDigest)
            )
        )
        harness.runtime.submit(
            .configureWakeupPin(
                WakeupPinWriteRequest(pin: 0xFE, sessionGeneration: session.sessionGeneration, configDigest: session.configDigest)
            )
        )
        waitSettled()
        XCTAssertEqual(harness.radio.writes.count, before)
        XCTAssertEqual(harness.box.snapshot?.wakeupConfiguration?.pin, 12)

        let disabled = waitFor(harness, "disabled") { $0.wakeupConfiguration?.pin == WakeupPin.disabled }
        harness.runtime.submit(
            .configureWakeupPin(
                WakeupPinWriteRequest(
                    pin: WakeupPin.disabled,
                    sessionGeneration: session.sessionGeneration,
                    configDigest: session.configDigest
                )
            )
        )
        wait(for: [disabled], timeout: 1.0)
        XCTAssertFalse(harness.radio.writes.contains { DisplayLinkUUIDs.forbiddenOpcodes.contains($0.opcode ?? 255) })
        XCTAssertEqual(harness.radio.writes.last?.opcode, DisplayLinkUUIDs.setConfigOpcode)
        XCTAssertEqual(Array(try XCTUnwrap(harness.radio.writes.last).data.dropFirst())[8], WakeupPin.disabled)
    }

    func testCancelDisconnectSleepConfigChangeAndStaleConfirmationWriteNothing() throws {
        let harness = try RuntimeHarness()
        let first = try becomeReady(harness)
        let originalWrites = harness.radio.writes.count

        harness.radio.emitDisconnect(desk)
        let dropped = waitFor(harness, "dropped") { $0.bleLink == .disconnected && $0.hasReadyWakeupConfiguration == false }
        wait(for: [dropped], timeout: 1.0)
        harness.runtime.submit(
            .configureWakeupPin(
                WakeupPinWriteRequest(pin: 4, sessionGeneration: first.sessionGeneration, configDigest: first.configDigest)
            )
        )
        waitSettled()
        XCTAssertEqual(harness.radio.writes.count, originalWrites)

        let recovered = waitFor(harness, "recovered") { $0.bleLink == .ready && $0.hasReadyWakeupConfiguration }
        harness.radio.peripherals[desk] = FakePeripheralSpec()
        harness.runtime.submit(.bindDisplay(desk))
        wait(for: [recovered], timeout: 1.0)
        let second = try XCTUnwrap(harness.box.snapshot?.wakeupConfiguration)
        XCTAssertNotEqual(second.sessionGeneration, first.sessionGeneration)
        let afterRecover = harness.radio.writes.count
        harness.runtime.submit(
            .configureWakeupPin(
                WakeupPinWriteRequest(pin: 9, sessionGeneration: first.sessionGeneration, configDigest: first.configDigest)
            )
        )
        waitSettled()
        XCTAssertEqual(harness.radio.writes.count, afterRecover)
        XCTAssertEqual(harness.box.snapshot?.wakeupConfiguration?.pin, 0xFF)

        var changed = Array(BLETestFixtures.sampleConfig)
        changed[0] = 11
        harness.radio.emitValue(identifier: desk, characteristic: DisplayLinkUUIDs.data, value: Data(changed))
        let digestChanged = waitFor(harness, "digest") { $0.wakeupConfiguration?.configDigest != second.configDigest }
        wait(for: [digestChanged], timeout: 1.0)
        let afterChange = harness.radio.writes.count
        harness.runtime.submit(
            .configureWakeupPin(
                WakeupPinWriteRequest(pin: 6, sessionGeneration: second.sessionGeneration, configDigest: second.configDigest)
            )
        )
        waitSettled()
        XCTAssertEqual(harness.radio.writes.count, afterChange)

        let sleep = try RuntimeHarness()
        let sleepSession = try becomeReady(sleep)
        let sleepWrites = sleep.radio.writes.count
        let unavailable = waitFor(sleep, "sleep") { $0.bleLink == .unavailable }
        sleep.radio.setAvailability(.unavailable)
        wait(for: [unavailable], timeout: 1.0)
        sleep.runtime.submit(
            .configureWakeupPin(
                WakeupPinWriteRequest(
                    pin: 3,
                    sessionGeneration: sleepSession.sessionGeneration,
                    configDigest: sleepSession.configDigest
                )
            )
        )
        waitSettled()
        XCTAssertEqual(sleep.radio.writes.count, sleepWrites)
        XCTAssertFalse(sleep.radio.writes.contains { $0.opcode == DisplayLinkUUIDs.setConfigOpcode })
    }

    func testConfigureWakeupPinDoesNothingWithoutReadySession() throws {
        let harness = try RuntimeHarness()
        waitStart(harness)
        harness.runtime.submit(
            .configureWakeupPin(
                WakeupPinWriteRequest(pin: 1, sessionGeneration: 1, configDigest: BLETestFixtures.sampleConfig)
            )
        )
        waitSettled()
        XCTAssertTrue(harness.radio.writes.isEmpty)
        XCTAssertFalse(harness.box.snapshot?.hasReadyWakeupConfiguration ?? true)
    }

    private func waitSettled() {
        let idle = expectation(description: "settled")
        idle.isInverted = true
        wait(for: [idle], timeout: 0.2)
    }

    @discardableResult
    private func becomeReady(_ harness: RuntimeHarness) throws -> ReadyWakeupConfiguration {
        waitStart(harness)
        harness.radio.peripherals[desk] = FakePeripheralSpec()
        waitForScan(harness)
        let ready = waitFor(harness, "ready") { $0.bleLink == .ready && $0.wakeupConfiguration != nil }
        harness.runtime.submit(.bindDisplay(desk))
        wait(for: [ready], timeout: 1.0)
        return try XCTUnwrap(harness.box.snapshot?.wakeupConfiguration)
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

@MainActor
final class WakeupPinMenuConsentTests: XCTestCase {
    func testImmediateConfirmationShowsOldAndNewAndCancelWritesNothing() throws {
        let prompt = ScriptedConfirmationPrompt()
        prompt.pinToReturn = 12
        prompt.confirmChange = false
        let controller = StatusItemController(
            settings: SettingsPanelController(),
            confirmations: prompt
        )
        let box = CommandBox()
        controller.submit = { box.command = $0 }
        controller.apply(
            RuntimeSnapshot(
                statusSummary: "ready",
                binding: .bound,
                displayStyle: .quotaFocus,
                hasReadyWakeupConfiguration: true,
                wakeupConfiguration: ReadyWakeupConfiguration(
                    pin: 0xFF,
                    sessionGeneration: 4,
                    configDigest: BLETestFixtures.sampleConfig
                )
            )
        )
        let menu = try XCTUnwrap(controller.menu)
        let index = try XCTUnwrap(menu.items.firstIndex(where: { $0.title == "Configure Wakeup Pin…" }))
        menu.performActionForItem(at: index)

        XCTAssertEqual(prompt.requestedCurrent, 0xFF)
        XCTAssertEqual(prompt.confirmedFrom, 0xFF)
        XCTAssertEqual(prompt.confirmedTo, 12)
        XCTAssertTrue(
            WakeupPinCopy.confirmationInformation(from: 0xFF, to: 12).contains("Disabled")
        )
        XCTAssertNil(box.command)
    }

    func testConfirmedPinSubmitsCapturedGenerationAndDigest() throws {
        let prompt = ScriptedConfirmationPrompt()
        prompt.pinToReturn = 7
        prompt.confirmChange = true
        let controller = StatusItemController(
            settings: SettingsPanelController(),
            confirmations: prompt
        )
        let box = CommandBox()
        controller.submit = { box.command = $0 }
        let digest = BLETestFixtures.sampleConfig
        controller.apply(
            RuntimeSnapshot(
                statusSummary: "ready",
                binding: .bound,
                displayStyle: .quotaFocus,
                hasReadyWakeupConfiguration: true,
                wakeupConfiguration: ReadyWakeupConfiguration(
                    pin: 1,
                    sessionGeneration: 8,
                    configDigest: digest
                )
            )
        )
        let menu = try XCTUnwrap(controller.menu)
        let index = try XCTUnwrap(menu.items.firstIndex(where: { $0.title == "Configure Wakeup Pin…" }))
        menu.performActionForItem(at: index)
        XCTAssertEqual(
            box.command,
            .configureWakeupPin(
                WakeupPinWriteRequest(pin: 7, sessionGeneration: 8, configDigest: digest)
            )
        )
    }

    func testInvalidEnteredPinDoesNotConfirmOrSubmit() throws {
        let prompt = ScriptedConfirmationPrompt()
        prompt.pinToReturn = 32
        prompt.confirmChange = true
        let controller = StatusItemController(
            settings: SettingsPanelController(),
            confirmations: prompt
        )
        let box = CommandBox()
        controller.submit = { box.command = $0 }
        controller.apply(
            RuntimeSnapshot(
                statusSummary: "ready",
                binding: .bound,
                displayStyle: .quotaFocus,
                hasReadyWakeupConfiguration: true,
                wakeupConfiguration: ReadyWakeupConfiguration(
                    pin: 0xFF,
                    sessionGeneration: 1,
                    configDigest: BLETestFixtures.sampleConfig
                )
            )
        )
        let menu = try XCTUnwrap(controller.menu)
        let index = try XCTUnwrap(menu.items.firstIndex(where: { $0.title == "Configure Wakeup Pin…" }))
        menu.performActionForItem(at: index)
        XCTAssertEqual(prompt.confirmCount, 0)
        XCTAssertNil(box.command)
    }
}

@MainActor
private final class ScriptedConfirmationPrompt: ConfirmationPrompting {
    var pinToReturn: UInt8? = 12
    var confirmChange = true
    var requestedCurrent: UInt8?
    var confirmedFrom: UInt8?
    var confirmedTo: UInt8?
    var confirmCount = 0

    func confirmUnbindDisplay() -> Bool { false }
    func confirmRebuildLocalMetrics() -> Bool { false }
    func confirmResetUsageInkData() -> Bool { false }

    func requestWakeupPinValue(current: UInt8) -> UInt8? {
        requestedCurrent = current
        return pinToReturn
    }

    func confirmWakeupPinChange(from old: UInt8, to new: UInt8) -> Bool {
        confirmCount += 1
        confirmedFrom = old
        confirmedTo = new
        return confirmChange
    }
}

private final class CommandBox: @unchecked Sendable {
    var command: RuntimeCommand?
}

private final class RuntimeHarness {
    let root: URL
    let radio = FakeRadio()
    let clock = ManualDisplayClock()
    let box = SnapshotProbe()
    let runtime: UsageInkRuntime

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageink-wakeup-\(UUID().uuidString)", isDirectory: true)
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
