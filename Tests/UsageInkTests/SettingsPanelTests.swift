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
}
