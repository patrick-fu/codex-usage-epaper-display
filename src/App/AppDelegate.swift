import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    private(set) var runtime: UsageInkRuntime!
    private(set) var statusItemController: StatusItemController!
    private(set) var settingsPanelController: SettingsPanelController!

    override init() {
        super.init()
        if AppDelegate.shared == nil {
            AppDelegate.shared = self
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if statusItemController != nil {
            return
        }
        PersistenceLocation.installTestHostIsolationIfNeeded()
        ActivityLocation.installTestHostIsolationIfNeeded()
        _ = NSApp.setActivationPolicy(.accessory)

        let settings = SettingsPanelController()
        settingsPanelController = settings
        let controller = StatusItemController(
            settings: settings,
            confirmations: AlertConfirmationPrompt()
        )
        statusItemController = controller

        let sink = MainSnapshotSink { snapshot in
            controller.apply(snapshot)
        }
        let runtime = UsageInkRuntime(makeLink: Self.makeDisplayLink) { snapshot in
            sink.publish(snapshot)
        }
        self.runtime = runtime
        controller.submit = { command in
            runtime.submit(command)
        }
        settings.submit = { command in
            runtime.submit(command)
        }
        runtime.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }
}

extension AppDelegate {
    nonisolated fileprivate static func makeDisplayLink(queue: DispatchQueue) -> DisplayLinkControlling {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return NullDisplayLink()
        }
        return ReadySessionCoordinator(
            radio: NRF5Radio(queue: queue),
            clock: DispatchDisplayClock(queue: queue)
        )
    }
}

private final class MainSnapshotSink: @unchecked Sendable {
    private let apply: @MainActor @Sendable (RuntimeSnapshot) -> Void

    init(apply: @escaping @MainActor @Sendable (RuntimeSnapshot) -> Void) {
        self.apply = apply
    }

    func publish(_ snapshot: RuntimeSnapshot) {
        Task { @MainActor in
            apply(snapshot)
        }
    }
}
