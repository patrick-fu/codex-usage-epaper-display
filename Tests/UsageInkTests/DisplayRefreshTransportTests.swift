import XCTest
@testable import UsageInk

final class DisplayRefreshTransportTests: XCTestCase {
    private let desk = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    func testRawTransferSendsCompletePlanesThenRefreshWithFlushAndNoForbiddenOpcodes() {
        let harness = RefreshHarness()
        harness.radio.maximumWriteWithoutResponse = 20
        harness.radio.maximumWriteWithResponse = 20
        bindReady(harness, rle: false)
        let black = Data(repeating: 0x00, count: 15_000)
        let red = Data(repeating: 0xFF, count: 15_000)
        XCTAssertTrue(
            harness.coordinator.transferDisplayFrame(
                blackPlane: black,
                redPlane: red,
                sessionGeneration: harness.session!.generation
            )
        )

        let imageWrites = Array(harness.radio.writes.dropFirst())
        let decoded = try! decodeImageWrites(imageWrites, expectedCapacity: 18)
        XCTAssertEqual(decoded.black.count, 15_000)
        XCTAssertEqual(decoded.red.count, 15_000)
        XCTAssertEqual(decoded.black, black)
        XCTAssertEqual(decoded.red, red)
        XCTAssertFalse(decoded.usedRLE)
        XCTAssertTrue(decoded.refreshWithResponse)
        XCTAssertEqual(decoded.blackFlags.first, DisplayLinkUUIDs.writeImageFlagFirst)
        XCTAssertEqual(decoded.redFlags.first, DisplayLinkUUIDs.writeImageFlagFirst | DisplayLinkUUIDs.writeImageFlagRed)
        XCTAssertTrue(decoded.blackFlushWithResponse)
        XCTAssertTrue(decoded.redFlushWithResponse)
        XCTAssertEqual(harness.radio.writesRejectedForFlowControl, 0)
        XCTAssertFalse(harness.completed)
        harness.clock.advance(15)
        XCTAssertTrue(harness.completed)
        XCTAssertNil(harness.failed)
        assertNoForbiddenOpcodes(harness.radio.writes)
        assertNoApplicationAck(harness.radio.writes)
    }

    func testAdvertisedRLEUsesChunkConstrainedShorterWireAndKeepsCodesInsideChunks() {
        let harness = RefreshHarness()
        harness.radio.maximumWriteWithoutResponse = 20
        harness.radio.maximumWriteWithResponse = 20
        bindReady(harness, rle: true)
        let black = Data(repeating: 0x00, count: 15_000)
        let red = Data(repeating: 0xFF, count: 15_000)
        XCTAssertTrue(
            harness.coordinator.transferDisplayFrame(
                blackPlane: black,
                redPlane: red,
                sessionGeneration: harness.session!.generation
            )
        )
        let imageWrites = Array(harness.radio.writes.dropFirst())
        let decoded = try! decodeImageWrites(imageWrites, expectedCapacity: 18)
        XCTAssertTrue(decoded.usedRLE)
        XCTAssertEqual(decoded.black, black)
        XCTAssertEqual(decoded.red, red)
        let payloadBytes = decoded.payloadLength
        XCTAssertLessThan(payloadBytes, 30_000)
        for write in imageWrites where write.data.first == DisplayLinkUUIDs.writeImageOpcode {
            let payload = write.data.dropFirst(2)
            XCTAssertLessThanOrEqual(payload.count, 18)
            XCTAssertNotNil(PlaneRLE.decode(Data(payload)))
        }
        assertNoForbiddenOpcodes(harness.radio.writes)
    }

