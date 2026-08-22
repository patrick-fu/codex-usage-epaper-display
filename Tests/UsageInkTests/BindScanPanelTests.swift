import AppKit
import XCTest
@testable import UsageInk

@MainActor
final class BindScanPanelTests: XCTestCase {
    func testPanelListsAdvertisedNameRSSIAndShortIdentifier() {
        let panel = BindScanPanelController()
        let identifier = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        var snapshot = RuntimeSnapshot(
            statusSummary: "— · Local activity unknown",
            binding: .unbound,
            displayStyle: .quotaFocus,
            hasReadyWakeupConfiguration: false,
            bleLink: .scanning,
            bindCandidates: [
                BindCandidate(identifier: identifier, advertisedName: "UsageInk-Desk", rssi: -38)
            ]
        )
        panel.apply(snapshot)

        XCTAssertEqual(
            (panel.view(withIdentifier: BindScanPanelController.statusIdentifier) as? NSTextField)?.stringValue,
            "Scanning for display"
        )
        let button = panel.view(withIdentifier: "bind.candidate.\(identifier.uuidString)") as? NSButton
        XCTAssertEqual(button?.title, "UsageInk-Desk · -38 · 6E5F")
        XCTAssertNil(panel.view(withIdentifier: "settings.bind"))
    }

    func testSelectingACandidateSubmitsBindCommand() {
        let panel = BindScanPanelController()
        let identifier = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        let box = CommandBox()
        panel.submit = { box.command = $0 }
        panel.apply(
            RuntimeSnapshot(
                statusSummary: "— · Local activity unknown",
                binding: .unbound,
                displayStyle: .quotaFocus,
                hasReadyWakeupConfiguration: false,
                bleLink: .unbound,
                bindCandidates: [
                    BindCandidate(identifier: identifier, advertisedName: "UsageInk-Desk", rssi: -38)
                ]
            )
        )
        let button = panel.view(withIdentifier: "bind.candidate.\(identifier.uuidString)") as? NSButton
        button?.performClick(nil)
        XCTAssertEqual(box.command, .bindDisplay(identifier))
    }

    func testBindScanIsASettingsSheetAndDismissesWhenBound() throws {
        let delegate = try AppLaunchSupport.bootstrapShell()
        let controller = try XCTUnwrap(delegate.statusItemController)
        let settings = try XCTUnwrap(delegate.settingsPanelController)
        settings.presentBindScan(controller.bindScanPanel)
        XCTAssertEqual(settings.hostedPanel.attachedSheet, controller.bindScanPanel.hostedPanel)
        XCTAssertEqual(
            NSApp.windows.filter { $0.identifier == SettingsPanelController.windowIdentifier }.count,
            1
        )
        controller.apply(
            RuntimeSnapshot(
                statusSummary: "— · Local activity unknown",
                binding: .bound,
                displayStyle: .quotaFocus,
                hasReadyWakeupConfiguration: true
            )
        )
        XCTAssertNil(settings.hostedPanel.attachedSheet)
        XCTAssertFalse(controller.bindScanPanel.isVisible)
    }
}

private final class CommandBox: @unchecked Sendable {
    var command: RuntimeCommand?
}
