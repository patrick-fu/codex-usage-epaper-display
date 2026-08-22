import XCTest
@testable import UsageInk

final class ReadySessionCoordinatorTests: XCTestCase {
    private let desk = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    func testScanPublishesNameLiveRSSIAndShortIdentifier() {
        let harness = CoordinatorHarness()
        harness.radio.peripherals[desk] = FakePeripheralSpec(name: "UsageInk-Desk", rssi: -38)
        harness.coordinator.attach()
        harness.coordinator.startBindScan()

        XCTAssertEqual(harness.link, .scanning)
        XCTAssertEqual(harness.candidates.count, 1)
        XCTAssertEqual(harness.candidates[0].advertisedName, "UsageInk-Desk")
        XCTAssertEqual(harness.candidates[0].rssi, -38)
        XCTAssertEqual(harness.candidates[0].shortIdentifier, "6E5F")

        harness.radio.updateRSSI(desk, rssi: -21)
        XCTAssertEqual(harness.candidates[0].rssi, -21)
    }

    func testCompatibleDisplayReachesReadyAfterConfigInitAndFreshMTU() {
        let harness = CoordinatorHarness()
        harness.radio.peripherals[desk] = FakePeripheralSpec()
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.coordinator.bind(identifier: desk)

        XCTAssertEqual(harness.link, .ready)
        XCTAssertEqual(harness.session?.mtu, 185)
        XCTAssertFalse(harness.session?.rleEnabled ?? true)
        XCTAssertEqual(harness.radio.writes.map(\.data), [Data([DisplayLinkUUIDs.initOpcode])])
        XCTAssertEqual(harness.radio.writes.first?.withResponse, true)
        XCTAssertFalse(harness.radio.writes.contains { record in
            DisplayLinkUUIDs.forbiddenOpcodes.contains(record.opcode ?? 255)
                || record.opcode == DisplayLinkUUIDs.setConfigOpcode
        })
    }

    func testIndependentRLEAndTimeTagsDoNotReplaceFreshMTU() {
        let harness = CoordinatorHarness()
        var spec = FakePeripheralSpec()
        spec.autoMTUText = nil
        harness.radio.peripherals[desk] = spec
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.coordinator.bind(identifier: desk)
        XCTAssertEqual(harness.link, .initializing)

        harness.radio.emitValue(
            identifier: desk,
            characteristic: DisplayLinkUUIDs.data,
            value: Data("rle=1 t=1700000000".utf8)
        )
        XCTAssertEqual(harness.link, .initializing)
        harness.radio.emitValue(
            identifier: desk,
            characteristic: DisplayLinkUUIDs.data,
            value: Data("mtu=185".utf8)
        )
        XCTAssertEqual(harness.link, .ready)
        XCTAssertEqual(harness.session?.rleEnabled, true)
        XCTAssertEqual(harness.session?.timeUnixSeconds, 1_700_000_000)
        XCTAssertEqual(harness.session?.mtu, 185)
    }

    func testMissingVersionCharacteristicIsTreatedAsIncompatibleFirmware() {
        let harness = CoordinatorHarness()
        var spec = FakePeripheralSpec()
        spec.characteristics = [.dataDefault]
        spec.versionByte = nil
        harness.radio.peripherals[desk] = spec
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.coordinator.bind(identifier: desk)

        XCTAssertEqual(harness.classification, .firmwareIncompatible)
        XCTAssertNotEqual(harness.link, .ready)
        XCTAssertTrue(harness.radio.writes.isEmpty)
    }

    func testLegacyFirmwareDoesNotBindOrSendInit() {
        let harness = CoordinatorHarness()
        var spec = FakePeripheralSpec()
        spec.versionByte = 0x15
        harness.radio.peripherals[desk] = spec
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.coordinator.bind(identifier: desk)

        XCTAssertEqual(harness.classification, .firmwareIncompatible)
        XCTAssertTrue(harness.radio.writes.isEmpty)
        XCTAssertNil(harness.session)
    }

    func testMissingDataPropertiesAreRejected() {
        let harness = CoordinatorHarness()
        var spec = FakePeripheralSpec()
        spec.characteristics = [
            RadioCharacteristic(
                uuid: DisplayLinkUUIDs.data,
                canRead: true,
                canWriteWithResponse: true,
                canWriteWithoutResponse: false,
                canNotify: true
            ),
            .versionDefault,
        ]
        harness.radio.peripherals[desk] = spec
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.coordinator.bind(identifier: desk)
        XCTAssertEqual(harness.classification, .characteristicMissing)
        XCTAssertTrue(harness.radio.writes.isEmpty)
    }

