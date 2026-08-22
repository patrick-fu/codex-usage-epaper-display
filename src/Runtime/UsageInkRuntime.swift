import Foundation

enum RuntimeCommand: Sendable, Equatable {
    case refreshNow
    case findAndBindDisplay
    case bindDisplay(UUID)
    case unbindDisplay
    case setDisplayStyle(DisplayStyle)
    case savePreferences(DisplayPreferences)
    case configureWakeupPin(WakeupPinWriteRequest)
    case rebuildLocalMetrics
    case resetUsageInkData
}

struct RuntimeSnapshot: Sendable, Equatable {
    var statusSummary: String
    var binding: BindingPresentation
    var displayStyle: DisplayStyle
    var hasReadyWakeupConfiguration: Bool
    var wakeupConfiguration: ReadyWakeupConfiguration? = nil
    var preferences: DisplayPreferences = .default
    var panelTrust: PanelTrust = .invalid
    var showsFirstRunDisclosure: Bool = false
    var shouldPresentSettingsOnLaunch: Bool = false
    var storageClassification: StorageClassification? = nil
    var isPersistenceWritable: Bool = true
    var bleLink: BLELinkState = .unbound
    var bindCandidates: [BindCandidate] = []
    var lastBLEClassification: BLEClassification? = nil
    var account: AccountObservation = .unknown
}

final class UsageInkRuntime: @unchecked Sendable, DisplayLinkDelegate {
    static let queueLabel = "com.patrickfu.UsageInk.runtime"

    private let queue: DispatchQueue
    private let snapshotHandler: @Sendable (RuntimeSnapshot) -> Void
    private let formatter: StatusSummaryFormatter
    private let store: PersistenceStore
    private let link: DisplayLinkControlling
    private var productState: ProductState = .default
    private var binding: BindingPresentation = .unbound
    private var readySession: ReadyBLESession?
    private var wakeupConsent: WakeupPinWriteRequest?
    private var localAvailability: SourceAvailability = .unknown
    private var panelTrust: PanelTrust = .invalid
    private var showsFirstRunDisclosure = true
    private var shouldPresentSettingsOnLaunch = true
    private var storageClassification: StorageClassification?
    private var isPersistenceWritable = true
    private var bleLink: BLELinkState = .unbound
    private var bindCandidates: [BindCandidate] = []
    private var lastBLEClassification: BLEClassification?
    private var bluetoothBecameUnavailable = false
    private var compositionSession = DisplayCompositionSession()

    var persistenceRoot: URL {
        store.root
    }

    private let codex: CodexPollingDependencies
    private var accountObservation: AccountObservation = .unknown
    private var pollRunning = false