    func testFlowControlWaitsForCanSendWriteWithoutResponse() {
        let harness = RefreshHarness()
        harness.radio.maximumWriteWithoutResponse = 20
        harness.radio.maximumWriteWithResponse = 20
        bindReady(harness, rle: false)
        harness.radio.writeWithoutResponseCredits = 0
        let black = Data(repeating: 0x12, count: 15_000)
        let red = Data(repeating: 0x34, count: 15_000)
        XCTAssertTrue(
            harness.coordinator.transferDisplayFrame(
                blackPlane: black,
                redPlane: red,
                sessionGeneration: harness.session!.generation
            )
        )
        XCTAssertEqual(harness.radio.writes.map(\.data), [Data([DisplayLinkUUIDs.initOpcode])])
        harness.radio.grantWriteWithoutResponseCredit()
        XCTAssertEqual(harness.radio.writes.count, 2)
        XCTAssertEqual(harness.radio.writes.last?.withResponse, false)
        XCTAssertEqual(harness.radio.writesRejectedForFlowControl, 0)
        harness.radio.setUnlimitedWriteWithoutResponse()
        let decoded = try! decodeImageWrites(Array(harness.radio.writes.dropFirst()), expectedCapacity: 18)
        XCTAssertEqual(decoded.black, black)
        XCTAssertEqual(decoded.red, red)
        XCTAssertTrue(decoded.refreshWithResponse)
    }

    func testUnchangedFingerprintManualForceIsAFullRetransfer() {
        let harness = RefreshHarness()
        bindReady(harness, rle: false)
        let black = Data(repeating: 0x00, count: 15_000)
        let red = Data(repeating: 0xFF, count: 15_000)
        XCTAssertTrue(
            harness.coordinator.transferDisplayFrame(
                blackPlane: black,
                redPlane: red,
                sessionGeneration: harness.session!.generation
            )
        )
        harness.clock.advance(15)
        XCTAssertTrue(harness.completed)
        let firstCount = harness.radio.writes.count
        harness.completed = false
        XCTAssertTrue(
            harness.coordinator.transferDisplayFrame(
                blackPlane: black,
                redPlane: red,
                sessionGeneration: harness.session!.generation
            )
        )
        XCTAssertGreaterThan(harness.radio.writes.count, firstCount)
        let second = Array(harness.radio.writes.dropFirst(firstCount))
        let decoded = try! decodeImageWrites(second, expectedCapacity: ImageTransferPlanner.negotiatedCapacity(
            firmwareMTU: 185,
            withoutResponseLimit: 512,
            withResponseLimit: 512
        ))
        XCTAssertEqual(decoded.black.count, 15_000)
        XCTAssertEqual(decoded.red.count, 15_000)
        XCTAssertTrue(decoded.refreshWithResponse)
    }

    func testDisconnectDuringObservationInvalidatesWithoutSuccess() {
        let harness = RefreshHarness()
        bindReady(harness, rle: false)
        XCTAssertTrue(
            harness.coordinator.transferDisplayFrame(
                blackPlane: Data(repeating: 0x00, count: 15_000),
                redPlane: Data(repeating: 0xFF, count: 15_000),
                sessionGeneration: harness.session!.generation
            )
        )
        XCTAssertFalse(harness.completed)
        harness.radio.emitDisconnect(desk)
        XCTAssertEqual(harness.failed, .disconnected)
        XCTAssertFalse(harness.completed)
        harness.clock.advance(15)
        XCTAssertFalse(harness.completed)
    }

