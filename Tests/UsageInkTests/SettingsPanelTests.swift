import AppKit
import XCTest
@testable import UsageInk

@MainActor
final class SettingsPanelTests: XCTestCase {
    func testOpeningSettingsTwiceReusesASinglePanel() throws {
        let delegate = try AppLaunchSupport.bootstrapShell()
        let controller = try XCTUnwrap(delegate.statusItemController)
        controller.openSettings()
        controller.openSettings()

        XCTAssertTrue(controller.isSettingsVisible)
        XCTAssertEqual(delegate.settingsPanelController.panelCount, 1)
        let settingsWindows = NSApp.windows.filter { window in
            window.identifier == SettingsPanelController.windowIdentifier && window.isVisible
        }
        XCTAssertEqual(settingsWindows.count, 1)
        XCTAssertTrue(settingsWindows[0] is NSPanel)
        settingsWindows[0].orderOut(nil)
    }

    func testPanelExposesSpecifiedPreferenceFields() {
        let panel = SettingsPanelController()
        for identifier in SettingsPanelController.preferenceIdentifiers {
            XCTAssertNotNil(panel.view(withIdentifier: identifier), identifier)
        }
        XCTAssertNil(panel.view(withIdentifier: "settings.bind"))
        XCTAssertNil(panel.view(withIdentifier: "settings.wakeup"))
        XCTAssertNil(panel.view(withIdentifier: "settings.reset"))
    }

    func testFirstRunSnapshotShowsBilingualDisclosureInTheSamePanel() {
        let panel = SettingsPanelController()
        var snapshot = RuntimeSnapshot(
            statusSummary: "— · Local activity unknown",
            binding: .unbound,
            displayStyle: .quotaFocus,
            hasReadyWakeupConfiguration: false,
            showsFirstRunDisclosure: true
        )
        panel.apply(snapshot)
        XCTAssertTrue(panel.isDisclosureVisible)
        XCTAssertTrue(panel.disclosureText.contains("state.json"))
        XCTAssertTrue(panel.disclosureText.contains("activity.sqlite"))
        XCTAssertTrue(panel.disclosureText.contains("${CODEX_HOME:-~/.codex}/sessions"))
        XCTAssertTrue(panel.disclosureText.contains("archived_sessions"))
        XCTAssertTrue(panel.disclosureText.contains("token_count"))
        XCTAssertTrue(panel.disclosureText.contains("authentication"))
        XCTAssertTrue(panel.disclosureText.contains("telemetry"))
        XCTAssertTrue(panel.disclosureText.contains("Bound Display"))
        XCTAssertTrue(panel.disclosureText.contains("Time Machine"))
        XCTAssertTrue(panel.disclosureText.contains("OpenAI"))
        XCTAssertTrue(panel.disclosureText.contains("state.json"))
        XCTAssertTrue(panel.disclosureText.contains("本机"))
        XCTAssertTrue(panel.disclosureText.contains("认证"))
        XCTAssertTrue(panel.disclosureText.contains("遥测"))
        XCTAssertTrue(panel.disclosureText.contains("时间机器"))
        XCTAssertTrue(panel.disclosureText.contains("OpenAI"))
        XCTAssertEqual(panel.panelCount, 1)

        snapshot.showsFirstRunDisclosure = false
        panel.apply(snapshot)
        XCTAssertFalse(panel.isDisclosureVisible)
    }

    func testSaveSubmitsASinglePreferenceBatch() {
        let panel = SettingsPanelController()
        let box = CommandBox()
        panel.submit = { command in
            box.command = command
        }
        let snapshot = RuntimeSnapshot(
            statusSummary: "—",
            binding: .unbound,
            displayStyle: .quotaFocus,
            hasReadyWakeupConfiguration: false,
            showsFirstRunDisclosure: true
        )
        panel.apply(snapshot)
        let style = panel.view(withIdentifier: "settings.displayStyle") as? NSPopUpButton
        style?.selectItem(at: 0)
        style?.performClick(nil)
        let title = panel.view(withIdentifier: "settings.title") as? NSTextField
        title?.stringValue = "CODEX DESK"
        (panel.view(withIdentifier: "settings.save") as? NSButton)?.performClick(nil)
        guard case .savePreferences(let preferences) = box.command else {
            return XCTFail("expected savePreferences batch")
        }
        XCTAssertEqual(preferences.displayStyle, .balanced)
        XCTAssertEqual(try preferences.validated().title, "CODEX DESK")
    }
}

private final class CommandBox: @unchecked Sendable {
    var command: RuntimeCommand?
}
