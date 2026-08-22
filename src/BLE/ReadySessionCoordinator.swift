import Foundation

final class ReadySessionCoordinator: DisplayLinkControlling, RadioTransportDelegate {
    weak var delegate: DisplayLinkDelegate?
    private let radio: RadioTransport
    private let clock: DisplayClock
    private var availability: RadioAvailability = .unknown
    private var link: BLELinkState = .unbound
    private var candidates: [UUID: BindCandidate] = [:]
    private var persistedBinding: UUID?
    private var activeIdentifier: UUID?
    private var advertisedNames: [UUID: String] = [:]
    private var sawConfig = false
    private var awaitingFreshMTU = false
    private var currentConfig: EPDConfig?
    private var rleEnabled = false
    private var timeUnixSeconds: Int?
    private var sawUnavailableThisProcess = false
    private var didCompleteInitialAvailability = false

    init(radio: RadioTransport, clock: DisplayClock) {
        self.radio = radio
        self.clock = clock
        radio.delegate = self
    }

    func attach() {
        radio.start()
    }

    func setPersistedBinding(_ identifier: UUID?) {
        persistedBinding = identifier
        if identifier != nil, link == .unbound {
            emitLink(.disconnected)
        } else if identifier == nil, link == .disconnected {
            emitLink(.unbound)
        }
    }

    func startBindScan() {
        guard persistedBinding == nil else {
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
        startConnect(identifier: identifier)
    }

    func recover(identifier: UUID) {
        guard availability == .poweredOn else {
            return
        }
        startConnect(identifier: identifier)
    }

    func unbind() {
        cancelWork()
        persistedBinding = nil
        emitLink(.unbound)
    }

    func cancelWork() {
        cancelTimers()
        radio.stopScan()
        if let activeIdentifier {
            radio.cancelConnection(identifier: activeIdentifier)
        }
        resetSession()
        if persistedBinding != nil {
            emitLink(link == .unavailable ? .unavailable : .disconnected)
        } else if availability == .poweredOn {
            emitLink(.unbound)
        }
    }

    func radioDidChangeAvailability(_ availability: RadioAvailability) {
        let previous = self.availability
        self.availability = availability
        delegate?.displayLinkDidChangeAvailability(availability)
        switch availability {
        case .unknown:
            break
        case .unauthorized:
            sawUnavailableThisProcess = true
            failLiveSession(classification: .bluetoothUnauthorized, linkState: .unavailable)
        case .unavailable:
            sawUnavailableThisProcess = true
            failLiveSession(classification: .bluetoothUnavailable, linkState: .unavailable)
        case .poweredOn:
            if link == .unavailable || previous != .poweredOn {
                emitLink(persistedBinding == nil ? .unbound : .disconnected)
            }
            let shouldRecover = didCompleteInitialAvailability && sawUnavailableThisProcess && persistedBinding != nil
            didCompleteInitialAvailability = true
            if shouldRecover, let persistedBinding {
                recover(identifier: persistedBinding)
            }
        }
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
        guard activeIdentifier == identifier || persistedBinding == identifier else {
            return
        }
        if link == .ready || activeIdentifier == identifier {
            resetSession()
            classify(.disconnected)
            emitLink(persistedBinding == nil ? .unbound : .disconnected)
            delegate?.displayLinkDidDisconnect()
        }
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
        }
    }

    func radioDidWrite(identifier: UUID, characteristic: UUID, failed: Bool) {
        guard activeIdentifier == identifier, link == .initializing else {
            return
        }
        if failed {
            fail(.initTimeout)
            return
        }
        awaitingFreshMTU = true
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
        radio.connect(identifier: identifier)
        clock.schedule(id: "connect", after: 10) { [weak self] in
            self?.fail(.connectFailed)
        }
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
        emitLink(.initializing)
        let payload = Data([DisplayLinkUUIDs.initOpcode])
        radio.write(
            identifier: activeIdentifier!,
            characteristic: DisplayLinkUUIDs.data,
            data: payload,
            type: .withResponse
        )
        clock.schedule(id: "init", after: 5) { [weak self] in
            self?.fail(.initTimeout)
        }
    }

    private func handleMTUText(_ value: Data) {
        guard let text = String(data: value, encoding: .utf8) else {
            return
        }
        if text.contains("rle=1") {
            rleEnabled = true
        }
        if let time = parseTaggedInt(text, tag: "t=") {
            timeUnixSeconds = time
        }
        guard awaitingFreshMTU, let mtu = parseTaggedInt(text, tag: "mtu=") else {
            return
        }
        if mtu == DisplayLinkUUIDs.appleDefaultMTU {
            fail(.mtuInvalid)
            return
        }
        clock.cancel(id: "init")
        guard let identifier = activeIdentifier, let config = currentConfig else {
            fail(.unknown)
            return
        }
        emitLink(.ready)
        persistedBinding = identifier
        delegate?.displayLinkDidBecomeReady(
            ReadyBLESession(
                identifier: identifier,
                advertisedName: advertisedNames[identifier] ?? candidates[identifier]?.advertisedName,
                config: config,
                mtu: mtu,
                rleEnabled: rleEnabled,
                timeUnixSeconds: timeUnixSeconds
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
        persistedBinding == nil ? .unbound : .disconnected
    }

    private func resetSession() {
        activeIdentifier = nil
        resetSessionFlags()
    }

    private func resetSessionFlags() {
        sawConfig = false
        awaitingFreshMTU = false
        currentConfig = nil
        rleEnabled = false
        timeUnixSeconds = nil
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
