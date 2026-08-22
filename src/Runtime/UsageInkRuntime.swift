import Foundation

enum RuntimeCommand: Sendable, Equatable {
    case refreshNow
    case findAndBindDisplay
    case bindDisplay(UUID)
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
    var shouldPresentSettingsOnLaunch: Bool = false
    var storageClassification: StorageClassification? = nil
    var isPersistenceWritable: Bool = true
    var bleLink: BLELinkState = .unbound
    var bindCandidates: [BindCandidate] = []
    var lastBLEClassification: BLEClassification? = nil
    var localActivity: LocalActivityObservation = .unknown
}

final class UsageInkRuntime: @unchecked Sendable, DisplayLinkDelegate {
    static let queueLabel = "com.patrickfu.UsageInk.runtime"

    private let queue: DispatchQueue
    private let snapshotHandler: @Sendable (RuntimeSnapshot) -> Void
    private let formatter: StatusSummaryFormatter
    private let store: PersistenceStore
    private let activityStore: ActivityStore
    private let codexHome: URL
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let link: DisplayLinkControlling
    private var productState: ProductState = .default
    private var binding: BindingPresentation = .unbound
    private var hasReadyWakeupConfiguration = false
    private var accountAvailability: SourceAvailability = .unknown
    private var localActivity: LocalActivityObservation = .unknown
    private var panelTrust: PanelTrust = .invalid
    private var showsFirstRunDisclosure = true
    private var shouldPresentSettingsOnLaunch = true
    private var storageClassification: StorageClassification?
    private var isPersistenceWritable = true
    private var bleLink: BLELinkState = .unbound
    private var bindCandidates: [BindCandidate] = []
    private var lastBLEClassification: BLEClassification?
    private var bluetoothBecameUnavailable = false

    var persistenceRoot: URL {
        store.root
    }

    init(
        language: ResolvedInterfaceLanguage = .resolveSystem(),
        store: PersistenceStore = PersistenceStore(),
        activityStore: ActivityStore? = nil,
        codexHome: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current,
        makeLink: ((DispatchQueue) -> DisplayLinkControlling)? = nil,
        snapshotHandler: @escaping @Sendable (RuntimeSnapshot) -> Void
    ) {
        ActivityLocation.installTestHostIsolationIfNeeded()
        self.queue = DispatchQueue(label: Self.queueLabel, qos: .userInitiated)
        self.formatter = StatusSummaryFormatter(language: language)
        self.store = store
        self.activityStore = activityStore ?? ActivityStore(root: store.root)
        self.codexHome = codexHome ?? ActivityLocation.resolvedCodexHome()
        self.now = now
        self.timeZone = timeZone
        self.snapshotHandler = snapshotHandler
        self.link = makeLink?(queue) ?? NullDisplayLink()
        self.link.delegate = self
    }

