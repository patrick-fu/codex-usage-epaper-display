import Foundation

protocol DisplayClock: AnyObject {
    func schedule(id: String, after: TimeInterval, _ body: @escaping () -> Void)
    func cancel(id: String)
    func cancelAll()
}

protocol DisplayLinkDelegate: AnyObject {
    func displayLinkDidChangeAvailability(_ availability: RadioAvailability)
    func displayLinkDidUpdateLink(_ state: BLELinkState)
    func displayLinkDidUpdateCandidates(_ candidates: [BindCandidate])
    func displayLinkDidClassify(_ classification: BLEClassification)
    func displayLinkDidBecomeReady(_ session: ReadyBLESession)
    func displayLinkDidDisconnect()
    func displayLinkDidUpdateReadyConfig(_ config: EPDConfig)
    func displayLinkDidFinishConfigWrite(succeeded: Bool)
}

protocol DisplayLinkControlling: AnyObject {
    var delegate: DisplayLinkDelegate? { get set }
    func attach()
    func confirmBoundIdentity(_ identifier: UUID?)
    func startBindScan()
    func bind(identifier: UUID)
    func recover(identifier: UUID)
    func unbind()
    func cancelWork()
    func writeWakeupPin(_ pin: UInt8, sessionGeneration: UInt64, configDigest: Data) -> Bool
}

final class NullDisplayLink: DisplayLinkControlling {
    weak var delegate: DisplayLinkDelegate?

    func attach() {}
    func confirmBoundIdentity(_ identifier: UUID?) {}
    func startBindScan() {}
    func bind(identifier: UUID) {}
    func recover(identifier: UUID) {}
    func unbind() {}
    func cancelWork() {}
    func writeWakeupPin(_ pin: UInt8, sessionGeneration: UInt64, configDigest: Data) -> Bool {
        false
    }
}