    func testMissingServiceIsRejected() {
        let harness = CoordinatorHarness()
        var spec = FakePeripheralSpec()
        spec.services = [UUID()]
        harness.radio.peripherals[desk] = spec
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.coordinator.bind(identifier: desk)
        XCTAssertEqual(harness.classification, .serviceMissing)
    }

    func testFreshMTUMayArriveBeforeWriteCallback() {
        let harness = CoordinatorHarness()
        var spec = FakePeripheralSpec()
        spec.autoMTUText = "mtu=185"
        spec.mtuBeforeWriteAck = true
        harness.radio.peripherals[desk] = spec
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.coordinator.bind(identifier: desk)
        XCTAssertEqual(harness.link, .ready)
        XCTAssertEqual(harness.session?.mtu, 185)
    }

    func testPreInitNotifyIsRejectedAndAppleDefaultMTUIsInvalid() {
        let first = CoordinatorHarness()
        var spec = FakePeripheralSpec()
        spec.extraFirstNotify = Data("mtu=185 rle=1 t=1".utf8)
        spec.autoConfig = BLETestFixtures.sampleConfig
        first.radio.peripherals[desk] = spec
        first.coordinator.attach()
        first.coordinator.startBindScan()
        first.coordinator.bind(identifier: desk)
        XCTAssertEqual(first.classification, .callbackAmbiguous)
        XCTAssertTrue(first.radio.writes.isEmpty)
        XCTAssertNil(first.session)

        let second = CoordinatorHarness()
        var later = FakePeripheralSpec()
        later.autoMTUText = "mtu=20"
        second.radio.peripherals[desk] = later
        second.coordinator.attach()
        second.coordinator.startBindScan()
        second.coordinator.bind(identifier: desk)
        XCTAssertEqual(second.classification, .mtuInvalid)
        XCTAssertNotEqual(second.link, .ready)
    }

    func testPreviousSessionRLEDoesNotPolluteNextInit() {
        let harness = CoordinatorHarness()
        var spec = FakePeripheralSpec()
        spec.autoMTUText = "mtu=185 rle=1 t=1700000000"
        harness.radio.peripherals[desk] = spec
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.coordinator.bind(identifier: desk)
        XCTAssertEqual(harness.session?.rleEnabled, true)
        harness.coordinator.confirmBoundIdentity(desk)
        harness.radio.emitDisconnect(desk)

        spec.autoMTUText = "mtu=185"
        harness.radio.peripherals[desk] = spec
        harness.session = nil
        harness.coordinator.recover(identifier: desk)
        XCTAssertEqual(harness.link, .ready)
        XCTAssertEqual(harness.session?.mtu, 185)
        XCTAssertEqual(harness.session?.rleEnabled, false)
        XCTAssertNil(harness.session?.timeUnixSeconds)
    }

    func testSubscribeFailedIsClassifiedWithoutInit() {
        let harness = CoordinatorHarness()
        var spec = FakePeripheralSpec()
        spec.notifySucceeds = false
        harness.radio.peripherals[desk] = spec
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.coordinator.bind(identifier: desk)
        XCTAssertEqual(harness.classification, .subscribeFailed)
        XCTAssertTrue(harness.radio.writes.isEmpty)
    }

    func testNonOneByteVersionIsTreatedAsIncompatibleFirmware() {
        let harness = CoordinatorHarness()
        var spec = FakePeripheralSpec()
        spec.versionPayload = Data([0x16, 0x00])
        harness.radio.peripherals[desk] = spec
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.coordinator.bind(identifier: desk)
        XCTAssertEqual(harness.classification, .firmwareIncompatible)
        XCTAssertTrue(harness.radio.writes.isEmpty)
    }

    func testDisconnectDropsReadySession() {
        let harness = CoordinatorHarness()
        harness.radio.peripherals[desk] = FakePeripheralSpec()
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.coordinator.bind(identifier: desk)
        XCTAssertEqual(harness.link, .ready)
        harness.coordinator.confirmBoundIdentity(desk)
        harness.radio.emitDisconnect(desk)
        XCTAssertEqual(harness.classification, .disconnected)
        XCTAssertEqual(harness.link, .disconnected)
    }