    init(
        language: ResolvedInterfaceLanguage = .resolveSystem(),
        store: PersistenceStore = PersistenceStore(),
        makeLink: ((DispatchQueue) -> DisplayLinkControlling)? = nil,
        makeCodex: ((DispatchQueue) -> CodexPollingDependencies)? = nil,
        snapshotHandler: @escaping @Sendable (RuntimeSnapshot) -> Void
    ) {
        self.queue = DispatchQueue(label: Self.queueLabel, qos: .userInitiated)
        self.formatter = StatusSummaryFormatter(language: language)
        self.store = store
        self.snapshotHandler = snapshotHandler
        self.link = makeLink?(queue) ?? NullDisplayLink()
        if let makeCodex {
            self.codex = makeCodex(queue)
        } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            self.codex = .disabled()
        } else {
            self.codex = .live(queue: queue)
        }
        self.link.delegate = self
    }

    func start() {
        queue.async { [self] in
            applyLoad(store.load())
            panelTrust = .invalid
            clearReadySession()
            lastBLEClassification = nil
            bindCandidates = []
            bluetoothBecameUnavailable = false
            link.confirmBoundIdentity(persistedBindingIdentifier)
            link.attach()
            publish()
            startAccountPoll()
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
            clearReadySession()
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
            clearReadySession()
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
        clearReadySession()
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
            readySession = session
            wakeupConsent = nil
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

    func displayLinkDidUpdateReadyConfig(_ config: EPDConfig) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var session = readySession else {
            return
        }
        if session.config.digest != config.digest {
            wakeupConsent = nil
        }
        session.config = config
        readySession = session
        publish()
    }

    func displayLinkDidFinishConfigWrite(succeeded: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        if wakeupConsent != nil {
            wakeupConsent = nil
        }
        _ = succeeded
        publish()
    }

    func displayLinkDidDisconnect() {
        dispatchPrecondition(condition: .onQueue(queue))
        clearReadySession()
        if binding == .bound, bleLink == .ready {
            bleLink = .disconnected
        }
        panelTrust = .invalid
        publish()
    }

    private func handle(_ command: RuntimeCommand) {
        switch command {
        case .refreshNow:
            startAccountPoll()
        case .rebuildLocalMetrics:
            break
        case .findAndBindDisplay:
            guard persistedBindingIdentifier == nil else { return }
            link.startBindScan()
        case .bindDisplay(let identifier):
            if let bound = persistedBindingIdentifier, bound != identifier {
                return
            }
            link.bind(identifier: identifier)
        case .configureWakeupPin(let request):
            applyWakeupPinWrite(request)
        case .unbindDisplay:
            performUnbind()
        case .setDisplayStyle(let style):
            guard isPersistenceWritable else { return }
            var candidate = productState
            candidate.preferences.displayStyle = style
            persistCandidate(candidate, enqueueConfiguration: true)
        case .savePreferences(let preferences):
            guard isPersistenceWritable else { return }
            var candidate = productState
            candidate.preferences = preferences
            persistCandidate(candidate, enqueueConfiguration: true)
        case .resetUsageInkData:
            link.unbind()
            do {
                try store.reset()
                applyLoad(store.load())
                panelTrust = .invalid
                clearReadySession()
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
        clearReadySession()
        lastBLEClassification = nil
        bindCandidates = []
        panelTrust = .invalid
    }

    private func rejectReadySession() {
        link.cancelWork()
        binding = .unbound
        bleLink = .unbound
        clearReadySession()
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
        clearReadySession()
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
        accountObservation = AccountObservation(
            availability: staleIfNeeded(productState.account.availability, lastSuccess: productState.account.lastSuccessfulObservationAt),
            failure: productState.account.failure,
            planType: productState.account.planType,
            windows: productState.account.windows.map { window in
                UsageWindowObservation(
                    slot: UsageWindowSlot(rawValue: window.slot) ?? .primary,
                    usedPercent: window.usedPercent,
                    windowDurationMins: window.windowDurationMins,
                    resetsAt: window.resetsAt
                )
            }
        )
    }

    private var hasReadyWakeupConfiguration: Bool {
        bleLink == .ready && readySession != nil
    }

    private var publishedWakeupConfiguration: ReadyWakeupConfiguration? {
        guard hasReadyWakeupConfiguration, let session = readySession else {
            return nil
        }
        return ReadyWakeupConfiguration(
            pin: session.config.wakeupPin,
            sessionGeneration: session.generation,
            configDigest: session.config.digest
        )
    }

    private func clearReadySession() {
        readySession = nil
        wakeupConsent = nil
    }

    private func applyWakeupPinWrite(_ request: WakeupPinWriteRequest) {
        wakeupConsent = request
        guard WakeupPin.isAllowed(request.pin) else {
            wakeupConsent = nil
            return
        }
        guard bleLink == .ready,
              let session = readySession,
              session.generation == request.sessionGeneration,
              session.config.digest == request.configDigest
        else {
            wakeupConsent = nil
            return
        }
        let issued = link.writeWakeupPin(
            request.pin,
            sessionGeneration: request.sessionGeneration,
            configDigest: request.configDigest
        )
        if !issued {
            wakeupConsent = nil
        }
    }

    private func persistCandidate(_ candidate: ProductState, enqueueConfiguration: Bool = false) {
        do {
            try store.save(candidate)
            productState = candidate
            showsFirstRunDisclosure = false
            shouldPresentSettingsOnLaunch = false
            storageClassification = nil
            isPersistenceWritable = true
            panelTrust = .invalid
            if enqueueConfiguration {
                DisplayCompositionCoordinator.applyConfiguration(
                    session: &compositionSession,
                    preferences: productState.preferences,
                    fallbackInput: fallbackCompositionInput(preferences: productState.preferences)
                )
            }
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
                account: accountObservation,
                local: localAvailability,
                displayUnavailable: displayUnavailable,
                bleLink: bleLink,
                classification: lastBLEClassification
            ),
            binding: binding,
            displayStyle: productState.preferences.displayStyle,
            hasReadyWakeupConfiguration: hasReadyWakeupConfiguration,
            wakeupConfiguration: publishedWakeupConfiguration,
            preferences: productState.preferences,
            panelTrust: panelTrust,
            showsFirstRunDisclosure: showsFirstRunDisclosure,
            shouldPresentSettingsOnLaunch: shouldPresentSettingsOnLaunch,
            storageClassification: storageClassification,
            isPersistenceWritable: isPersistenceWritable,
            bleLink: bleLink,
            bindCandidates: bindCandidates,
            lastBLEClassification: lastBLEClassification,
            account: accountObservation
        )
    }

    var inFlightFrame: DisplayFrame? {
        queue.sync { compositionSession.inFlightFrame }
    }

    var pendingAutomaticInput: DisplayFrameInput? {
        queue.sync { compositionSession.pendingAutomatic }
    }

    func beginInFlightComposition(_ input: DisplayFrameInput) throws -> DisplayFrame {
        var frame: DisplayFrame?
        var caught: Error?
        queue.sync {
            do {
                frame = try DisplayCompositionCoordinator.beginInFlight(
                    session: &compositionSession,
                    input: input
                )
            } catch {
                caught = error
            }
        }
        if let caught {
            throw caught
        }
        return try unwrapFrame(frame)
    }

    func finishInFlightComposition() -> DisplayFrameInput? {
        queue.sync {
            DisplayCompositionCoordinator.finishInFlight(session: &compositionSession)
        }
    }

    private func unwrapFrame(_ frame: DisplayFrame?) throws -> DisplayFrame {
        guard let frame else {
            throw DisplayCompositionMissingFrame()
        }
        return frame
    }

    private func fallbackCompositionInput(preferences: DisplayPreferences) -> DisplayFrameInput {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return DisplayFrameInput(
            preferences: preferences,
            account: .unknown,
            localActivity: .unknown,
            composedAt: Date(),
            calendar: calendar,
            timeZone: .current,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    private func startAccountPoll() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard codex.isEnabled else {
            return
        }
        if pollRunning {
            return
        }
        pollRunning = true
        let explicitPath = productState.preferences.customCodexPath
        let appVersion = codex.appVersion
        codex.probeQueue.async { [self] in
            let resolved = self.codex.resolve(explicitPath)
            self.queue.async {
                self.handleResolvedBinary(resolved, appVersion: appVersion)
            }
        }
    }

    private func handleResolvedBinary(
        _ resolved: Result<CodexResolvedBinary, CodexFailure>,
        appVersion: String
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard pollRunning else {
            return
        }
        switch resolved {
        case .failure(let failure):
            applyAccountFailure(failure)
            pollRunning = false
            publish()
        case .success(let binary):
            codex.poll(binary.path, appVersion) { [weak self] result in
                guard let self else {
                    return
                }
                self.queue.async {
                    switch result {
                    case .success(let snapshot):
                        self.applyAccountSuccess(snapshot)
                    case .failure(let failure):
                        self.applyAccountFailure(failure)
                    }
                    self.pollRunning = false
                    self.publish()
                }
            }
        }
    }

    private func applyAccountSuccess(_ snapshot: CodexUsageSnapshot) {
        let observedAt = Int(codex.now().timeIntervalSince1970)
        accountObservation = AccountObservation(
            availability: .fresh,
            failure: nil,
            planType: snapshot.planType,
            windows: snapshot.windows
        )
        var candidate = productState
        candidate.account.lastSuccessfulObservationAt = observedAt
        candidate.account.availability = .fresh
        candidate.account.failure = nil
        candidate.account.planType = snapshot.planType
        candidate.account.windows = snapshot.windows.compactMap { window in
            guard let resetsAt = window.resetsAt else {
                return nil
            }
            return UsageWindowRecord(
                slot: window.slot.rawValue,
                usedPercent: window.usedPercent,
                windowDurationMins: window.windowDurationMins,
                resetsAt: resetsAt
            )
        }
        persistAccount(candidate)
    }

    private func applyAccountFailure(_ failure: CodexFailure) {
        let availability: PersistedAvailability
        switch failure {
        case .authRequired:
            availability = .authRequired
        default:
            availability = .unavailable
        }
        accountObservation.availability = availability
        accountObservation.failure = failure.rawValue
        var candidate = productState
        candidate.account.availability = availability
        candidate.account.failure = failure.rawValue
        persistAccount(candidate)
    }

    private func persistAccount(_ candidate: ProductState) {
        do {
            try store.save(candidate)
            productState = candidate
            storageClassification = nil
            isPersistenceWritable = true
        } catch PersistenceError.readOnlyUnsupportedSchema {
            applyLoad(store.load())
            isPersistenceWritable = false
            storageClassification = .stateVersionUnsupported
        } catch {
            applyLoad(store.load())
            storageClassification = .stateWriteFailed
        }
    }

    private func staleIfNeeded(_ availability: PersistedAvailability, lastSuccess: Int?) -> PersistedAvailability {
        guard availability == .fresh, let lastSuccess else {
            return availability
        }
        let age = codex.now().timeIntervalSince1970 - TimeInterval(lastSuccess)
        if age >= 20 * 60 {
            return .stale
        }
        return availability
    }
}

struct DisplayCompositionMissingFrame: Error {}
