import AppKit

@MainActor
final class BindScanPanelController: NSObject {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("usageink.bind-scan")
    static let statusIdentifier = "bind.status"
    static let listIdentifier = "bind.candidates"

    private let panel: NSPanel
    private let statusField: NSTextField
    private let stack: NSStackView
    var submit: ((RuntimeCommand) -> Void)?

    override init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Find and Bind Display"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.identifier = Self.windowIdentifier
        panel.isExcludedFromWindowsMenu = true

        statusField = NSTextField(labelWithString: "Scanning for display")
        statusField.identifier = NSUserInterfaceItemIdentifier(Self.statusIdentifier)
        statusField.translatesAutoresizingMaskIntoConstraints = false

        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.identifier = NSUserInterfaceItemIdentifier(Self.listIdentifier)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusField)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            statusField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            statusField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: statusField.bottomAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])
        panel.contentView = content
        self.panel = panel
        super.init()
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var hostedPanel: NSPanel {
        panel
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func apply(_ snapshot: RuntimeSnapshot) {
        statusField.stringValue = statusText(from: snapshot)
        rebuildCandidates(snapshot.bindCandidates)
    }

    func view(withIdentifier identifier: String) -> NSView? {
        if identifier == Self.statusIdentifier {
            return statusField
        }
        if identifier == Self.listIdentifier {
            return stack
        }
        return stack.views.first { $0.identifier?.rawValue == identifier }
    }

    private func rebuildCandidates(_ candidates: [BindCandidate]) {
        stack.views.forEach { stack.removeView($0) }
        for candidate in candidates {
            let title = [
                candidate.advertisedName ?? "Unnamed",
                "\(candidate.rssi)",
                candidate.shortIdentifier,
            ].joined(separator: " · ")
            let button = NSButton(title: title, target: self, action: #selector(selectCandidate(_:)))
            button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier("bind.candidate.\(candidate.identifier.uuidString)")
            button.toolTip = candidate.identifier.uuidString
            stack.addArrangedSubview(button)
        }
    }

    private func statusText(from snapshot: RuntimeSnapshot) -> String {
        if snapshot.bleLink == .scanning {
            return "Scanning for display"
        }
        if snapshot.bindCandidates.isEmpty {
            return "No compatible Bound Display found"
        }
        return "Select a Bound Display"
    }

    @objc private func selectCandidate(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let uuidString = raw.split(separator: ".").last,
              let identifier = UUID(uuidString: String(uuidString)) else {
            return
        }
        submit?(.bindDisplay(identifier))
    }
}
