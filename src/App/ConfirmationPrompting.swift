import AppKit

@MainActor
protocol ConfirmationPrompting: AnyObject {
    func confirmUnbindDisplay() -> Bool
    func confirmRebuildLocalMetrics() -> Bool
    func confirmResetUsageInkData() -> Bool
}

@MainActor
final class AlertConfirmationPrompt: ConfirmationPrompting {
    func confirmUnbindDisplay() -> Bool {
        confirm(
            message: "Unbind Display",
            information: "UsageInk will stop sending Display Frames to the Bound Display."
        )
    }

    func confirmRebuildLocalMetrics() -> Bool {
        confirm(
            message: "Rebuild Local Metrics",
            information: "UsageInk will rebuild local metrics from allowed local sources."
        )
    }

    func confirmResetUsageInkData() -> Bool {
        confirm(
            message: "Reset UsageInk Data",
            information: "This clears local UsageInk data. It does not change ~/.codex or the Bound Display."
        )
    }

    private func confirm(message: String, information: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        alert.alertStyle = .warning
        alert.addButton(withTitle: message)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
