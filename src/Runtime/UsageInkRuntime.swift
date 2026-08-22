import Foundation

enum RuntimeCommand: Sendable, Equatable {
    case refreshNow
    case findAndBindDisplay
    case unbindDisplay
    case setDisplayStyle(DisplayStyle)
    case rebuildLocalMetrics
    case resetUsageInkData
}

struct RuntimeSnapshot: Sendable, Equatable {
    var statusSummary: String
    var binding: BindingPresentation
    var displayStyle: DisplayStyle
    var hasReadyWakeupConfiguration: Bool
}

final class UsageInkRuntime: @unchecked Sendable {
    static let queueLabel = "com.patrickfu.UsageInk.runtime"

    private let queue: DispatchQueue
    private let snapshotHandler: @Sendable (RuntimeSnapshot) -> Void
    private let formatter: StatusSummaryFormatter
    private var displayStyle: DisplayStyle = .quotaFocus
    private var binding: BindingPresentation = .unbound
    private var hasReadyWakeupConfiguration = false
    private var accountAvailability: SourceAvailability = .unknown
    private var localAvailability: SourceAvailability = .unknown
    private var displayUnavailable = false

    init(
        language: ResolvedInterfaceLanguage = .resolveSystem(),
        snapshotHandler: @escaping @Sendable (RuntimeSnapshot) -> Void
    ) {
        self.queue = DispatchQueue(label: Self.queueLabel, qos: .userInitiated)
        self.formatter = StatusSummaryFormatter(language: language)
        self.snapshotHandler = snapshotHandler
    }

    func start() {
        queue.async { [self] in
            publish()
        }
    }

    func submit(_ command: RuntimeCommand) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            handle(command)
            publish()
        }
    }

    private func handle(_ command: RuntimeCommand) {
        switch command {
        case .refreshNow, .findAndBindDisplay, .unbindDisplay, .rebuildLocalMetrics, .resetUsageInkData:
            break
        case .setDisplayStyle(let style):
            displayStyle = style
        }
    }

    private func publish() {
        dispatchPrecondition(condition: .onQueue(queue))
        snapshotHandler(makeSnapshot())
    }

    private func makeSnapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            statusSummary: formatter.summary(
                account: accountAvailability,
                local: localAvailability,
                displayUnavailable: displayUnavailable
            ),
            binding: binding,
            displayStyle: displayStyle,
            hasReadyWakeupConfiguration: hasReadyWakeupConfiguration
        )
    }
}
