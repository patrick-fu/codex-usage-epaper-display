import Foundation

private enum RadioWriteOperation {
    case initialize
    case setConfig(EPDConfig)
    case planeFlush
    case refreshOpcode
    case retryInitialize
}

private struct TransferSession {
    var generation: UInt64
    var chunks: [PlannedImageChunk]
    var index: Int
    var retryUsed: Bool
    var waitingForCredit: Bool
    var observing: Bool
}

private struct InFlightWrite {
    var operationID: UInt64
    var operation: RadioWriteOperation
}

final class ReadySessionCoordinator: DisplayLinkControlling, RadioTransportDelegate {
    weak var delegate: DisplayLinkDelegate?
    private let radio: RadioTransport
    private let clock: DisplayClock
    private var availability: RadioAvailability = .unknown
    private var link: BLELinkState = .unbound
    private var candidates: [UUID: BindCandidate] = [:]
    private var confirmedIdentity: UUID?
    private var activeIdentifier: UUID?
    private var advertisedNames: [UUID: String] = [:]
    private var sawConfig = false
    private var initGateOpen = false
    private var initGeneration = 0
    private var currentConfig: EPDConfig?
    private var rleEnabled = false
    private var timeUnixSeconds: Int?
    private var sessionGeneration: UInt64 = 0
    private var firmwareMTU = 0
    private var nextWriteOperationID: UInt64 = 0
    private var inFlightWrites: [InFlightWrite] = []
    private var transfer: TransferSession?

    init(radio: RadioTransport, clock: DisplayClock) {
        self.radio = radio
        self.clock = clock
        radio.delegate = self
    }

    func attach() {
        radio.start()
    }

    func confirmBoundIdentity(_ identifier: UUID?) {
        confirmedIdentity = identifier
        if identifier != nil, link == .unbound || link == .disconnected {
            emitLink(.disconnected)
        } else if identifier == nil, link == .disconnected {
            emitLink(.unbound)
        }
    }

    func startBindScan() {
        guard confirmedIdentity == nil else {
            return
        }
        guard availability == .poweredOn else {
            classify(availability == .unauthorized ? .bluetoothUnauthorized : .bluetoothUnavailable)
            return
        }
        cancelTimers()
        candidates.removeAll()
        emitCandidates()
        emitLink(.scanning)
        radio.scan(service: DisplayLinkUUIDs.service)
        clock.schedule(id: "scan", after: 15) { [weak self] in
            self?.handleScanTimeout()
        }
    }

    func bind(identifier: UUID) {
        if let confirmedIdentity, confirmedIdentity != identifier {
            return
        }
        startConnect(identifier: identifier)
    }

    func recover(identifier: UUID) {
        guard availability == .poweredOn else {
            return
        }
        guard confirmedIdentity == identifier else {
            return
        }
        startConnect(identifier: identifier)
    }

    func unbind() {
        confirmedIdentity = nil
        cancelWork()
        emitLink(.unbound)
    }

    func writeWakeupPin(_ pin: UInt8, sessionGeneration: UInt64, configDigest: Data) -> Bool {
        guard link == .ready,
              self.sessionGeneration == sessionGeneration,
              let identifier = activeIdentifier,
              let current = currentConfig,
              current.digest == configDigest,
              let next = current.replacingWakeupPin(pin),
              next.differsOnlyByWakeupPin(from: current),
              transfer == nil,
              !hasInFlightSetConfig
        else {
            return false
        }
        var payload = Data([DisplayLinkUUIDs.setConfigOpcode])
        payload.append(contentsOf: next.bytes)
        issueWrite(identifier: identifier, data: payload, operation: .setConfig(next))
        return true
    }

