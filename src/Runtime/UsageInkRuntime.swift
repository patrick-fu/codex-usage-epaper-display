import Foundation

enum RuntimeCommand: Sendable, Equatable {
    case refreshNow
    case findAndBindDisplay
    case unbindDisplay
    case setDisplayStyle(DisplayStyle)
    case savePreferences(DisplayPreferences)
    case rebuildLocalMetrics
    case resetUsageInkData
}

struct RuntimeSnapshot: Sendable, Equatable {
    var statusSummary: String
    var binding: BindingPresentation
    var displayStyle: DisplayStyle
    var hasReadyWakeupConfiguration: Bool
    var preferences: DisplayPreferences = .default
    var panelTrust: PanelTrust = .invalid
    var showsFirstRunDisclosure: Bool = false
    var storageClassification: StorageClassification? = nil
    var isPersistenceWritable: Bool = true
}

final class UsageInkRuntime: @unchecked Sendable {
    static let queueLabel = "com.patrickfu.UsageInk.runtime"

    private let queue: DispatchQueue
    private let snapshotHandler: @Sendable (RuntimeSnapshot) -> Void
    private let formatter: StatusSummaryFormatter
    private let store: PersistenceStore
    private var productState: ProductState = .default
    private var binding: BindingPresentation = .unbound
    private var hasReadyWakeupConfiguration = false
    private var accountAvailability: SourceAvailability = .unknown
    private var localAvailability: SourceAvailability = .unknown
    private var displayUnavailable = false
    private var panelTrust: PanelTrust = .invalid
    private var showsFirstRunDisclosure = true
    private var storageClassification: StorageClassification?
    private var isPersistenceWritable = true

    init(
        language: ResolvedInterfaceLanguage = .resolveSystem(),
        store: PersistenceStore = PersistenceStore(),
        snapshotHandler: @escaping @Sendable (RuntimeSnapshot) -> Void
    ) {
        self.queue = DispatchQueue(label: Self.queueLabel, qos: .userInitiated)
        self.formatter = StatusSummaryFormatter(language: language)
        self.store = store
        self.snapshotHandler = snapshotHandler
    }

    func start() {
        queue.async { [self] in
            applyLoad(store.load())
            panelTrust = .invalid
            hasReadyWakeupConfiguration = false
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
        case .refreshNow, .findAndBindDisplay, .unbindDisplay, .rebuildLocalMetrics:
            break
        case .setDisplayStyle(let style):
            guard isPersistenceWritable else { return }
            productState.preferences.displayStyle = style
            persistProductState()
        case .savePreferences(let preferences):
            guard isPersistenceWritable else { return }
            productState.preferences = preferences
            persistProductState()
        case .resetUsageInkData:
            do {
                try store.reset()
                applyLoad(store.load())
                panelTrust = .invalid
                hasReadyWakeupConfiguration = false
            } catch {
                storageClassification = .stateWriteFailed
            }
        }
    }

    private func applyLoad(_ result: PersistenceLoadResult) {
        productState = result.state
        showsFirstRunDisclosure = result.showsFirstRunDisclosure
        storageClassification = result.storageClassification
        isPersistenceWritable = result.isWritable
        binding = .unbound
        hasReadyWakeupConfiguration = false
        panelTrust = .invalid
    }

    private func persistProductState() {
        do {
            try store.save(productState)
            applyLoad(store.load())
            panelTrust = .invalid
        } catch PersistenceError.readOnlyUnsupportedSchema {
            isPersistenceWritable = false
            storageClassification = .stateVersionUnsupported
        } catch PersistenceError.invalidCustomCodexPath {
            applyLoad(store.load())
        } catch {
            storageClassification = .stateWriteFailed
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
            displayStyle: productState.preferences.displayStyle,
            hasReadyWakeupConfiguration: hasReadyWakeupConfiguration,
            preferences: productState.preferences,
            panelTrust: panelTrust,
            showsFirstRunDisclosure: showsFirstRunDisclosure,
            storageClassification: storageClassification,
            isPersistenceWritable: isPersistenceWritable
        )
    }
}
