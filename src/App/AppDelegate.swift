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
        let runtime = UsageInkRuntime { snapshot in
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