    func transferDisplayFrame(blackPlane: Data, redPlane: Data, sessionGeneration: UInt64) -> Bool {
        guard link == .ready,
              self.sessionGeneration == sessionGeneration,
              activeIdentifier != nil,
              transfer == nil,
              firmwareMTU > 0 else {
            return false
        }
        let identifier = activeIdentifier!
        let capacity = ImageTransferPlanner.negotiatedCapacity(
            firmwareMTU: firmwareMTU,
            withoutResponseLimit: radio.maximumWriteValueLength(identifier: identifier, type: .withoutResponse),
            withResponseLimit: radio.maximumWriteValueLength(identifier: identifier, type: .withResponse)
        )
        if capacity < 1 {
            failTransfer(.mtuInvalid)
            return false
        }
        guard let planned = ImageTransferPlanner.plan(
            black: blackPlane,
            red: redPlane,
            rleAdvertised: rleEnabled,
            chunkCapacity: capacity
        ) else {
            failTransfer(.unknown)
            return false
        }
        transfer = TransferSession(
            generation: sessionGeneration,
            chunks: planned.chunks,
            index: 0,
            retryUsed: false,
            waitingForCredit: false,
            observing: false
        )
        startPlaneTimer()
        pumpTransfer()
        return true
    }

    func cancelWork() {
        cancelTimers()
        radio.stopScan()
        if let activeIdentifier {
            radio.cancelConnection(identifier: activeIdentifier)
        }
        resetSession()
        if confirmedIdentity != nil {
            emitLink(link == .unavailable ? .unavailable : .disconnected)
        } else if availability == .unauthorized || availability == .unavailable {
            emitLink(.unavailable)
        } else {
            emitLink(.unbound)
        }
    }

    func radioDidChangeAvailability(_ availability: RadioAvailability) {
        let previous = self.availability
        self.availability = availability
        switch availability {
        case .unknown:
            break
        case .unauthorized:
            failLiveSession(classification: .bluetoothUnauthorized, linkState: .unavailable)
        case .unavailable:
            failLiveSession(classification: .bluetoothUnavailable, linkState: .unavailable)
        case .poweredOn:
            if link == .unavailable || previous != .poweredOn {
                emitLink(idleLink())
            }
        }
        delegate?.displayLinkDidChangeAvailability(availability)
    }

    func radioDidDiscover(identifier: UUID, name: String?, rssi: Int) {
        advertisedNames[identifier] = name ?? advertisedNames[identifier]
        candidates[identifier] = BindCandidate(
            identifier: identifier,
            advertisedName: advertisedNames[identifier],
            rssi: rssi
        )
        emitCandidates()
    }

    func radioDidConnect(identifier: UUID) {
        guard activeIdentifier == identifier, link == .connecting else {
            return
        }
        clock.cancel(id: "connect")
        emitLink(.discovering)
        radio.discoverServices(identifier: identifier, uuids: [DisplayLinkUUIDs.service])
    }

    func radioDidFailToConnect(identifier: UUID) {
        guard activeIdentifier == identifier else {
            return
        }
        fail(.connectFailed)
    }

    func radioDidDisconnect(identifier: UUID) {
        guard activeIdentifier == identifier || confirmedIdentity == identifier else {
            return
        }
        if link == .ready || activeIdentifier == identifier {
            failTransfer(.disconnected)
            resetSession()
            classify(.disconnected)
            emitLink(idleLink())
            delegate?.displayLinkDidDisconnect()
        }
    }

    func radioIsReadyToSendWriteWithoutResponse(identifier: UUID) {
        guard activeIdentifier == identifier, transfer?.waitingForCredit == true else {
            return
        }
        pumpTransfer()
    }

    func radioDidDiscoverServices(identifier: UUID, services: [UUID]) {
        guard activeIdentifier == identifier, link == .discovering else {
            return
        }
        guard services.contains(DisplayLinkUUIDs.service) else {
            fail(.serviceMissing)
            return
        }
        radio.discoverCharacteristics(
            identifier: identifier,
            service: DisplayLinkUUIDs.service,
            uuids: [DisplayLinkUUIDs.data, DisplayLinkUUIDs.version]
        )
    }

