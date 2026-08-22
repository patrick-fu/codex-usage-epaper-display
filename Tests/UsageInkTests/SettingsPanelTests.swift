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
        XCTAssertNotEqual(
            try XCTUnwrap(delegate.runtime).persistenceRoot.resolvingSymlinksInPath(),
            PersistenceLocation.productionRoot().resolvingSymlinksInPath()
        )
        XCTAssertEqual(
            delegate.settingsPanelController.panelCount,
            NSApp.windows.filter { $0.identifier == SettingsPanelController.windowIdentifier }.count
        )
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
        XCTAssertTrue(NSApp.windows.contains { $0 === panel.hostedPanel })

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
        let title = panel.view(withIdentifier: "settings.title") as? NSTextField
        title?.stringValue = "CODEX DESK"
        (panel.view(withIdentifier: "settings.save") as? NSButton)?.performClick(nil)
        guard case .savePreferences(let preferences) = box.command else {
            return XCTFail("expected savePreferences batch")
        }
        XCTAssertEqual(preferences.displayStyle, .balanced)
        XCTAssertEqual(try preferences.validated().title, "CODEX DESK")
        XCTAssertFalse(preferences.modules.cache)
        XCTAssertFalse(preferences.modules.tps)
        XCTAssertEqual(preferences.tpsWindowMinutes, 15)
    }

    func testSavePersistsCacheTPSModulesAndLookback() {
        let panel = SettingsPanelController()
        let box = CommandBox()
        panel.submit = { command in
            box.command = command
        }
        panel.apply(
            RuntimeSnapshot(
                statusSummary: "—",
                binding: .unbound,
                displayStyle: .quotaFocus,
                hasReadyWakeupConfiguration: false,
                showsFirstRunDisclosure: false
            )
        )
        let cache = panel.view(withIdentifier: "settings.modules.cache") as? NSButton
        let tps = panel.view(withIdentifier: "settings.modules.tps") as? NSButton
        let lookback = panel.view(withIdentifier: "settings.tpsWindowMinutes") as? NSPopUpButton
        XCTAssertEqual(cache?.state, .off)
        XCTAssertEqual(tps?.state, .off)
        XCTAssertEqual(lookback?.titleOfSelectedItem, "15")
        cache?.state = .on
        tps?.state = .on
        _ = cache?.sendAction(cache?.action, to: cache?.target)
        _ = tps?.sendAction(tps?.action, to: tps?.target)
        lookback?.selectItem(withTitle: "3")
        _ = lookback?.sendAction(lookback?.action, to: lookback?.target)
        (panel.view(withIdentifier: "settings.save") as? NSButton)?.performClick(nil)
        guard case .savePreferences(let preferences) = box.command else {
            return XCTFail("expected savePreferences batch")
        }
        XCTAssertTrue(preferences.modules.cache)
        XCTAssertTrue(preferences.modules.tps)
        XCTAssertEqual(preferences.tpsWindowMinutes, 3)
        XCTAssertTrue(DisplayPreferences.default.modules.cache == false)
        XCTAssertTrue(DisplayPreferences.default.modules.tps == false)
        XCTAssertEqual(DisplayPreferences.default.tpsWindowMinutes, 15)
    }

    func testCorruptAndUnsupportedSnapshotsShowBilingualResetGuidance() {
        let panel = SettingsPanelController()
        let corrupt = RuntimeSnapshot(
            statusSummary: "—",
            binding: .unbound,
            displayStyle: .quotaFocus,
            hasReadyWakeupConfiguration: false,
            showsFirstRunDisclosure: false,
            shouldPresentSettingsOnLaunch: true,
            storageClassification: .stateCorrupt,
            isPersistenceWritable: true
        )
        panel.apply(corrupt)
        XCTAssertTrue(panel.isStorageStatusVisible)
        XCTAssertTrue(panel.storageStatusText.contains("Reset UsageInk Data"))
        XCTAssertTrue(panel.storageStatusText.contains("重置 UsageInk 数据"))
        XCTAssertFalse(panel.isDisclosureVisible)
        XCTAssertTrue((panel.view(withIdentifier: "settings.save") as? NSButton)?.isEnabled ?? false)

        var unsupported = corrupt
        unsupported.storageClassification = .stateVersionUnsupported
        unsupported.isPersistenceWritable = false
        panel.apply(unsupported)
        XCTAssertTrue(panel.isStorageStatusVisible)
        XCTAssertTrue(panel.storageStatusText.contains("read-only"))
        XCTAssertTrue(panel.storageStatusText.contains("只读"))
        XCTAssertTrue(panel.storageStatusText.contains("Reset UsageInk Data"))
        XCTAssertTrue(panel.storageStatusText.contains("不会覆盖"))
        XCTAssertFalse((panel.view(withIdentifier: "settings.save") as? NSButton)?.isEnabled ?? true)
        XCTAssertTrue(NSApp.windows.contains { $0 === panel.hostedPanel })
        XCTAssertEqual(
            panel.panelCount,
            NSApp.windows.filter { $0.identifier == SettingsPanelController.windowIdentifier }.count
        )
    }

    func testDirtyDraftSurvivesMenuStyleSnapshotAndInvalidSaveShowsBilingualError() {
        let panel = SettingsPanelController()
        let snapshot = RuntimeSnapshot(
            statusSummary: "—",
            binding: .unbound,
            displayStyle: .quotaFocus,
            hasReadyWakeupConfiguration: false,
            showsFirstRunDisclosure: true
        )
        panel.apply(snapshot)
        let title = panel.view(withIdentifier: "settings.title") as? NSTextField
        title?.stringValue = "DIRTY TITLE"
        _ = title?.sendAction(title?.action, to: title?.target)

        var styleSnapshot = snapshot
        styleSnapshot.showsFirstRunDisclosure = false
        styleSnapshot.preferences.displayStyle = .balanced
        styleSnapshot.displayStyle = .balanced
        panel.apply(styleSnapshot)
        XCTAssertEqual(panel.currentDraftTitle, "DIRTY TITLE")
        XCTAssertEqual((panel.view(withIdentifier: "settings.displayStyle") as? NSPopUpButton)?.indexOfSelectedItem, 0)

        let threshold = panel.view(withIdentifier: "settings.redThreshold") as? NSTextField
        threshold?.stringValue = "81"
        _ = threshold?.sendAction(threshold?.action, to: threshold?.target)
        (panel.view(withIdentifier: "settings.save") as? NSButton)?.performClick(nil)
        XCTAssertTrue(panel.isValidationErrorVisible)
        XCTAssertTrue(panel.validationErrorText.contains("could not be saved"))
        XCTAssertTrue(panel.validationErrorText.contains("无法保存"))
    }
}

private final class CommandBox: @unchecked Sendable {
    var command: RuntimeCommand?
}
