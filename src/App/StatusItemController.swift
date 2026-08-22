import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let settings: SettingsPanelController
    private let confirmations: ConfirmationPrompting
    var submit: (@Sendable (RuntimeCommand) -> Void)?
    private var snapshot: RuntimeSnapshot?

    init(settings: SettingsPanelController, confirmations: ConfirmationPrompting) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.settings = settings
        self.confirmations = confirmations
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "UsageInk")
        statusItem.button?.image?.isTemplate = true
        statusItem.menu = NSMenu()
    }

    var menu: NSMenu? {
        statusItem.menu
    }

    var isSettingsVisible: Bool {
        settings.isVisible
    }

    func apply(_ snapshot: RuntimeSnapshot) {
        self.snapshot = snapshot
        rebuildMenu()
    }

    func openSettings() {
        settings.show()
    }

    private func rebuildMenu() {
        guard let snapshot, let menu else {
            return
        }
        menu.removeAllItems()
        for spec in MenuBuilder.items(from: snapshot) {
            menu.addItem(makeItem(from: spec))
        }
    }

    private func makeItem(from spec: MenuItemSpec) -> NSMenuItem {
        let item = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(spec.identity.rawValue)
        item.isEnabled = spec.isEnabled
        item.state = spec.isChecked ? .on : .off
        item.target = spec.isEnabled ? self : nil
        item.action = action(for: spec.identity)

        if !spec.children.isEmpty {
            let submenu = NSMenu(title: spec.title)
            for child in spec.children {
                submenu.addItem(makeItem(from: child))
            }
            item.submenu = submenu
            item.action = nil
        }
        return item
    }

    private func action(for identity: MenuIdentity) -> Selector? {
        switch identity {
        case .statusSummary, .displayStyle:
            return nil
        case .refreshNow:
            return #selector(refreshNow)
        case .findAndBindDisplay:
            return #selector(findAndBindDisplay)
        case .unbindDisplay:
            return #selector(unbindDisplay)
        case .displayStyleBalanced:
            return #selector(selectBalanced)
        case .displayStyleQuotaFocus:
            return #selector(selectQuotaFocus)
        case .displayStyleActivityFocus:
            return #selector(selectActivityFocus)
        case .settings:
            return #selector(showSettings)
        case .configureWakeupPin:
            return #selector(configureWakeupPin)
        case .rebuildLocalMetrics:
            return #selector(rebuildLocalMetrics)
        case .resetUsageInkData:
            return #selector(resetUsageInkData)
        case .about:
            return #selector(showAbout)
        case .quit:
            return #selector(quit)
        }
    }

    @objc private func refreshNow() {
        submit?(.refreshNow)
    }

    @objc private func findAndBindDisplay() {
        submit?(.findAndBindDisplay)
    }

    @objc private func unbindDisplay() {
        if confirmations.confirmUnbindDisplay() {
            submit?(.unbindDisplay)
        }
    }

    @objc private func selectBalanced() {
        submit?(.setDisplayStyle(.balanced))
    }

    @objc private func selectQuotaFocus() {
        submit?(.setDisplayStyle(.quotaFocus))
    }

    @objc private func selectActivityFocus() {
        submit?(.setDisplayStyle(.activityFocus))
    }

    @objc private func showSettings() {
        settings.show()
    }

    @objc private func configureWakeupPin() {
        // Wakeup configuration is owned by a later ticket. The item exists only
        // when a ready BLE session already has a valid 13-byte configuration.
    }

    @objc private func rebuildLocalMetrics() {
        if confirmations.confirmRebuildLocalMetrics() {
            submit?(.rebuildLocalMetrics)
        }
    }

    @objc private func resetUsageInkData() {
        if confirmations.confirmResetUsageInkData() {
            submit?(.resetUsageInkData)
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "UsageInk"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        alert.informativeText = "Version \(version)"
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