    func testFirstFlagsOnlyAppearOnTheFirstChunkOfEachPlane() {
        let harness = RefreshHarness()
        harness.radio.maximumWriteWithoutResponse = 20
        harness.radio.maximumWriteWithResponse = 20
        bindReady(harness, rle: false)
        XCTAssertTrue(
            harness.coordinator.transferDisplayFrame(
                blackPlane: Data(repeating: 0x00, count: 15_000),
                redPlane: Data(repeating: 0xFF, count: 15_000),
                sessionGeneration: harness.session!.generation
            )
        )
        let imageWrites = Array(harness.radio.writes.dropFirst())
        let decoded = try! decodeImageWrites(imageWrites, expectedCapacity: 18)
        XCTAssertGreaterThan(decoded.blackFlags.count, 1)
        XCTAssertGreaterThan(decoded.redFlags.count, 1)
        XCTAssertEqual(decoded.blackFlags.first, DisplayLinkUUIDs.writeImageFlagFirst)
        XCTAssertEqual(decoded.redFlags.first, DisplayLinkUUIDs.writeImageFlagFirst | DisplayLinkUUIDs.writeImageFlagRed)
        for flag in decoded.blackFlags.dropFirst() {
            XCTAssertEqual(flag & DisplayLinkUUIDs.writeImageFlagFirst, 0)
            XCTAssertEqual(flag & DisplayLinkUUIDs.writeImageFlagRed, 0)
        }
        for flag in decoded.redFlags.dropFirst() {
            XCTAssertEqual(flag & DisplayLinkUUIDs.writeImageFlagFirst, 0)
            XCTAssertEqual(flag & DisplayLinkUUIDs.writeImageFlagRed, DisplayLinkUUIDs.writeImageFlagRed)
        }
        XCTAssertTrue(decoded.blackFlushWithResponse)
        XCTAssertTrue(decoded.redFlushWithResponse)
    }

    func testInvalidCapacityFailsTransferInsteadOfSilentReturn() {
        let harness = RefreshHarness()
        harness.radio.maximumWriteWithoutResponse = 2
        harness.radio.maximumWriteWithResponse = 2
        bindReady(harness, rle: false)
        let started = harness.coordinator.transferDisplayFrame(
            blackPlane: Data(repeating: 0x00, count: 15_000),
            redPlane: Data(repeating: 0xFF, count: 15_000),
            sessionGeneration: harness.session!.generation
        )
        XCTAssertFalse(started)
        XCTAssertEqual(harness.classification, .mtuInvalid)
        XCTAssertNotEqual(harness.link, .ready)
        XCTAssertFalse(harness.completed)
    }

    func testSameSessionRetryWaitsForFreshMTUBeforeResendingPlanes() {
        let harness = RefreshHarness()
        harness.radio.maximumWriteWithoutResponse = 20
        harness.radio.maximumWriteWithResponse = 20
        bindReady(harness, rle: false)
        harness.radio.peripherals[desk]?.autoMTUText = nil
        harness.radio.holdWriteAcknowledgements = true
        XCTAssertTrue(
            harness.coordinator.transferDisplayFrame(
                blackPlane: Data(repeating: 0x00, count: 15_000),
                redPlane: Data(repeating: 0xFF, count: 15_000),
                sessionGeneration: harness.session!.generation
            )
        )
        XCTAssertTrue(harness.radio.writes.contains { $0.opcode == DisplayLinkUUIDs.writeImageOpcode })
        harness.radio.dropDeferredWriteAcknowledgements()
        let writesBeforeRetry = harness.radio.writes.count
        harness.clock.advance(30)
        XCTAssertEqual(harness.link, .initializing)
        XCTAssertEqual(harness.radio.writes.last?.data, Data([DisplayLinkUUIDs.initOpcode]))
        XCTAssertEqual(harness.classification, .planeTimeout)
        harness.radio.acknowledgeNextWrite()
        XCTAssertEqual(harness.radio.writes.count, writesBeforeRetry + 1)
        XCTAssertFalse(harness.radio.writes.dropFirst(writesBeforeRetry + 1).contains { $0.opcode == DisplayLinkUUIDs.writeImageOpcode })
        harness.radio.dropDeferredWriteAcknowledgements()
        harness.radio.holdWriteAcknowledgements = false
        harness.radio.emitValue(
            identifier: desk,
            characteristic: DisplayLinkUUIDs.data,
            value: Data("mtu=185 rle=1 t=9".utf8)
        )
        XCTAssertEqual(harness.link, .ready)
        let retryWrites = Array(harness.radio.writes.dropFirst(writesBeforeRetry + 1))
        XCTAssertTrue(retryWrites.contains { $0.opcode == DisplayLinkUUIDs.writeImageOpcode })
        XCTAssertEqual(retryWrites.last?.data, Data([DisplayLinkUUIDs.refreshOpcode]))
        XCTAssertTrue(retryWrites.last?.withResponse ?? false)
        let decoded = try! decodeImageWrites(retryWrites, expectedCapacity: 18)
        XCTAssertEqual(decoded.black.count, 15_000)
        XCTAssertEqual(decoded.red.count, 15_000)
        XCTAssertTrue(decoded.usedRLE)
        XCTAssertTrue(decoded.blackFlushWithResponse)
        XCTAssertTrue(decoded.redFlushWithResponse)
        XCTAssertFalse(harness.completed)
        harness.clock.advance(15)
        XCTAssertTrue(harness.completed)
    }

