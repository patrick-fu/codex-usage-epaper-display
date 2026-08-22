import AppKit
import XCTest
@testable import UsageInk

@MainActor
final class ShellLaunchTests: XCTestCase {
    func testLaunchUsesAccessoryPolicyWithoutAMainWindow() throws {
        let delegate = try AppLaunchSupport.bootstrapShell()
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        let controller = try XCTUnwrap(delegate.statusItemController)
        let menu = try XCTUnwrap(controller.menu)
        waitForMenu(menu)
        let titledWindows = NSApp.windows.filter { window in
            window.isVisible && window.styleMask.contains(.titled)
        }
        XCTAssertLessThanOrEqual(titledWindows.count, 1)
        for window in titledWindows {
            XCTAssertTrue(window is NSPanel)
            XCTAssertEqual(window.identifier, SettingsPanelController.windowIdentifier)
        }
    }

    func testStatusItemExposesSpecifiedUnboundMenuSkeleton() throws {
        let delegate = try AppLaunchSupport.bootstrapShell()
        let controller = try XCTUnwrap(delegate.statusItemController)
        let menu = try XCTUnwrap(controller.menu)
        waitForMenu(menu)

        let summary = StatusSummaryFormatter(language: .resolveSystem()).summary(
            account: SourceAvailability.unknown,
            local: .unknown,
            displayUnavailable: false
        )
        XCTAssertEqual(menu.items.map(\.title), [
            summary,
            "Refresh Now",
            "Find and Bind Display…",
            "Display Style",
            "Settings…",
            "Rebuild Local Metrics…",
            "Reset UsageInk Data…",
            "About UsageInk",
            "Quit UsageInk",
        ])
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertEqual(
            menu.item(withTitle: "Display Style")?.submenu?.items.map(\.title),
            ["Balanced", "Quota Focus", "Activity Focus"]
        )
        XCTAssertEqual(menu.item(withTitle: "Display Style")?.submenu?.items[1].state, .on)
        XCTAssertNil(menu.item(withTitle: "Configure Wakeup Pin…"))
    }

    private func waitForMenu(_ menu: NSMenu) {
        let populated = expectation(description: "status menu populated")
        func poll() {
            if menu.items.count >= 9 {
                populated.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
        }
        poll()
        wait(for: [populated], timeout: 1.0)
    }
}