    func testCoordinatorDoesNotRecoverUntilAsked() {
        let harness = CoordinatorHarness()
        harness.radio.peripherals[desk] = FakePeripheralSpec()
        harness.coordinator.attach()
        harness.coordinator.confirmBoundIdentity(desk)
        harness.radio.setAvailability(.unauthorized)
        harness.radio.setAvailability(.poweredOn)
        XCTAssertNotEqual(harness.link, .ready)
        XCTAssertEqual(harness.link, .disconnected)
        XCTAssertTrue(harness.radio.writes.isEmpty)
        harness.coordinator.recover(identifier: desk)
        XCTAssertEqual(harness.link, .ready)
        XCTAssertEqual(harness.radio.writes.count, 1)
    }

    func testClassificationCopyIsLocalizedNotCamelCase() {
        for classification in [
            BLEClassification.boundDisplayNotFound,
            .connectFailed,
            .subscribeFailed,
            .configTimeout,
            .mtuInvalid,
            .disconnected,
            .callbackAmbiguous,
        ] {
            let english = classification.menuText(language: .english)
            let chinese = classification.menuText(language: .simplifiedChinese)
            XCTAssertNotEqual(english, classification.rawValue)
            XCTAssertFalse(english.first?.isLowercase ?? true)
            XCTAssertNotEqual(english, chinese)
            XCTAssertFalse(english.isEmpty)
            XCTAssertFalse(chinese.isEmpty)
        }
    }

    func testTimeoutsUseTheInjectedClock() {
        let harness = CoordinatorHarness()
        harness.radio.peripherals[desk] = FakePeripheralSpec()
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.clock.advance(15)
        XCTAssertEqual(harness.classification, nil)
        XCTAssertEqual(harness.link, .unbound)

        let empty = CoordinatorHarness()
        empty.coordinator.attach()
        empty.coordinator.startBindScan()
        empty.clock.advance(15)
        XCTAssertEqual(empty.classification, .boundDisplayNotFound)

        let connecting = CoordinatorHarness()
        var spec = FakePeripheralSpec()
        spec.connectHangs = true
        connecting.radio.peripherals[desk] = spec
        connecting.coordinator.attach()
        connecting.coordinator.startBindScan()
        connecting.coordinator.bind(identifier: desk)
        XCTAssertEqual(connecting.link, .connecting)
        connecting.clock.advance(10)
        XCTAssertEqual(connecting.classification, .connectFailed)

        let config = CoordinatorHarness()
        var silent = FakePeripheralSpec()
        silent.autoConfig = nil
        silent.autoMTUText = nil
        config.radio.peripherals[desk] = silent
        config.coordinator.attach()
        config.coordinator.startBindScan()
        config.coordinator.bind(identifier: desk)
        XCTAssertEqual(config.link, .awaitingConfig)
        config.clock.advance(5)
        XCTAssertEqual(config.classification, .configTimeout)
    }

    func testBluetoothDenialClearsCandidatesAndReEnableAllowsScan() {
        let harness = CoordinatorHarness()
        harness.radio.peripherals[desk] = FakePeripheralSpec()
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        XCTAssertFalse(harness.candidates.isEmpty)
        harness.radio.setAvailability(.unauthorized)
        XCTAssertEqual(harness.classification, .bluetoothUnauthorized)
        XCTAssertEqual(harness.link, .unavailable)
        XCTAssertTrue(harness.candidates.isEmpty)

        harness.radio.setAvailability(.poweredOn)
        harness.coordinator.startBindScan()
        XCTAssertEqual(harness.link, .scanning)
        XCTAssertEqual(harness.candidates.count, 1)
    }
}

private final class CoordinatorHarness: DisplayLinkDelegate {
    let radio = FakeRadio()
    let clock = ManualDisplayClock()
    let coordinator: ReadySessionCoordinator
    var link: BLELinkState = .unbound
    var candidates: [BindCandidate] = []
    var classification: BLEClassification?
    var session: ReadyBLESession?

    init() {
        coordinator = ReadySessionCoordinator(radio: radio, clock: clock)
        coordinator.delegate = self
    }

    func displayLinkDidChangeAvailability(_ availability: RadioAvailability) {}
    func displayLinkDidUpdateLink(_ state: BLELinkState) { link = state }
    func displayLinkDidUpdateCandidates(_ candidates: [BindCandidate]) { self.candidates = candidates }
    func displayLinkDidClassify(_ classification: BLEClassification) { self.classification = classification }
    func displayLinkDidBecomeReady(_ session: ReadyBLESession) { self.session = session }
    func displayLinkDidDisconnect() {}
}
