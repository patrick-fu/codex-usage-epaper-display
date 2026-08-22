import Foundation

protocol RadioTransportDelegate: AnyObject {
    func radioDidChangeAvailability(_ availability: RadioAvailability)
    func radioDidDiscover(identifier: UUID, name: String?, rssi: Int)
    func radioDidConnect(identifier: UUID)
    func radioDidFailToConnect(identifier: UUID)
    func radioDidDisconnect(identifier: UUID)
    func radioDidDiscoverServices(identifier: UUID, services: [UUID])
    func radioDidDiscoverCharacteristics(
        identifier: UUID,
        service: UUID,
        characteristics: [RadioCharacteristic]
    )
    func radioDidUpdateNotificationState(
        identifier: UUID,
        characteristic: UUID,
        enabled: Bool,
        failed: Bool
    )
    func radioDidUpdateValue(identifier: UUID, characteristic: UUID, value: Data)
    func radioDidWrite(identifier: UUID, characteristic: UUID, failed: Bool)
    func radioIsReadyToSendWriteWithoutResponse(identifier: UUID)
}

protocol RadioTransport: AnyObject {
    var delegate: RadioTransportDelegate? { get set }
    func start()
    func scan(service: UUID)
    func stopScan()
    func connect(identifier: UUID)
    func cancelConnection(identifier: UUID)
    func discoverServices(identifier: UUID, uuids: [UUID])
    func discoverCharacteristics(identifier: UUID, service: UUID, uuids: [UUID])
    func setNotify(identifier: UUID, characteristic: UUID, enabled: Bool)
    func read(identifier: UUID, characteristic: UUID)
    func write(identifier: UUID, characteristic: UUID, data: Data, type: RadioWriteType)
    func maximumWriteValueLength(identifier: UUID, type: RadioWriteType) -> Int
    func canSendWriteWithoutResponse(identifier: UUID) -> Bool
}

final class DispatchDisplayClock: DisplayClock {
    private let queue: DispatchQueue
    private var items: [String: DispatchWorkItem] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func schedule(id: String, after: TimeInterval, _ body: @escaping () -> Void) {
        cancel(id: id)
        let item = DispatchWorkItem(block: body)
        items[id] = item
        queue.asyncAfter(deadline: .now() + after, execute: item)
    }

    func cancel(id: String) {
        items[id]?.cancel()
        items[id] = nil
    }

    func cancelAll() {
        for item in items.values {
            item.cancel()
        }
        items.removeAll()
    }
}
