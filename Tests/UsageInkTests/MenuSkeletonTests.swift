import XCTest
@testable import UsageInk

final class MenuSkeletonTests: XCTestCase {
    func testUnboundMenuFollowsSpecifiedOrderWithoutWakeupItem() {
        let snapshot = RuntimeSnapshot(
            statusSummary: "— · Local activity unknown",
            binding: .unbound,
            displayStyle: .quotaFocus,
            hasReadyWakeupConfiguration: false
        )

        let titles = MenuBuilder.items(from: snapshot).map(\.title)
        XCTAssertEqual(titles, [
            "— · Local activity unknown",
            "Refresh Now",
            "Find and Bind Display…",
            "Display Style",
            "Settings…",
            "Rebuild Local Metrics…",
            "Reset UsageInk Data…",
            "About UsageInk",
            "Quit UsageInk",
        ])
    }

    func testBoundMenuReplacesFindWithUnbindAndKeepsRemainingOrder() {
        let snapshot = RuntimeSnapshot(
            statusSummary: "— · Local activity unknown",
            binding: .bound,
            displayStyle: .quotaFocus,
            hasReadyWakeupConfiguration: false
        )

        let titles = MenuBuilder.items(from: snapshot).map(\.title)
        XCTAssertEqual(titles, [
            "— · Local activity unknown",
            "Refresh Now",
            "Unbind Display…",
            "Display Style",
            "Settings…",
            "Rebuild Local Metrics…",
            "Reset UsageInk Data…",
            "About UsageInk",
            "Quit UsageInk",
        ])
    }

    func testWakeupItemAppearsOnlyWithReadyConfigurationAndStaysInSpecifiedSlot() {
        let snapshot = RuntimeSnapshot(
            statusSummary: "— · Local activity unknown",
            binding: .bound,
            displayStyle: .quotaFocus,
            hasReadyWakeupConfiguration: true
        )

        let titles = MenuBuilder.items(from: snapshot).map(\.title)
        XCTAssertEqual(titles, [
            "— · Local activity unknown",
            "Refresh Now",
            "Unbind Display…",
            "Display Style",
            "Settings…",
            "Configure Wakeup Pin…",
            "Rebuild Local Metrics…",
            "Reset UsageInk Data…",
            "About UsageInk",
            "Quit UsageInk",
        ])
    }

    func testDisplayStyleSubmenuUsesExactTitlesAndChecksQuotaFocusByDefault() {
        let snapshot = RuntimeSnapshot(
            statusSummary: "— · Local activity unknown",
            binding: .unbound,
            displayStyle: .quotaFocus,
            hasReadyWakeupConfiguration: false
        )
        let style = MenuBuilder.items(from: snapshot).first { $0.identity == .displayStyle }
        XCTAssertEqual(style?.children.map(\.title), [
            "Balanced",
            "Quota Focus",
            "Activity Focus",
        ])
        XCTAssertEqual(style?.children.map(\.isChecked), [false, true, false])
    }

    func testStatusSummaryItemIsNotEnabled() {
        let snapshot = RuntimeSnapshot(
            statusSummary: "— · Local activity unknown",
            binding: .unbound,
            displayStyle: .quotaFocus,
            hasReadyWakeupConfiguration: false
        )
        let status = MenuBuilder.items(from: snapshot)[0]
        XCTAssertEqual(status.identity, .statusSummary)
        XCTAssertFalse(status.isEnabled)
    }

    func testEnglishUnknownSourcesUseSpecCopy() {
        let text = StatusSummaryFormatter(language: .english).summary(
            account: SourceAvailability.unknown,
            local: .unknown,
            displayUnavailable: false
        )
        XCTAssertEqual(text, "— · Local activity unknown")
    }

    func testSimplifiedChineseUnknownSourcesUseSpecCopy() {
        let text = StatusSummaryFormatter(language: .simplifiedChinese).summary(
            account: SourceAvailability.unknown,
            local: .unknown,
            displayUnavailable: true
        )
        XCTAssertEqual(text, "— · 本机活动未知 · 显示器不可用")
    }
}