    func radioDidDiscoverCharacteristics(
        identifier: UUID,
        service: UUID,
        characteristics: [RadioCharacteristic]
    ) {
        guard activeIdentifier == identifier, link == .discovering, service == DisplayLinkUUIDs.service else {
            return
        }
        guard let data = characteristics.first(where: { $0.uuid == DisplayLinkUUIDs.data }),
              data.isValidDataCharacteristic else {
            fail(.characteristicMissing)
            return
        }
        let version = characteristics.first(where: { $0.uuid == DisplayLinkUUIDs.version })
        if let version, version.canRead {
            radio.read(identifier: identifier, characteristic: DisplayLinkUUIDs.version)
        } else {
            handleFirmware(DisplayLinkUUIDs.missingFirmware, identifier: identifier)
        }
    }

    func radioDidUpdateNotificationState(
        identifier: UUID,
        characteristic: UUID,
        enabled: Bool,
        failed: Bool
    ) {
        guard activeIdentifier == identifier, link == .subscribing, characteristic == DisplayLinkUUIDs.data else {
            return
        }
        if failed || !enabled {
            fail(.subscribeFailed)
            return
        }
        emitLink(.awaitingConfig)
        clock.schedule(id: "config", after: 5) { [weak self] in
            self?.fail(.configTimeout)
        }
    }

    func radioDidUpdateValue(identifier: UUID, characteristic: UUID, value: Data) {
        guard activeIdentifier == identifier else {
            return
        }
        if characteristic == DisplayLinkUUIDs.version {
            let firmware = value.count == 1 ? value[0] : DisplayLinkUUIDs.missingFirmware
            handleFirmware(firmware, identifier: identifier)
            return
        }
        guard characteristic == DisplayLinkUUIDs.data else {
            return
        }
        if link == .awaitingConfig {
            handleConfig(value)
            return
        }
        if link == .initializing {
            handleMTUText(value)
            return
        }
        if link == .ready, !hasInFlightSetConfig, let config = EPDConfig(data: value) {
            currentConfig = config
            delegate?.displayLinkDidUpdateReadyConfig(config)
        }
    }

    func radioDidWrite(identifier: UUID, characteristic: UUID, failed: Bool) {
        guard activeIdentifier == identifier, !inFlightWrites.isEmpty else {
            return
        }
        let completed = inFlightWrites.removeFirst()
        switch completed.operation {
        case .initialize:
            if link == .initializing, failed {
                fail(.initTimeout)
            }
        case .setConfig(let written):
            guard link == .ready else {
                return
            }
            if failed {
                delegate?.displayLinkDidFinishConfigWrite(succeeded: false)
                return
            }
            currentConfig = written
            delegate?.displayLinkDidUpdateReadyConfig(written)
            delegate?.displayLinkDidFinishConfigWrite(succeeded: true)
        case .planeFlush:
            if failed {
                failTransfer(.planeTimeout)
                return
            }
            startPlaneTimer()
            pumpTransfer()
        case .refreshOpcode:
            if failed {
                failTransfer(.refreshTimeout)
                return
            }
            beginObservation()
        case .retryInitialize:
            if failed {
                failTransfer(.initTimeout)
                return
            }
            startPlaneTimer()
            pumpTransfer()
        }
    }

    private func startConnect(identifier: UUID) {
        guard availability == .poweredOn else {
            classify(availability == .unauthorized ? .bluetoothUnauthorized : .bluetoothUnavailable)
            return
        }
        cancelTimers()
        radio.stopScan()
        if let activeIdentifier, activeIdentifier != identifier {
            radio.cancelConnection(identifier: activeIdentifier)
        }
        resetSessionFlags()
        activeIdentifier = identifier
        emitLink(.connecting)
        clock.schedule(id: "connect", after: 10) { [weak self] in
            self?.fail(.connectFailed)
        }
        radio.connect(identifier: identifier)
    }