    func testRetryExhaustedFailsTransferAndKeepsNoSuccess() {
        let harness = RefreshHarness()
        harness.radio.maximumWriteWithoutResponse = 20
        harness.radio.maximumWriteWithResponse = 20
        bindReady(harness, rle: false)
        harness.radio.holdWriteAcknowledgements = true
        XCTAssertTrue(
            harness.coordinator.transferDisplayFrame(
                blackPlane: Data(repeating: 0x00, count: 15_000),
                redPlane: Data(repeating: 0xFF, count: 15_000),
                sessionGeneration: harness.session!.generation
            )
        )
        harness.radio.dropDeferredWriteAcknowledgements()
        harness.clock.advance(30)
        XCTAssertEqual(harness.link, .initializing)
        harness.radio.dropDeferredWriteAcknowledgements()
        harness.radio.emitValue(
            identifier: desk,
            characteristic: DisplayLinkUUIDs.data,
            value: Data("mtu=185".utf8)
        )
        XCTAssertEqual(harness.link, .ready)
        harness.radio.dropDeferredWriteAcknowledgements()
        harness.clock.advance(30)
        XCTAssertEqual(harness.failed, .planeTimeout)
        XCTAssertFalse(harness.completed)
        XCTAssertEqual(harness.link, .ready)
    }

    func testHostSleepCancelsObservationAndDropsReadySession() {
        let harness = RefreshHarness()
        bindReady(harness, rle: false)
        XCTAssertTrue(
            harness.coordinator.transferDisplayFrame(
                blackPlane: Data(repeating: 0x00, count: 15_000),
                redPlane: Data(repeating: 0xFF, count: 15_000),
                sessionGeneration: harness.session!.generation
            )
        )
        XCTAssertFalse(harness.completed)
        harness.coordinator.noteHostWillSleep()
        XCTAssertEqual(harness.failed, .disconnected)
        XCTAssertNotEqual(harness.link, .ready)
        harness.clock.advance(15)
        XCTAssertFalse(harness.completed)
    }

        private func bindReady(_ harness: RefreshHarness, rle: Bool) {
        var spec = FakePeripheralSpec()
        spec.autoMTUText = rle ? "mtu=185 rle=1 t=1" : "mtu=185"
        harness.radio.peripherals[desk] = spec
        harness.coordinator.attach()
        harness.coordinator.startBindScan()
        harness.coordinator.bind(identifier: desk)
        XCTAssertEqual(harness.link, .ready)
        XCTAssertEqual(harness.session?.rleEnabled, rle)
        XCTAssertEqual(harness.radio.writes.map(\.data), [Data([DisplayLinkUUIDs.initOpcode])])
    }

    private func assertNoForbiddenOpcodes(_ writes: [BLEWriteRecord]) {
        for write in writes {
            if let opcode = write.opcode {
                XCTAssertFalse(DisplayLinkUUIDs.forbiddenOpcodes.contains(opcode), "forbidden opcode \(opcode)")
            }
        }
    }

