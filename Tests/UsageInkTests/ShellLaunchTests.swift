import AppKit
import XCTest
@testable import UsageInk

@MainActor
final class ShellLaunchTests: XCTestCase {
    func testLaunchUsesAccessoryPolicyWithoutAMainWindow() throws {
        _ = try AppLaunchSupport.bootstrapShell()
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        let titledWindows = NSApp.windows.filter { window in
            window.isVisible && window.styleMask.contains(.titled)
        }
        XCTAssertEqual(titledWindows, [], "shell launch must not present a main window")
    }

    func testStatusItemExposesSpecifiedUnboundMenuSkeleton() throws {
        let delegate = try AppLaunchSupport.bootstrapShell()
        let controller = try XCTUnwrap(delegate.statusItemController)
        let menu = try XCTUnwrap(controller.menu)
        waitForMenu(menu)

        let summary = StatusSummaryFormatter(language: .resolveSystem()).summary(
            account: .unknown,
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
