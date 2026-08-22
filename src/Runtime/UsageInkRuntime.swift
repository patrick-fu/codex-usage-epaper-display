import Foundation

enum RuntimeCommand: Sendable, Equatable {
    case refreshNow
    case hostWillSleep
    case hostDidWake
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
    private let clock: DisplayClock
    private let timeZone: TimeZone
    private let link: DisplayLinkControlling
    private var productState: ProductState = .default
    private var binding: BindingPresentation = .unbound
    private var readySession: ReadyBLESession?
    private var wakeupConsent: WakeupPinWriteRequest?
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
    private var compositionSession = DisplayCompositionSession()

    var persistenceRoot: URL {
        store.root
    }

    private let codex: CodexPollingDependencies
    private var accountObservation: AccountObservation = .unknown
    private var pollRunning = false
    private var manualRefreshPending = false
    private var automaticRefreshPending = false
    private var transferActive = false
    private var inFlightManualRequest = false
    private var queuedManualAfterTransfer = false
    private var queuedAutomaticAfterTransfer = false
    private var pollAttempted = false
    private var pollTerminal = false
    private var pollGeneration: UInt64 = 0
    private var pollDeadline: Date?
    private var sleeping = false

    private static let pollTimerID = "runtime.poll"
    private static let freshnessTimerID = "runtime.freshness"