    private func assertNoApplicationAck(_ writes: [BLEWriteRecord]) {
        for write in writes {
            XCTAssertNotEqual(write.opcode, 0x91)
            XCTAssertFalse(write.data.count >= 3 && write.data[0] == 0x30 && write.data[1] == 0xA5)
        }
    }
}

private enum DecodeFailure: Error {
    case missingOpcode
    case invalidRLE
}

private func decodeRLE(_ payload: Data) throws -> Data {
    guard let decoded = PlaneRLE.decode(payload) else {
        throw DecodeFailure.invalidRLE
    }
    return decoded
}

private struct DecodedTransfer {

    var black: Data
    var red: Data
    var usedRLE: Bool
    var blackFlags: [UInt8]
    var redFlags: [UInt8]
    var blackFlushWithResponse: Bool
    var redFlushWithResponse: Bool
    var refreshWithResponse: Bool
    var payloadLength: Int
}

private func decodeImageWrites(_ writes: [BLEWriteRecord], expectedCapacity: Int) throws -> DecodedTransfer {
    var black = Data()
    var red = Data()
    var blackFlags: [UInt8] = []
    var redFlags: [UInt8] = []
    var usedRLE = false
    var sawBlack = false
    var sawRed = false
    var lastBlackWithResponse = false
    var lastRedWithResponse = false
    var refreshWithResponse = false
    var payloadLength = 0
    var sawRefresh = false
    for write in writes {
        guard let opcode = write.opcode else { throw DecodeFailure.missingOpcode }
        if opcode == DisplayLinkUUIDs.initOpcode {
            continue
        }
        if opcode == DisplayLinkUUIDs.refreshOpcode {
            XCTAssertFalse(sawRefresh)
            XCTAssertTrue(sawBlack && sawRed)
            XCTAssertEqual(write.data, Data([DisplayLinkUUIDs.refreshOpcode]))
            XCTAssertTrue(write.withResponse)
            refreshWithResponse = true
            sawRefresh = true
            continue
        }
        XCTAssertEqual(opcode, DisplayLinkUUIDs.writeImageOpcode)
        XCTAssertGreaterThanOrEqual(write.data.count, 3)
        let flags = write.data[1]
        let payload = Data(write.data.dropFirst(2))
        XCTAssertLessThanOrEqual(payload.count, expectedCapacity)
        payloadLength += payload.count
        let rle = flags & DisplayLinkUUIDs.writeImageFlagRLE != 0
        if rle {
            usedRLE = true
        }
        let decoded = rle ? try decodeRLE(payload) : payload
        if flags & DisplayLinkUUIDs.writeImageFlagRed == 0 {
            XCTAssertFalse(sawRed)
            if blackFlags.isEmpty {
                XCTAssertEqual(flags & DisplayLinkUUIDs.writeImageFlagFirst, DisplayLinkUUIDs.writeImageFlagFirst)
            }
            blackFlags.append(flags)
            black.append(decoded)
            sawBlack = true
            lastBlackWithResponse = write.withResponse
        } else {
            XCTAssertTrue(sawBlack)
            if redFlags.isEmpty {
                XCTAssertEqual(flags & DisplayLinkUUIDs.writeImageFlagFirst, DisplayLinkUUIDs.writeImageFlagFirst)
            }
            redFlags.append(flags)
            red.append(decoded)
            sawRed = true
            lastRedWithResponse = write.withResponse
        }
    }
    XCTAssertTrue(sawRefresh)
    return DecodedTransfer(
        black: black,
        red: red,
        usedRLE: usedRLE,
        blackFlags: blackFlags,
        redFlags: redFlags,
        blackFlushWithResponse: lastBlackWithResponse,
        redFlushWithResponse: lastRedWithResponse,
        refreshWithResponse: refreshWithResponse,
        payloadLength: payloadLength
    )
}

private final class RefreshHarness: DisplayLinkDelegate {
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