    private func handleFirmware(_ firmware: UInt8, identifier: UUID) {
        guard activeIdentifier == identifier, link == .discovering else {
            return
        }
        if firmware < DisplayLinkUUIDs.compatibleFirmware {
            fail(.firmwareIncompatible)
            return
        }
        emitLink(.subscribing)
        radio.setNotify(identifier: identifier, characteristic: DisplayLinkUUIDs.data, enabled: true)
    }

    private func handleConfig(_ value: Data) {
        if sawConfig {
            return
        }
        sawConfig = true
        guard let config = EPDConfig(data: value) else {
            fail(.callbackAmbiguous)
            return
        }
        clock.cancel(id: "config")
        currentConfig = config
        rleEnabled = false
        timeUnixSeconds = nil
        emitLink(.initializing)
        initGeneration += 1
        initGateOpen = true
        clock.schedule(id: "init", after: 5) { [weak self] in
            self?.fail(.initTimeout)
        }
        issueWrite(
            identifier: activeIdentifier!,
            data: Data([DisplayLinkUUIDs.initOpcode]),
            operation: .initialize
        )
    }

    private func handleMTUText(_ value: Data) {
        guard initGateOpen, initGeneration > 0 else {
            return
        }
        guard let text = String(data: value, encoding: .utf8) else {
            return
        }
        if text.contains("rle=1") {
            rleEnabled = true
        }
        if let time = parseTaggedInt(text, tag: "t=") {
            timeUnixSeconds = time
        }
        guard let mtu = parseTaggedInt(text, tag: "mtu=") else {
            return
        }
        if mtu == DisplayLinkUUIDs.appleDefaultMTU {
            fail(.mtuInvalid)
            return
        }
        clock.cancel(id: "init")
        clock.cancel(id: "connect")
        clock.cancel(id: "config")
        clock.cancel(id: "scan")
        guard let identifier = activeIdentifier, let config = currentConfig else {
            fail(.unknown)
            return
        }
        initGateOpen = false
        firmwareMTU = mtu
        sessionGeneration += 1
        emitLink(.ready)
        delegate?.displayLinkDidBecomeReady(
            ReadyBLESession(
                identifier: identifier,
                advertisedName: advertisedNames[identifier] ?? candidates[identifier]?.advertisedName,
                config: config,
                mtu: mtu,
                rleEnabled: rleEnabled,
                timeUnixSeconds: timeUnixSeconds,
                generation: sessionGeneration
            )
        )
    }

    private func handleScanTimeout() {
        radio.stopScan()
        if candidates.isEmpty {
            classify(.boundDisplayNotFound)
        }
        emitLink(.unbound)
    }

    private func fail(_ classification: BLEClassification) {
        failTransfer(classification)
        let identifier = activeIdentifier
        cancelTimers()
        radio.stopScan()
        if let identifier {
            radio.cancelConnection(identifier: identifier)
        }
        resetSession()
        classify(classification)
        emitLink(idleLink())
        if classification == .disconnected || classification == .bluetoothUnavailable || classification == .bluetoothUnauthorized {
            delegate?.displayLinkDidDisconnect()
        }
    }

    private func failLiveSession(classification: BLEClassification, linkState: BLELinkState) {
        failTransfer(classification)
        cancelTimers()
        radio.stopScan()
        if let activeIdentifier {
            radio.cancelConnection(identifier: activeIdentifier)
        }
        resetSession()
        candidates.removeAll()
        emitCandidates()
        classify(classification)
        emitLink(linkState)
        delegate?.displayLinkDidDisconnect()
    }

    private func idleLink() -> BLELinkState {
        confirmedIdentity == nil ? .unbound : .disconnected
    }

    private func resetSession() {
        activeIdentifier = nil
        resetSessionFlags()
    }

    private func resetSessionFlags() {
        sawConfig = false
        initGateOpen = false
        currentConfig = nil
        rleEnabled = false
        timeUnixSeconds = nil
        firmwareMTU = 0
        transfer = nil
        inFlightWrites.removeAll()
    }

