import XCTest
@testable import UsageInk

final class ActivityFocusModelTests: XCTestCase {
    func testLocalsUsePriorityAndQuotasStayCanonicalAtBottom() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .activityFocus
        preferences.modules.cache = true
        preferences.modules.tps = true
        let model = ActivityFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences)
        )
        XCTAssertEqual(model.primary?.id, "local.today")
        XCTAssertEqual(model.secondary.map(\.id), [
            "local.weekTokens",
            "local.cache",
            "local.tps",
        ])
        XCTAssertEqual(model.quotas.map(\.id), ["quota.primary", "quota.secondary"])
        XCTAssertNil(model.unavailableMark)
    }

    func testQuotaOrderDoesNotMoveActivityFocusPlacement() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .activityFocus
        preferences.quotaOrder = .activityFirst
        let model = ActivityFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences)
        )
        XCTAssertEqual(model.primary?.id, "local.today")
        XCTAssertEqual(model.secondary.map(\.id), ["local.weekTokens"])
        XCTAssertEqual(model.quotas.map(\.id), ["quota.primary", "quota.secondary"])
    }

    func testMissingAndZeroWindowsAreNotInvented() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .activityFocus
        let onlyPrimary = AccountObservation(
            availability: .fresh,
            failure: nil,
            planType: "Plus",
            windows: [
                UsageWindowObservation(slot: .primary, usedPercent: 12, windowDurationMins: 10_080, resetsAt: 99)
            ]
        )
        let one = ActivityFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, account: onlyPrimary)
        )
        XCTAssertEqual(one.quotas.map(\.id), ["quota.primary"])

        let zero = ActivityFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, account: .unknown)
        )
        XCTAssertEqual(zero.quotas, [])
        XCTAssertEqual(zero.primary?.id, "local.today")
    }

    func testDisabledTitleUsesStructuralFallbackAndAllDisabledHasNoMetric() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .activityFocus
        preferences.modules.title = false
        preferences.modules.quota = false
        preferences.modules.today = false
        preferences.modules.weekTokens = false
        preferences.modules.plan = false
        let model = ActivityFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, account: .unknown, local: .unknown)
        )
        XCTAssertEqual(model.title, "USAGE")
        XCTAssertNil(model.primary)
        XCTAssertEqual(model.secondary, [])
        XCTAssertEqual(model.quotas, [])
        XCTAssertEqual(model.unavailableMark, DisplayCopy.emDash)
    }

    func testUnavailableUnknownAndInvalidPercentNeverBecomeZero() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .activityFocus
        let unknown = ActivityFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, account: .unknown, local: .unknown)
        )
        XCTAssertEqual(unknown.primary?.displayedValue, DisplayCopy.emDash)
        XCTAssertNil(unknown.primary?.semanticValue)
        XCTAssertNotEqual(unknown.primary?.displayedValue, "0")

        let invalidPercent = AccountObservation(
            availability: .fresh,
            failure: nil,
            planType: "Plus",
            windows: [
                UsageWindowObservation(slot: .primary, usedPercent: .nan, windowDurationMins: 60, resetsAt: 1)
            ]
        )
        let invalid = ActivityFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, account: invalidPercent, local: .unknown)
        )
        XCTAssertEqual(invalid.quotas[0].displayedValue, DisplayCopy.emDash)
        XCTAssertNil(invalid.quotas[0].progressPercent)

        var staleAccount = DisplayFrameFixtures.typicalAccount()
        staleAccount.availability = .stale
        let stale = ActivityFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, account: staleAccount, local: .unknown)
        )
        XCTAssertEqual(stale.quotas[0].displayedValue, "42%")
        XCTAssertEqual(stale.quotas[0].badge, "Account data stale")
        XCTAssertEqual(stale.quotas[1].displayedValue, "81%")
    }

    func testIncompleteCacheCoverageDoesNotRenderZero() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .activityFocus
        preferences.modules.today = false
        preferences.modules.weekTokens = false
        preferences.modules.cache = true
        let local = LocalActivityObservation(
            availability: .fresh,
            failure: nil,
            todayTokens: 10,
            weekTokens: 10,
            cacheHitRate: 0,
            tps: 0,
            coverageComplete: false
        )
        let model = ActivityFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, local: local)
        )
        XCTAssertEqual(model.primary?.id, "local.cache")
        XCTAssertEqual(model.primary?.displayedValue, DisplayCopy.emDash)
        XCTAssertEqual(model.primary?.coverageComplete, false)
    }

    func testSecondaryLocalsCapAtThree() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .activityFocus
        preferences.modules.cache = true
        preferences.modules.tps = true
        let model = ActivityFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences)
        )
        XCTAssertEqual(model.secondary.count, 3)
        XCTAssertEqual(model.secondary.last?.id, "local.tps")
    }

    func testDisabledLocalsKeepQuotasWithoutUnavailableMark() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .activityFocus
        preferences.modules.today = false
        preferences.modules.weekTokens = false
        preferences.modules.cache = false
        preferences.modules.tps = false
        let model = ActivityFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences)
        )
        XCTAssertNil(model.primary)
        XCTAssertEqual(model.secondary, [])
        XCTAssertEqual(model.quotas.map(\.id), ["quota.primary", "quota.secondary"])
        XCTAssertNil(model.unavailableMark)
    }
}
