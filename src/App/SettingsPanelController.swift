import AppKit

@MainActor
final class SettingsPanelController {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("usageink.settings")

    private let panel: NSPanel

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.identifier = Self.windowIdentifier
        panel.isExcludedFromWindowsMenu = true

        let label = NSTextField(labelWithString: "UsageInk")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 15, weight: .semibold)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
        ])
        panel.contentView = content
        self.panel = panel
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var panelCount: Int {
        1
    }

    func show() {
        NSApp.activate()
        if !panel.isVisible {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
    }
}