    init(
        language: ResolvedInterfaceLanguage = .resolveSystem(),
        store: PersistenceStore = PersistenceStore(),
        activityStore: ActivityStore? = nil,
        codexHome: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        clock: DisplayClock? = nil,
        timeZone: TimeZone = .current,
        makeLink: ((DispatchQueue) -> DisplayLinkControlling)? = nil,
        makeCodex: ((DispatchQueue) -> CodexPollingDependencies)? = nil,
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
        self.clock = clock ?? DispatchDisplayClock(queue: queue)
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
            refreshLocalActivity(forceScan: false)
            if accountObservation.availability == .stale,
               productState.account.availability != .stale {
                var candidate = productState
                candidate.account.availability = .stale
                persistAccount(candidate)
            }
            link.confirmBoundIdentity(persistedBindingIdentifier)
            link.attach()
            scheduleFreshnessCheck()
            if persistedBindingIdentifier != nil {
                automaticRefreshPending = true
                if needsPollForEnabledSources {
                    startPoll()
                } else {
                    resetPollDeadline(from: now())
                    ensureRecovery()
                    processRefreshRequest()
                }
            } else if needsPollForEnabledSources {
                startPoll()
            } else {
                resetPollDeadline(from: now())
            }
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
            clearReadySession()
            panelTrust = .invalid
        case .poweredOn:
            if (bluetoothBecameUnavailable || hasRefreshRequest), let identifier = persistedBindingIdentifier {
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
        switch state {
        case .disconnected, .unbound, .unavailable, .unreachable:
            clearReadySession()
        case .ready, .scanning, .connecting, .discovering, .subscribing, .awaitingConfig, .initializing:
            break
        }
        if state == .ready {
            processRefreshRequest()
        }
        publish()
    }

    func displayLinkDidUpdateCandidates(_ candidates: [BindCandidate]) {
        dispatchPrecondition(condition: .onQueue(queue))
        bindCandidates = candidates
        publish()
    }

    func displayLinkDidClassify(_ classification: BLEClassification) {
        dispatchPrecondition(condition: .onQueue(queue))
        lastBLEClassification = classification
        switch classification {
        case .planeTimeout, .refreshTimeout, .mtuInvalid, .initTimeout,
             .disconnected, .callbackAmbiguous, .retryExhausted:
            panelTrust = .invalid
        default:
            break
        }
        publish()
    }

    func displayLinkDidBecomeReady(_ session: ReadyBLESession) {
        dispatchPrecondition(condition: .onQueue(queue))
        let isFirstUsableBinding = persistedBindingIdentifier == nil
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
            // A first usable binding owns an initial full frame, even with degraded data.
            automaticRefreshPending = true
            if isFirstUsableBinding, !pollRunning {
                startPoll()
            }
            processRefreshRequest()
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

    func displayLinkDidCompleteRefresh() {
        dispatchPrecondition(condition: .onQueue(queue))
        transferActive = false
        if inFlightManualRequest {
            manualRefreshPending = false
        } else {
            automaticRefreshPending = false
        }
        inFlightManualRequest = false
        panelTrust = .assumed
        if let fingerprint = compositionSession.inFlightFrame?.fingerprint {
            var candidate = productState
            candidate.setupDone = true
            candidate.refreshRecord.lastSucceededFingerprint = fingerprint
            candidate.refreshRecord.lastSuccessfulRefreshAt = Int(now().timeIntervalSince1970)
            persistRefreshSuccess(candidate)
        }
        let laterAutomatic = DisplayCompositionCoordinator.finishInFlight(session: &compositionSession)
        automaticRefreshPending = queuedAutomaticAfterTransfer || laterAutomatic != nil
        queuedAutomaticAfterTransfer = false
        if queuedManualAfterTransfer {
            queuedManualAfterTransfer = false
            requestManualRefresh(resetDeadline: false)
        } else {
            processRefreshRequest()
        }
        publish()
    }

    func displayLinkDidFailRefresh(_ classification: BLEClassification) {
        dispatchPrecondition(condition: .onQueue(queue))
        transferActive = false
        let wasManual = inFlightManualRequest
        if wasManual {
            manualRefreshPending = false
        }
        inFlightManualRequest = false
        panelTrust = .invalid
        lastBLEClassification = classification
        let laterAutomatic = DisplayCompositionCoordinator.finishInFlight(session: &compositionSession)
        automaticRefreshPending = queuedAutomaticAfterTransfer || laterAutomatic != nil || !wasManual
        queuedAutomaticAfterTransfer = false
        if queuedManualAfterTransfer {
            queuedManualAfterTransfer = false
            requestManualRefresh(resetDeadline: false)
        } else {
            processRefreshRequest()
        }
        publish()
    }

    func displayLinkDidDisconnect() {
        dispatchPrecondition(condition: .onQueue(queue))
        transferActive = false
        clearReadySession()
        if binding == .bound, bleLink == .ready {
            bleLink = .disconnected
        }
        panelTrust = .invalid
        if persistedBindingIdentifier != nil {
            automaticRefreshPending = true
            if !sleeping {
                ensureRecovery()
            }
        }
        publish()
    }

    private func handle(_ command: RuntimeCommand) {
        switch command {
        case .refreshNow:
            requestManualRefresh()
        case .hostWillSleep:
            handleHostWillSleep()
        case .hostDidWake:
            handleHostDidWake()
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
                try activityStore.destroyDatabase()
                try store.reset()
                applyLoad(store.load())
                localActivity = .unknown
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
            if enqueueConfiguration {
                DisplayCompositionCoordinator.applyConfiguration(
                    session: &compositionSession,
                    preferences: productState.preferences,
                    fallbackInput: fallbackCompositionInput(preferences: productState.preferences)
                )
                automaticRefreshPending = true
                processRefreshRequest(allowAutomaticPoll: false)
            }
        } catch PersistenceError.readOnlyUnsupportedSchema {
            notePersistenceFailure(.readOnlyUnsupportedSchema)
        } catch {
            notePersistenceFailure(.writeFailed)
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
                local: localActivity,
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
            account: accountObservation,
            localActivity: localActivity
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
        calendar.timeZone = timeZone
        return DisplayFrameInput(
            preferences: preferences,
            account: accountObservation,
            localActivity: localActivity,
            composedAt: now(),
            calendar: calendar,
            timeZone: timeZone,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    private func requestManualRefresh(resetDeadline: Bool = true) {
        dispatchPrecondition(condition: .onQueue(queue))
        if resetDeadline {
            resetPollDeadline(from: now())
        }
        if transferActive {
            queuedManualAfterTransfer = true
            return
        }
        manualRefreshPending = true
        if pollRunning {
            return
        }
        pollAttempted = false
        pollTerminal = false
        startPoll(resetDeadline: false)
        processRefreshRequest()
    }

    private var hasRefreshRequest: Bool {
        manualRefreshPending || automaticRefreshPending
    }

    private var accountEnabled: Bool {
        productState.preferences.modules.plan || productState.preferences.modules.quota
    }

    private var localEnabled: Bool {
        let modules = productState.preferences.modules
        return modules.today || modules.weekTokens || modules.cache || modules.tps
    }

    private var needsPollForEnabledSources: Bool {
        (accountEnabled && accountObservation.availability != .fresh)
            || (localEnabled && localActivity.availability != .fresh)
    }

    private func processRefreshRequest(allowAutomaticPoll: Bool = true) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard hasRefreshRequest, !transferActive, !sleeping else {
            return
        }
        if manualRefreshPending && !pollTerminal {
            startPoll(resetDeadline: false)
            return
        }
        if allowAutomaticPoll, needsPollForEnabledSources, !pollAttempted {
            startPoll()
            return
        }
        guard !pollRunning else {
            return
        }
        guard persistedBindingIdentifier != nil else {
            return
        }
        do {
            compositionSession.pendingAutomatic = nil
            let frame = try DisplayCompositionCoordinator.beginInFlight(
                session: &compositionSession,
                input: fallbackCompositionInput(preferences: productState.preferences)
            )
            if !manualRefreshPending,
               panelTrust == .assumed,
               productState.refreshRecord.lastSucceededFingerprint == frame.fingerprint {
                _ = DisplayCompositionCoordinator.finishInFlight(session: &compositionSession)
                automaticRefreshPending = false
                return
            }
            startTransferIfNeeded()
        } catch {
            return
        }
    }

    private func startTransferIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard hasRefreshRequest, !transferActive else {
            return
        }
        guard let frame = compositionSession.inFlightFrame,
              bleLink == .ready,
              let session = readySession else {
            return
        }
        inFlightManualRequest = manualRefreshPending
        transferActive = link.transferDisplayFrame(
            blackPlane: frame.blackPlane,
            redPlane: frame.redPlane,
            sessionGeneration: session.generation
        )
        if !transferActive, persistedBindingIdentifier != nil {
            ensureRecovery()
        }
    }

    private func persistRefreshSuccess(_ candidate: ProductState) {
        do {
            try store.save(candidate)
            productState = candidate
            storageClassification = nil
            isPersistenceWritable = true
        } catch PersistenceError.readOnlyUnsupportedSchema {
            notePersistenceFailure(.readOnlyUnsupportedSchema)
        } catch {
            notePersistenceFailure(.writeFailed)
        }
    }

    private func startPoll(resetDeadline: Bool = true) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !sleeping else {
            return
        }
        if pollRunning {
            return
        }
        let start = now()
        if resetDeadline {
            resetPollDeadline(from: start)
        }
        pollAttempted = true
        pollTerminal = false
        pollRunning = true
        let generation = pollGeneration
        refreshLocalActivity(forceScan: true)
        guard codex.isEnabled else {
            finishPoll(generation: generation)
            return
        }
        let explicitPath = productState.preferences.customCodexPath
        let appVersion = codex.appVersion
        codex.probeQueue.async { [self] in
            let resolved = self.codex.resolve(explicitPath)
            self.queue.async {
                self.handleResolvedBinary(resolved, appVersion: appVersion, generation: generation)
            }
        }
    }

    private func handleResolvedBinary(
        _ resolved: Result<CodexResolvedBinary, CodexFailure>,
        appVersion: String,
        generation: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard pollRunning, generation == pollGeneration else {
            return
        }
        switch resolved {
        case .failure(let failure):
            applyAccountFailure(failure)
            finishPoll(generation: generation)
            publish()
        case .success(let binary):
            codex.poll(binary.path, appVersion) { [weak self] result in
                guard let self else {
                    return
                }
                self.queue.async {
                    guard generation == self.pollGeneration, self.pollRunning else {
                        return
                    }
                    switch result {
                    case .success(let snapshot):
                        self.applyAccountSuccess(snapshot)
                    case .failure(let failure):
                        self.applyAccountFailure(failure)
                    }
                    self.finishPoll(generation: generation)
                    self.publish()
                }
            }
        }
    }

    private func finishPoll(generation: UInt64) {
        guard generation == pollGeneration else {
            return
        }
        pollRunning = false
        pollTerminal = true
        scheduleFreshnessCheck()
        if hasRefreshRequest {
            if persistedBindingIdentifier != nil {
                ensureRecovery()
            }
            processRefreshRequest()
        }
    }

    private func resetPollDeadline(from start: Date) {
        pollDeadline = start.addingTimeInterval(15 * 60)
        schedulePollTimer()
    }

    private func schedulePollTimer() {
        guard !sleeping, let deadline = pollDeadline else {
            return
        }
        clock.schedule(id: Self.pollTimerID, after: max(0, deadline.timeIntervalSince(now()))) { [weak self] in
            self?.queue.async {
                guard let self, !self.sleeping else { return }
                if self.transferActive {
                    self.queuedAutomaticAfterTransfer = true
                } else {
                    self.automaticRefreshPending = true
                }
                self.pollAttempted = false
                self.pollTerminal = false
                self.startPoll()
                self.processRefreshRequest()
                self.publish()
            }
        }
    }

    private func scheduleFreshnessCheck() {
        clock.cancel(id: Self.freshnessTimerID)
        guard !sleeping else { return }
        let timestamp = now()
        var dates: [Date] = []
        if accountEnabled,
           productState.account.availability == .fresh,
           let success = productState.account.lastSuccessfulObservationAt {
            dates.append(Date(timeIntervalSince1970: TimeInterval(success + 20 * 60)))
        }
        if localEnabled,
           productState.localActivity.availability == .fresh,
           let success = productState.localActivity.lastSuccessfulObservationAt {
            dates.append(Date(timeIntervalSince1970: TimeInterval(success + 20 * 60)))
        }
        guard let next = dates.min() else { return }
        clock.schedule(id: Self.freshnessTimerID, after: max(0, next.timeIntervalSince(timestamp))) { [weak self] in
            self?.queue.async {
                guard let self, !self.sleeping else { return }
                self.refreshFreshness()
                self.publish()
            }
        }
    }

    private func refreshFreshness() {
        let oldAccount = accountObservation.availability
        let oldLocal = localActivity.availability
        let accountAvailability = staleIfNeeded(
            productState.account.availability,
            lastSuccess: productState.account.lastSuccessfulObservationAt
        )
        if accountAvailability != productState.account.availability {
            accountObservation.availability = accountAvailability
            var candidate = productState
            candidate.account.availability = accountAvailability
            persistAccount(candidate)
        }
        refreshLocalActivity(forceScan: false)
        if localActivity.availability == .stale,
           productState.localActivity.availability != .stale {
            persistLocalSourceRecord(
                LocalActivitySourceRecord(
                    lastSuccessfulObservationAt: productState.localActivity.lastSuccessfulObservationAt,
                    availability: .stale,
                    failure: productState.localActivity.failure
                )
            )
        }
        if oldAccount == .fresh && accountObservation.availability == .stale
            || oldLocal == .fresh && localActivity.availability == .stale {
            if transferActive {
                queuedAutomaticAfterTransfer = true
            } else {
                automaticRefreshPending = true
            }
            pollAttempted = false
            pollTerminal = false
            startPoll()
            processRefreshRequest()
        }
        scheduleFreshnessCheck()
    }

    private func ensureRecovery() {
        guard !sleeping,
              hasRefreshRequest,
              let identifier = persistedBindingIdentifier,
              bleLink != .ready,
              bleLink != .scanning,
              bleLink != .connecting,
              bleLink != .discovering,
              bleLink != .subscribing,
              bleLink != .awaitingConfig,
              bleLink != .initializing
        else { return }
        link.recover(identifier: identifier)
    }

    private func applyAccountSuccess(_ snapshot: CodexUsageSnapshot) {
        let observedAt = Int(now().timeIntervalSince1970)
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
            notePersistenceFailure(.readOnlyUnsupportedSchema)
        } catch {
            notePersistenceFailure(.writeFailed)
        }
    }

    private func staleIfNeeded(_ availability: PersistedAvailability, lastSuccess: Int?) -> PersistedAvailability {
        guard availability == .fresh, let lastSuccess else {
            return availability
        }
        let age = now().timeIntervalSince1970 - TimeInterval(lastSuccess)
        if age >= 20 * 60 {
            return .stale
        }
        return availability
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
            refreshLocalActivity(forceScan: true)
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
        if !forceScan,
           rehydrated.availability == .stale,
           productState.localActivity.availability != .stale {
            persistLocalSourceRecord(
                LocalActivitySourceRecord(
                    lastSuccessfulObservationAt: productState.localActivity.lastSuccessfulObservationAt,
                    availability: .stale,
                    failure: productState.localActivity.failure
                )
            )
        }
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
        LocalActivitySourceRecord.capturing(
            observation: observation,
            at: timestamp,
            prior: productState.localActivity
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
            notePersistenceFailure(.readOnlyUnsupportedSchema)
        } catch {
            notePersistenceFailure(.writeFailed)
        }
    }

    private func handleHostWillSleep() {
        dispatchPrecondition(condition: .onQueue(queue))
        sleeping = true
        clock.cancel(id: Self.pollTimerID)
        clock.cancel(id: Self.freshnessTimerID)
        pollGeneration &+= 1
        pollRunning = false
        pollTerminal = false
        codex.cancel()
        if !hasRefreshRequest {
            automaticRefreshPending = persistedBindingIdentifier != nil
        }
        transferActive = false
        panelTrust = .invalid
        clearReadySession()
        link.noteHostWillSleep()
    }

    private func handleHostDidWake() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard sleeping else { return }
        sleeping = false
        automaticRefreshPending = automaticRefreshPending || persistedBindingIdentifier != nil
        let overdue = pollDeadline.map { $0 <= now() } ?? false
        pollAttempted = false
        pollTerminal = false
        if overdue || needsPollForEnabledSources {
            startPoll()
        } else {
            schedulePollTimer()
            scheduleFreshnessCheck()
        }
        ensureRecovery()
        processRefreshRequest()
    }

    private func notePersistenceFailure(_ error: PersistenceError) {
        switch error {
        case .readOnlyUnsupportedSchema:
            isPersistenceWritable = false
            storageClassification = .stateVersionUnsupported
        default:
            storageClassification = .stateWriteFailed
        }
    }
}

struct DisplayCompositionMissingFrame: Error {}
