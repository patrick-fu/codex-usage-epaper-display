import Foundation
@testable import UsageInk

enum BLETestFixtures {
    static let sampleConfig = Data([8, 7, 6, 5, 4, 3, 2, 1, 0xFF, 0, 1, 0, 1])
}

final class ManualDisplayClock: DisplayClock, @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    let origin: Date
    private var tasks: [String: (fireAt: TimeInterval, body: () -> Void)] = [:]
    var queue: DispatchQueue?

    init(origin: Date = Date(timeIntervalSince1970: 0)) {
        self.origin = origin
    }

    var date: Date {
        lock.lock()
        defer { lock.unlock() }
        return origin.addingTimeInterval(elapsed)
    }

    func schedule(id: String, after: TimeInterval, _ body: @escaping () -> Void) {
        lock.lock()
        tasks[id] = (elapsed + after, body)
        lock.unlock()
    }

    func cancel(id: String) {
        lock.lock()
        tasks[id] = nil
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        tasks.removeAll()
        lock.unlock()
    }

    func scheduledDelay(id: String) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let task = tasks[id] else {
            return nil
        }
        return task.fireAt - elapsed
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        elapsed += interval
        let due = tasks.filter { $0.value.fireAt <= elapsed }
        for key in due.keys {
            tasks[key] = nil
        }
        let queue = self.queue
        lock.unlock()
        let run = {
            for item in due.values {
                item.body()
            }
        }
        if let queue {
            queue.async(execute: run)
        } else {
            run()
        }
    }
}

struct FakePeripheralSpec {
    var name: String? = "UsageInk-Desk"
    var rssi: Int = -42
    var connectSucceeds: Bool = true
    var services: [UUID] = [DisplayLinkUUIDs.service]
    var characteristics: [RadioCharacteristic] = [
        .dataDefault,
        .versionDefault,
    ]
    var versionByte: UInt8? = 0x16
    var versionPayload: Data?
    var notifySucceeds: Bool = true
    var writeSucceeds: Bool = true
    var autoConfig: Data? = BLETestFixtures.sampleConfig
    var autoMTUText: String? = "mtu=185"
    var extraFirstNotify: Data?
    var connectHangs: Bool = false
    var mtuBeforeWriteAck: Bool = false
}

final class FakeRadio: RadioTransport {
    weak var delegate: RadioTransportDelegate?
    var queue: DispatchQueue?
    var availability: RadioAvailability = .poweredOn
    var peripherals: [UUID: FakePeripheralSpec] = [:]
    private(set) var writes: [BLEWriteRecord] = []
    private(set) var scanActive = false
    private(set) var scanCount = 0
    private(set) var connectCount = 0
    var advertiseOnScan = true
    var holdWriteAcknowledgements = false
    var maximumWriteWithoutResponse = 512
    var maximumWriteWithResponse = 512
    var writeWithoutResponseCredits: Int?
    private(set) var writesRejectedForFlowControl = 0
    private var connected: UUID?
    private var deferredWriteAcks: [(identifier: UUID, characteristic: UUID, failed: Bool, type: RadioWriteType)] = []

    func start() {
        emit { self.delegate?.radioDidChangeAvailability(self.availability) }
    }

    func scan(service: UUID) {
        _ = service
        scanActive = true
        scanCount += 1
        guard advertiseOnScan else {
            return
        }
        for (identifier, spec) in peripherals {
            emitDiscover(identifier: identifier, spec: spec)
        }
    }

    func stopScan() {
        scanActive = false
    }

    func connect(identifier: UUID) {
        connectCount += 1
        guard let spec = peripherals[identifier], spec.connectSucceeds else {
            emit { self.delegate?.radioDidFailToConnect(identifier: identifier) }
            return
        }
        if spec.connectHangs {
            return
        }
        connected = identifier
        emit { self.delegate?.radioDidConnect(identifier: identifier) }
    }

    func cancelConnection(identifier: UUID) {
        if connected == identifier {
            connected = nil
            emit { self.delegate?.radioDidDisconnect(identifier: identifier) }
        }
    }

    func discoverServices(identifier: UUID, uuids: [UUID]) {
        let services = peripherals[identifier]?.services ?? []
        emit { self.delegate?.radioDidDiscoverServices(identifier: identifier, services: services) }
    }

    func discoverCharacteristics(identifier: UUID, service: UUID, uuids: [UUID]) {
        let characteristics = peripherals[identifier]?.characteristics ?? []
        emit {
            self.delegate?.radioDidDiscoverCharacteristics(
                identifier: identifier,
                service: service,
                characteristics: characteristics
            )
        }
    }

    func setNotify(identifier: UUID, characteristic: UUID, enabled: Bool) {
        let spec = peripherals[identifier]
        let failed = !(spec?.notifySucceeds ?? false)
        emit {
            self.delegate?.radioDidUpdateNotificationState(
                identifier: identifier,
                characteristic: characteristic,
                enabled: enabled && !failed,
                failed: failed
            )
        }
        guard !failed, enabled, characteristic == DisplayLinkUUIDs.data else {
            return
        }
        if let extra = spec?.extraFirstNotify {
            emitValue(identifier: identifier, characteristic: characteristic, value: extra)
        }
        if let config = spec?.autoConfig {
            emitValue(identifier: identifier, characteristic: characteristic, value: config)
        }
    }

