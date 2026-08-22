import CoreBluetooth
import Foundation

final class NRF5Radio: NSObject, RadioTransport, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var delegate: RadioTransportDelegate?
    private let queue: DispatchQueue
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var characteristics: [UUID: [UUID: CBCharacteristic]] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: nil)
    }

    func start() {
        emitAvailability(central.state)
    }

    func scan(service: UUID) {
        central.scanForPeripherals(
            withServices: [CBUUID(string: service.uuidString)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScan() {
        central.stopScan()
    }

    func connect(identifier: UUID) {
        if let peripheral = storedPeripheral(identifier) {
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            return
        }
        delegate?.radioDidFailToConnect(identifier: identifier)
    }

    func cancelConnection(identifier: UUID) {
        if let peripheral = peripherals[identifier] {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func discoverServices(identifier: UUID, uuids: [UUID]) {
        storedPeripheral(identifier)?.discoverServices(uuids.map { CBUUID(string: $0.uuidString) })
    }

    func discoverCharacteristics(identifier: UUID, service: UUID, uuids: [UUID]) {
        guard let peripheral = storedPeripheral(identifier),
              let cbService = peripheral.services?.first(where: { $0.uuid == CBUUID(string: service.uuidString) }) else {
            return
        }
        peripheral.discoverCharacteristics(uuids.map { CBUUID(string: $0.uuidString) }, for: cbService)
    }

    func setNotify(identifier: UUID, characteristic: UUID, enabled: Bool) {
        guard let peripheral = storedPeripheral(identifier),
              let cbCharacteristic = characteristics[identifier]?[characteristic] else {
            delegate?.radioDidUpdateNotificationState(
                identifier: identifier,
                characteristic: characteristic,
                enabled: false,
                failed: true
            )
            return
        }
        peripheral.setNotifyValue(enabled, for: cbCharacteristic)
    }

    func read(identifier: UUID, characteristic: UUID) {
        guard let peripheral = storedPeripheral(identifier),
              let cbCharacteristic = characteristics[identifier]?[characteristic] else {
            return
        }
        peripheral.readValue(for: cbCharacteristic)
    }

    func write(identifier: UUID, characteristic: UUID, data: Data, type: RadioWriteType) {
        guard let peripheral = storedPeripheral(identifier),
              let cbCharacteristic = characteristics[identifier]?[characteristic] else {
            delegate?.radioDidWrite(identifier: identifier, characteristic: characteristic, failed: true)
            return
        }
        let writeType: CBCharacteristicWriteType = type == .withResponse ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: cbCharacteristic, type: writeType)
        if writeType == .withoutResponse {
            delegate?.radioDidWrite(identifier: identifier, characteristic: characteristic, failed: false)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emitAvailability(central.state)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        delegate?.radioDidDiscover(identifier: peripheral.identifier, name: name, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        delegate?.radioDidConnect(identifier: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        delegate?.radioDidFailToConnect(identifier: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        delegate?.radioDidDisconnect(identifier: peripheral.identifier)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = (peripheral.services ?? []).compactMap { UUID(uuidString: $0.uuid.uuidString) }
        delegate?.radioDidDiscoverServices(identifier: peripheral.identifier, services: services)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        var mapped: [RadioCharacteristic] = []
        var stored = characteristics[peripheral.identifier] ?? [:]
        for characteristic in service.characteristics ?? [] {
            let uuid = UUID(uuidString: characteristic.uuid.uuidString) ?? UUID()
            stored[uuid] = characteristic
            mapped.append(
                RadioCharacteristic(
                    uuid: uuid,
                    canRead: characteristic.properties.contains(.read),
                    canWriteWithResponse: characteristic.properties.contains(.write),
                    canWriteWithoutResponse: characteristic.properties.contains(.writeWithoutResponse),
                    canNotify: characteristic.properties.contains(.notify)
                )
            )
        }
        characteristics[peripheral.identifier] = stored
        let serviceUUID = UUID(uuidString: service.uuid.uuidString) ?? DisplayLinkUUIDs.service
        delegate?.radioDidDiscoverCharacteristics(
            identifier: peripheral.identifier,
            service: serviceUUID,
            characteristics: mapped
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = UUID(uuidString: characteristic.uuid.uuidString) ?? DisplayLinkUUIDs.data
        delegate?.radioDidUpdateNotificationState(
            identifier: peripheral.identifier,
            characteristic: uuid,
            enabled: characteristic.isNotifying,
            failed: error != nil
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = UUID(uuidString: characteristic.uuid.uuidString) ?? DisplayLinkUUIDs.data
        delegate?.radioDidUpdateValue(
            identifier: peripheral.identifier,
            characteristic: uuid,
            value: characteristic.value ?? Data()
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = UUID(uuidString: characteristic.uuid.uuidString) ?? DisplayLinkUUIDs.data
        delegate?.radioDidWrite(identifier: peripheral.identifier, characteristic: uuid, failed: error != nil)
    }

    private func storedPeripheral(_ identifier: UUID) -> CBPeripheral? {
        if let existing = peripherals[identifier] {
            return existing
        }
        if let retrieved = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            peripherals[identifier] = retrieved
            retrieved.delegate = self
            return retrieved
        }
        return nil
    }

    private func emitAvailability(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            delegate?.radioDidChangeAvailability(.poweredOn)
        case .unauthorized:
            delegate?.radioDidChangeAvailability(.unauthorized)
        case .unknown:
            delegate?.radioDidChangeAvailability(.unknown)
        default:
            delegate?.radioDidChangeAvailability(.unavailable)
        }
    }
}
