import XCTest
@testable import UsageInk

final class QuotaFocusModelTests: XCTestCase {
    func testQuotaFirstHeroIsLongestWindowAndTieUsesLaterCanonicalSlot() {
        let both = DisplayFrameFixtures.typicalAccount()
        let selected = QuotaFocusModelBuilder.select(
            preferences: .default,
            account: both,
            local: DisplayFrameFixtures.typicalLocal()
        )
        guard case .quota(let hero) = selected.0 else {
            return XCTFail("expected quota hero")
        }
        XCTAssertEqual(hero.slot, .secondary)
        XCTAssertEqual(hero.windowDurationMins, 10_080)
        XCTAssertEqual(quotaSlots(selected.1), [.primary])

        let tied = AccountObservation(
            availability: .fresh,
            failure: nil,
            planType: "Plus",
            windows: [
                UsageWindowObservation(slot: .primary, usedPercent: 10, windowDurationMins: 60, resetsAt: 1),
                UsageWindowObservation(slot: .secondary, usedPercent: 20, windowDurationMins: 60, resetsAt: 2)
            ]
        )
        let tiedSelection = QuotaFocusModelBuilder.select(
            preferences: .default,
            account: tied,
            local: .unknown
        )
        guard case .quota(let tiedHero) = tiedSelection.0 else {
            return XCTFail("expected tied quota hero")
        }
        XCTAssertEqual(tiedHero.slot, .secondary)
    }

    func testMissingSecondaryWindowIsNotInvented() {
        let onlyPrimary = AccountObservation(
            availability: .fresh,
            failure: nil,
            planType: "Plus",
            windows: [
                UsageWindowObservation(slot: .primary, usedPercent: 12, windowDurationMins: 10_080, resetsAt: 99)
            ]
        )
        let selected = QuotaFocusModelBuilder.select(
            preferences: .default,
            account: onlyPrimary,
            local: DisplayFrameFixtures.typicalLocal()
        )
        guard case .quota(let hero) = selected.0 else {
            return XCTFail("expected returned window")
        }
        XCTAssertEqual(hero.slot, .primary)
        XCTAssertFalse(quotaSlots(selected.1).contains(.secondary))
        XCTAssertFalse(quotaSlots(selected.1).contains(.primary))
        let model = QuotaFocusModelBuilder.build(DisplayFrameFixtures.input(account: onlyPrimary))
        XCTAssertEqual(model.hero?.id, "quota.primary")
        XCTAssertFalse(model.ticker.contains { $0.id == "quota.secondary" })
    }

    func testActivityFirstHeroIsFirstEnabledLocalMetricWithQuotaFallback() {
        var preferences = DisplayPreferences.default
        preferences.quotaOrder = .activityFirst
        let selected = QuotaFocusModelBuilder.select(
            preferences: preferences,
            account: DisplayFrameFixtures.typicalAccount(),
            local: DisplayFrameFixtures.typicalLocal()
        )
        guard case .local(.today) = selected.0 else {
            return XCTFail("expected today hero")
        }
        guard case .local(.weekTokens) = selected.1.first else {
            return XCTFail("expected week ticker")
        }

        preferences.modules.today = false
        preferences.modules.weekTokens = false
        preferences.modules.cache = false
        preferences.modules.tps = false
        let fallback = QuotaFocusModelBuilder.select(
            preferences: preferences,
            account: DisplayFrameFixtures.typicalAccount(),
            local: DisplayFrameFixtures.typicalLocal()
        )
        guard case .quota(let hero) = fallback.0 else {
            return XCTFail("expected quota fallback")
        }
        XCTAssertEqual(hero.slot, .secondary)
    }

    func testUnavailableAndUnknownNeverBecomeZero() {
        let unknown = QuotaFocusModelBuilder.build(
            DisplayFrameFixtures.input(account: .unknown, local: .unknown)
        )
        XCTAssertEqual(unknown.hero?.displayedValue, DisplayCopy.emDash)
        XCTAssertNotEqual(unknown.hero?.displayedValue, "0")
        XCTAssertNotEqual(unknown.hero?.displayedValue, "0%")
        XCTAssertEqual(unknown.hero?.semanticValue, nil)

        let invalidPercent = AccountObservation(
            availability: .fresh,
            failure: nil,
            planType: "Plus",
            windows: [
                UsageWindowObservation(slot: .primary, usedPercent: .nan, windowDurationMins: 60, resetsAt: 1)
            ]
        )
        let model = QuotaFocusModelBuilder.build(DisplayFrameFixtures.input(account: invalidPercent, local: .unknown))
        XCTAssertEqual(model.hero?.displayedValue, DisplayCopy.emDash)
        XCTAssertNil(model.hero?.progressPercent)

        var staleAccount = DisplayFrameFixtures.typicalAccount()
        staleAccount.availability = .stale
        let stale = QuotaFocusModelBuilder.build(DisplayFrameFixtures.input(account: staleAccount, local: .unknown))
        XCTAssertEqual(stale.hero?.displayedValue, "81%")
        XCTAssertEqual(stale.hero?.badge, "Account data stale")
    }

    func testDisabledTitleUsesStructuralFallbackAndAllDisabledHasNoMetric() {
        var preferences = DisplayPreferences.default
        preferences.modules.title = false
        preferences.modules.quota = false
        preferences.modules.today = false
        preferences.modules.weekTokens = false
        preferences.modules.plan = false
        let model = QuotaFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, account: .unknown, local: .unknown)
        )
        XCTAssertEqual(model.title, "USAGE")
        XCTAssertNil(model.hero)
        XCTAssertEqual(model.unavailableMark, DisplayCopy.emDash)
        XCTAssertEqual(model.ticker, [])
    }

    func testIncompleteCacheCoverageDoesNotRenderZero() {
        var preferences = DisplayPreferences.default
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
        let model = QuotaFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, local: local)
        )
        let cache = model.ticker.first { $0.id == "local.cache" }
        XCTAssertEqual(cache?.displayedValue, DisplayCopy.emDash)
        XCTAssertEqual(cache?.coverageComplete, false)
    }

    private func quotaSlots(_ items: [QuotaFocusModelBuilder.Item]) -> [UsageWindowSlot] {
        items.compactMap { item in
            if case .quota(let window) = item {
                return window.slot
            }
            return nil
        }
    }
}