    func start() {
        queue.async { [self] in
            applyLoad(store.load())
            panelTrust = .invalid
            hasReadyWakeupConfiguration = false
            lastBLEClassification = nil
            bindCandidates = []
            bluetoothBecameUnavailable = false
            refreshLocalActivity(forceScan: true)
            link.confirmBoundIdentity(persistedBindingIdentifier)
            link.attach()
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

    func displayLinkDidChangeAvailability(_ availability: RadioAvailability) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch availability {
        case .unauthorized, .unavailable:
            bluetoothBecameUnavailable = true
            hasReadyWakeupConfiguration = false
            panelTrust = .invalid
        case .poweredOn:
            if bluetoothBecameUnavailable, let identifier = persistedBindingIdentifier {
                bluetoothBecameUnavailable = false
                link.recover(identifier: identifier)
            }
        case .unknown:
            break
        }
        publish()
    }

    func displayLinkDidUpdateLink(_ state: BLELinkState) {
        dispatchPrecondition(condition: .onQueue(queue))
        bleLink = state
        if state != .ready {
            hasReadyWakeupConfiguration = false
            publish()
        }
    }

    func displayLinkDidUpdateCandidates(_ candidates: [BindCandidate]) {
        dispatchPrecondition(condition: .onQueue(queue))
        bindCandidates = candidates
        publish()
    }

    func displayLinkDidClassify(_ classification: BLEClassification) {
        dispatchPrecondition(condition: .onQueue(queue))
        lastBLEClassification = classification
        hasReadyWakeupConfiguration = false
        publish()
    }

    func displayLinkDidBecomeReady(_ session: ReadyBLESession) {
        dispatchPrecondition(condition: .onQueue(queue))
        let record = BoundDisplayRecord(
            identifier: session.identifier.uuidString,
            displayName: ProductState.sanitizedDisplayName(session.advertisedName)
        )
        var candidate = productState
        candidate.boundDisplay = record
        do {
            try store.save(candidate)
            productState = candidate
            showsFirstRunDisclosure = false
            shouldPresentSettingsOnLaunch = false
            storageClassification = nil
            isPersistenceWritable = true
            binding = .bound
            bleLink = .ready
            hasReadyWakeupConfiguration = true
            lastBLEClassification = nil
            bindCandidates = []
            panelTrust = .invalid
            link.confirmBoundIdentity(session.identifier)
        } catch PersistenceError.readOnlyUnsupportedSchema {
            rejectReadySession()
            applyLoad(store.load())
            isPersistenceWritable = false
            storageClassification = .stateVersionUnsupported
        } catch {
            rejectReadySession()
            applyLoad(store.load())
            storageClassification = .stateWriteFailed
        }
        publish()
    }

    func displayLinkDidDisconnect() {
        dispatchPrecondition(condition: .onQueue(queue))
        hasReadyWakeupConfiguration = false
        if binding == .bound, bleLink == .ready {
            bleLink = .disconnected
        }
        panelTrust = .invalid
        publish()
    }

    private func handle(_ command: RuntimeCommand) {
        switch command {
        case .refreshNow:
            refreshLocalActivity(forceScan: true)
        case .rebuildLocalMetrics:
            rebuildLocalMetrics()
        case .findAndBindDisplay:
            guard persistedBindingIdentifier == nil else { return }
            link.startBindScan()
        case .bindDisplay(let identifier):
            if let bound = persistedBindingIdentifier, bound != identifier {
                return
            }
            link.bind(identifier: identifier)
        case .unbindDisplay:
            performUnbind()
        case .setDisplayStyle(let style):
            guard isPersistenceWritable else { return }
            var candidate = productState
            candidate.preferences.displayStyle = style
            persistCandidate(candidate)
        case .savePreferences(let preferences):
            guard isPersistenceWritable else { return }
            var candidate = productState
            candidate.preferences = preferences
            persistCandidate(candidate)
        case .resetUsageInkData:
            link.unbind()
            do {
                try activityStore.destroyDatabase()
                try store.reset()
                applyLoad(store.load())
                localActivity = .unknown
                panelTrust = .invalid
                hasReadyWakeupConfiguration = false
            } catch {
                applyLoad(store.load())
                storageClassification = .stateWriteFailed
            }
        }
    }

    private func performUnbind() {
        link.unbind()
        var candidate = productState
        candidate.boundDisplay = nil
        candidate.setupDone = false
        candidate.refreshRecord = .default
        persistCandidate(candidate)
        binding = .unbound
        bleLink = .unbound
        hasReadyWakeupConfiguration = false
        lastBLEClassification = nil
        bindCandidates = []
        panelTrust = .invalid
    }

    private func rejectReadySession() {
        link.cancelWork()
        binding = .unbound
        bleLink = .unbound
        hasReadyWakeupConfiguration = false
        panelTrust = .invalid
        bluetoothBecameUnavailable = false
        link.confirmBoundIdentity(nil)
    }

    private func applyLoad(_ result: PersistenceLoadResult) {
        productState = result.state
        showsFirstRunDisclosure = result.showsFirstRunDisclosure
        shouldPresentSettingsOnLaunch = result.shouldPresentSettingsOnLaunch
        storageClassification = result.storageClassification
        isPersistenceWritable = result.isWritable
        hasReadyWakeupConfiguration = false
        lastBLEClassification = nil
        bindCandidates = []
        panelTrust = .invalid
        if productState.boundDisplay != nil {
            binding = .bound
            bleLink = .disconnected
        } else {
            binding = .unbound
            bleLink = .unbound
        }
    }

    private func persistCandidate(_ candidate: ProductState) {
        do {
            try store.save(candidate)
            productState = candidate
            showsFirstRunDisclosure = false
            shouldPresentSettingsOnLaunch = false
            storageClassification = nil
            isPersistenceWritable = true
            panelTrust = .invalid
        } catch PersistenceError.readOnlyUnsupportedSchema {
            applyLoad(store.load())
            isPersistenceWritable = false
            storageClassification = .stateVersionUnsupported
        } catch {
            applyLoad(store.load())
            storageClassification = .stateWriteFailed
        }
    }

    private var persistedBindingIdentifier: UUID? {
        guard let raw = productState.boundDisplay?.identifier else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private func publish() {
        dispatchPrecondition(condition: .onQueue(queue))
        snapshotHandler(makeSnapshot())
    }

    private func makeSnapshot() -> RuntimeSnapshot {
        let displayUnavailable = bleLink == .unavailable
            || bleLink == .unreachable
            || (lastBLEClassification?.showsDisplayUnavailable ?? false)
        return RuntimeSnapshot(
            statusSummary: formatter.summary(
                account: accountAvailability,
                local: localActivity,
                displayUnavailable: displayUnavailable,
                bleLink: bleLink,
                classification: lastBLEClassification
            ),
            binding: binding,
            displayStyle: productState.preferences.displayStyle,
            hasReadyWakeupConfiguration: hasReadyWakeupConfiguration,
            preferences: productState.preferences,
            panelTrust: panelTrust,
            showsFirstRunDisclosure: showsFirstRunDisclosure,
            shouldPresentSettingsOnLaunch: shouldPresentSettingsOnLaunch,
            storageClassification: storageClassification,
            isPersistenceWritable: isPersistenceWritable,
            bleLink: bleLink,
            bindCandidates: bindCandidates,
            lastBLEClassification: lastBLEClassification,
            localActivity: localActivity
        )
    }

    private func rebuildLocalMetrics() {
        do {
            try activityStore.rebuildDatabase()
        } catch {
            localActivity = LocalActivityObservation(
                availability: .unavailable,
                failure: "unknown",
                todayTokens: nil,
                weekTokens: nil,
                cacheHitRate: nil,
                tps: nil,
                coverageComplete: false
            )
            persistLocalSourceRecord(.default)
            return
        }
        persistLocalSourceRecord(.default)
        refreshLocalActivity(forceScan: true)
    }

    private func refreshLocalActivity(forceScan: Bool) {
        let timestamp = now()
        var calendar = LocalActivityMetrics.isoCalendar(timeZone: timeZone)
        calendar.timeZone = timeZone
        let rehydrated = activityStore.rehydrate(
            now: timestamp,
            calendar: calendar,
            timeZone: timeZone,
            tpsWindowMinutes: productState.preferences.tpsWindowMinutes,
            lastSuccessfulObservationAt: productState.localActivity.lastSuccessfulObservationAt,
            persistedAvailability: productState.localActivity.availability,
            persistedFailure: productState.localActivity.failure
        )
        localActivity = rehydrated
        if forceScan {
            localActivity = activityStore.ingest(
                codexHome: codexHome,
                pollStart: timestamp,
                now: timestamp,
                calendar: calendar,
                timeZone: timeZone,
                tpsWindowMinutes: productState.preferences.tpsWindowMinutes,
                prior: rehydrated
            )
            if !showsFirstRunDisclosure {
                persistLocalSourceRecord(record(from: localActivity, at: timestamp))
            }
        }
    }

    private func record(from observation: LocalActivityObservation, at timestamp: Date) -> LocalActivitySourceRecord {
        let lastSuccess: Int?
        if observation.todayTokens == nil {
            lastSuccess = nil
        } else {
            lastSuccess = Int(timestamp.timeIntervalSince1970.rounded(.towardZero))
        }
        return LocalActivitySourceRecord(
            lastSuccessfulObservationAt: lastSuccess,
            availability: observation.availability,
            failure: observation.failure
        )
    }

    private func persistLocalSourceRecord(_ record: LocalActivitySourceRecord) {
        guard isPersistenceWritable else { return }
        var candidate = productState
        candidate.localActivity = record
        do {
            try store.save(candidate)
            productState = candidate
        } catch PersistenceError.readOnlyUnsupportedSchema {
            applyLoad(store.load())
            isPersistenceWritable = false
            storageClassification = .stateVersionUnsupported
        } catch {
            storageClassification = .stateWriteFailed
        }
    }
}