    private func pumpTransfer() {
        guard var work = transfer, !work.observing, let identifier = activeIdentifier else {
            return
        }
        work.waitingForCredit = false
        while work.index < work.chunks.count {
            let chunk = work.chunks[work.index]
            if !chunk.withResponse && !radio.canSendWriteWithoutResponse(identifier: identifier) {
                work.waitingForCredit = true
                transfer = work
                return
            }
            work.index += 1
            transfer = work
            if chunk.withResponse {
                issueWrite(
                    identifier: identifier,
                    data: chunk.packet,
                    operation: chunk.isRefresh ? .refreshOpcode : .planeFlush
                )
                return
            }
            radio.write(
                identifier: identifier,
                characteristic: DisplayLinkUUIDs.data,
                data: chunk.packet,
                type: .withoutResponse
            )
        }
        transfer = work
    }

    private func startPlaneTimer() {
        clock.cancel(id: "plane")
        clock.schedule(id: "plane", after: 30) { [weak self] in
            self?.handlePlaneTimeout()
        }
    }

    private func handlePlaneTimeout() {
        guard var work = transfer, !work.observing else {
            return
        }
        if link == .ready, let identifier = activeIdentifier, !work.retryUsed {
            work.retryUsed = true
            work.index = 0
            work.waitingForCredit = false
            transfer = work
            inFlightWrites.removeAll()
            issueWrite(
                identifier: identifier,
                data: Data([DisplayLinkUUIDs.initOpcode]),
                operation: .retryInitialize
            )
            startPlaneTimer()
            return
        }
        let current = work.chunks[min(work.index, max(work.chunks.count - 1, 0))]
        failTransfer(current.isRefresh ? .refreshTimeout : .planeTimeout)
    }

    private func beginObservation() {
        guard var work = transfer else {
            return
        }
        clock.cancel(id: "plane")
        clock.cancel(id: "init")
        clock.cancel(id: "connect")
        work.observing = true
        transfer = work
        clock.schedule(id: "observation", after: 15) { [weak self] in
            self?.completeRefresh()
        }
    }

    private func completeRefresh() {
        guard transfer?.observing == true else {
            return
        }
        transfer = nil
        delegate?.displayLinkDidCompleteRefresh()
    }

    private func failTransfer(_ classification: BLEClassification) {
        guard transfer != nil else {
            return
        }
        transfer = nil
        clock.cancel(id: "plane")
        clock.cancel(id: "observation")
        classify(classification)
        delegate?.displayLinkDidFailRefresh(classification)
    }

    private var hasInFlightSetConfig: Bool {
        inFlightWrites.contains { write in
            if case .setConfig = write.operation {
                return true
            }
            return false
        }
    }

    private func issueWrite(identifier: UUID, data: Data, operation: RadioWriteOperation) {
        nextWriteOperationID += 1
        inFlightWrites.append(
            InFlightWrite(operationID: nextWriteOperationID, operation: operation)
        )
        radio.write(
            identifier: identifier,
            characteristic: DisplayLinkUUIDs.data,
            data: data,
            type: .withResponse
        )
    }

    private func cancelTimers() {
        clock.cancelAll()
    }

    private func emitLink(_ state: BLELinkState) {
        link = state
        delegate?.displayLinkDidUpdateLink(state)
    }

    private func emitCandidates() {
        let sorted = candidates.values.sorted { $0.identifier.uuidString < $1.identifier.uuidString }
        delegate?.displayLinkDidUpdateCandidates(sorted)
    }

    private func classify(_ classification: BLEClassification) {
        delegate?.displayLinkDidClassify(classification)
    }

    private func parseTaggedInt(_ text: String, tag: String) -> Int? {
        guard let range = text.range(of: tag) else {
            return nil
        }
        let remainder = text[range.upperBound...]
        var digits = ""
        for character in remainder {
            if character.isNumber || character == "-" {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }
}
