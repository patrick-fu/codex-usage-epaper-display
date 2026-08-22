import AppKit

@MainActor
protocol ConfirmationPrompting: AnyObject {
    func confirmUnbindDisplay() -> Bool
    func confirmRebuildLocalMetrics() -> Bool
    func confirmResetUsageInkData() -> Bool
    func requestWakeupPinValue(current: UInt8) -> UInt8?
    func confirmWakeupPinChange(from old: UInt8, to new: UInt8) -> Bool
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

    func requestWakeupPinValue(current: UInt8) -> UInt8? {
        let alert = NSAlert()
        alert.messageText = WakeupPinCopy.requestMessage
        alert.informativeText = WakeupPinCopy.requestInformation
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: current == WakeupPin.disabled ? "disabled" : "\(current)")
        field.identifier = NSUserInterfaceItemIdentifier("wakeup.pin.field")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return WakeupPin.parse(field.stringValue)
    }

    func confirmWakeupPinChange(from old: UInt8, to new: UInt8) -> Bool {
        confirm(
            message: WakeupPinCopy.confirmationMessage,
            information: WakeupPinCopy.confirmationInformation(from: old, to: new)
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