    func read(identifier: UUID, characteristic: UUID) {
        guard characteristic == DisplayLinkUUIDs.version else {
            return
        }
        if let payload = peripherals[identifier]?.versionPayload {
            emitValue(identifier: identifier, characteristic: characteristic, value: payload)
            return
        }
        if let byte = peripherals[identifier]?.versionByte {
            emitValue(identifier: identifier, characteristic: characteristic, value: Data([byte]))
        }
    }

    func maximumWriteValueLength(identifier: UUID, type: RadioWriteType) -> Int {
        _ = identifier
        return type == .withResponse ? maximumWriteWithResponse : maximumWriteWithoutResponse
    }

    func canSendWriteWithoutResponse(identifier: UUID) -> Bool {
        _ = identifier
        guard let credits = writeWithoutResponseCredits else {
            return true
        }
        return credits > 0
    }

    func grantWriteWithoutResponseCredit() {
        writeWithoutResponseCredits = (writeWithoutResponseCredits ?? 0) + 1
        if let connected {
            emit { self.delegate?.radioIsReadyToSendWriteWithoutResponse(identifier: connected) }
        }
    }

    func setUnlimitedWriteWithoutResponse() {
        writeWithoutResponseCredits = nil
        if let connected {
            emit { self.delegate?.radioIsReadyToSendWriteWithoutResponse(identifier: connected) }
        }
    }

    func dropDeferredWriteAcknowledgements() {
        deferredWriteAcks.removeAll()
    }

    func write(identifier: UUID, characteristic: UUID, data: Data, type: RadioWriteType) {
        if type == .withoutResponse, !canSendWriteWithoutResponse(identifier: identifier) {
            writesRejectedForFlowControl += 1
        }
        if type == .withoutResponse, let credits = writeWithoutResponseCredits, credits > 0 {
            writeWithoutResponseCredits = credits - 1
        }
        writes.append(
            BLEWriteRecord(
                identifier: identifier,
                characteristic: characteristic,
                data: data,
                withResponse: type == .withResponse
            )
        )
        let spec = peripherals[identifier]
        let failed = !(spec?.writeSucceeds ?? false)
        if spec?.mtuBeforeWriteAck == true, let text = spec?.autoMTUText {
            emitValue(identifier: identifier, characteristic: DisplayLinkUUIDs.data, value: Data(text.utf8))
        }
        if holdWriteAcknowledgements, type == .withResponse {
            deferredWriteAcks.append((identifier, characteristic, failed, type))
            return
        }
        emit {
            self.delegate?.radioDidWrite(
                identifier: identifier,
                characteristic: characteristic,
                failed: failed,
                type: type
            )
        }
        if spec?.mtuBeforeWriteAck != true, !failed, let text = spec?.autoMTUText {
            emitValue(identifier: identifier, characteristic: DisplayLinkUUIDs.data, value: Data(text.utf8))
        }
    }

    func acknowledgeNextWrite() {
        guard !deferredWriteAcks.isEmpty else {
            return
        }
        let ack = deferredWriteAcks.removeFirst()
        emit {
            self.delegate?.radioDidWrite(
                identifier: ack.identifier,
                characteristic: ack.characteristic,
                failed: ack.failed,
                type: ack.type
            )
        }
        if ack.failed {
            return
        }
        let spec = peripherals[ack.identifier]
        if spec?.mtuBeforeWriteAck == true {
            return
        }
        if let text = spec?.autoMTUText {
            emitValue(identifier: ack.identifier, characteristic: DisplayLinkUUIDs.data, value: Data(text.utf8))
        }
    }

    func setAvailability(_ availability: RadioAvailability) {
        self.availability = availability
        emit { self.delegate?.radioDidChangeAvailability(availability) }
    }

    func advertise(_ identifier: UUID) {
        guard let spec = peripherals[identifier] else {
            return
        }
        emitDiscover(identifier: identifier, spec: spec)
    }

    func updateRSSI(_ identifier: UUID, rssi: Int) {
        peripherals[identifier]?.rssi = rssi
        guard let spec = peripherals[identifier] else {
            return
        }
        emitDiscover(identifier: identifier, spec: spec)
    }

    func emitValue(identifier: UUID, characteristic: UUID, value: Data) {
        emit {
            self.delegate?.radioDidUpdateValue(
                identifier: identifier,
                characteristic: characteristic,
                value: value
            )
        }
    }

    func emitDisconnect(_ identifier: UUID) {
        connected = nil
        emit { self.delegate?.radioDidDisconnect(identifier: identifier) }
    }

    private func emitDiscover(identifier: UUID, spec: FakePeripheralSpec) {
        emit {
            self.delegate?.radioDidDiscover(
                identifier: identifier,
                name: spec.name,
                rssi: spec.rssi
            )
        }
    }

    private func emit(_ body: @escaping () -> Void) {
        if let queue {
            if String(cString: __dispatch_queue_get_label(nil)) == queue.label {
                body()
            } else {
                queue.async(execute: body)
            }
        } else {
            body()
        }
    }
}
