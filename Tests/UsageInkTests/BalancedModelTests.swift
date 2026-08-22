import XCTest
@testable import UsageInk

final class BalancedModelTests: XCTestCase {
    func testQuotaFirstPutsCanonicalWindowsBeforeLocalsAndCapsAtSix() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .balanced
        preferences.modules.cache = true
        preferences.modules.tps = true
        let items = BalancedModelBuilder.select(
            preferences: preferences,
            account: DisplayFrameFixtures.typicalAccount()
        )
        XCTAssertEqual(items.compactMap(quotaSlot), [.primary, .secondary])
        XCTAssertEqual(items.compactMap(localKind), [.today, .weekTokens, .cache, .tps])
        XCTAssertEqual(items.count, 6)

        let onlyPrimary = AccountObservation(
            availability: .fresh,
            failure: nil,
            planType: "Plus",
            windows: [
                UsageWindowObservation(slot: .primary, usedPercent: 12, windowDurationMins: 300, resetsAt: 99)
            ]
        )
        let selected = BalancedModelBuilder.select(preferences: preferences, account: onlyPrimary)
        XCTAssertEqual(selected.compactMap(quotaSlot), [.primary])
        XCTAssertFalse(selected.compactMap(quotaSlot).contains(.secondary))
    }

    func testActivityFirstPutsLocalsBeforeQuotas() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .balanced
        preferences.quotaOrder = .activityFirst
        let items = BalancedModelBuilder.select(
            preferences: preferences,
            account: DisplayFrameFixtures.typicalAccount()
        )
        XCTAssertEqual(items.compactMap(localKind).first, .today)
        XCTAssertEqual(items.compactMap(quotaSlot), [.primary, .secondary])
        XCTAssertEqual(items.prefix(2).compactMap(localKind), [.today, .weekTokens])
    }

    func testDisabledTitleUsesStructuralFallbackAndAllDisabledHasNoMetric() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .balanced
        preferences.modules.title = false
        preferences.modules.quota = false
        preferences.modules.today = false
        preferences.modules.weekTokens = false
        preferences.modules.plan = false
        let model = BalancedModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, account: .unknown, local: .unknown)
        )
        XCTAssertEqual(model.title, "USAGE")
        XCTAssertEqual(model.entries, [])
        XCTAssertEqual(model.unavailableMark, DisplayCopy.emDash)
    }

    func testCacheAndTPSRenderZeroOnlyWhenAvailable() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .balanced
        preferences.modules.cache = true
        preferences.modules.tps = true
        let complete = LocalActivityObservation(
            availability: .fresh,
            failure: nil,
            todayTokens: 0,
            weekTokens: 0,
            cacheHitRate: 0,
            tps: 0,
            coverageComplete: true
        )
        let zero = BalancedModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, local: complete)
        )
        XCTAssertEqual(zero.entries.first { $0.id == "local.cache" }?.displayedValue, "0%")
        XCTAssertEqual(zero.entries.first { $0.id == "local.tps" }?.displayedValue, "0.0")

        let missing = BalancedModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, local: .unknown)
        )
        XCTAssertEqual(missing.entries.first { $0.id == "local.cache" }?.displayedValue, DisplayCopy.emDash)
        XCTAssertEqual(missing.entries.first { $0.id == "local.tps" }?.displayedValue, DisplayCopy.emDash)
        XCTAssertNotEqual(missing.entries.first { $0.id == "local.tps" }?.displayedValue, "0.0")
    }

    func testUnavailableValuesNeverBecomeZero() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .balanced
        let model = BalancedModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, account: .unknown, local: .unknown)
        )
        XCTAssertEqual(model.entries.first?.displayedValue, DisplayCopy.emDash)
        XCTAssertNotEqual(model.entries.first?.displayedValue, "0")
        XCTAssertNil(model.entries.first?.semanticValue)
    }

    private func quotaSlot(_ item: DisplayItem) -> UsageWindowSlot? {
        if case .quota(let window) = item { return window.slot }
        return nil
    }

    private func localKind(_ item: DisplayItem) -> LocalMetricKind? {
        if case .local(let kind) = item { return kind }
        return nil
    }
}
