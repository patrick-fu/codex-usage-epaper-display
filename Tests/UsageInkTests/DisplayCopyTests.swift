import XCTest
@testable import UsageInk

final class DisplayCopyTests: XCTestCase {
    func testWindowLabelsPreferExactLargerUnits() {
        XCTAssertEqual(DisplayCopy.windowLabel(durationMinutes: 5, language: .english), "5 min")
        XCTAssertEqual(DisplayCopy.windowLabel(durationMinutes: 60, language: .english), "1 hr")
        XCTAssertEqual(DisplayCopy.windowLabel(durationMinutes: 90, language: .english), "90 min")
        XCTAssertEqual(DisplayCopy.windowLabel(durationMinutes: 1_440, language: .english), "1 d")
        XCTAssertEqual(DisplayCopy.windowLabel(durationMinutes: 300, language: .simplifiedChinese), "5 小时")
        XCTAssertEqual(DisplayCopy.windowLabel(durationMinutes: 10_080, language: .simplifiedChinese), "7 天")
    }

    func testPercentRoundingIsHalfAwayFromZeroAndRejectsInvalidValues() {
        XCTAssertEqual(DisplayCopy.formatPercent(42.4), 42)
        XCTAssertEqual(DisplayCopy.formatPercent(42.5), 43)
        XCTAssertEqual(DisplayCopy.formatPercent(0), 0)
        XCTAssertEqual(DisplayCopy.formatPercent(100), 100)
        XCTAssertNil(DisplayCopy.formatPercent(-0.1))
        XCTAssertNil(DisplayCopy.formatPercent(100.1))
        XCTAssertNil(DisplayCopy.formatPercent(.nan))
        XCTAssertNil(DisplayCopy.formatPercent(.infinity))
        XCTAssertEqual(DisplayCopy.formatPercent(81), 81)
    }

    func testTokenAndRateFormatting() {
        XCTAssertEqual(DisplayCopy.formatTokens(0), "0")
        XCTAssertEqual(DisplayCopy.formatTokens(999), "999")
        XCTAssertEqual(DisplayCopy.formatTokens(1_000), "1K")
        XCTAssertEqual(DisplayCopy.formatTokens(1_500), "1.5K")
        XCTAssertEqual(DisplayCopy.formatTokens(1_000_000), "1M")
        XCTAssertEqual(DisplayCopy.formatTokens(1_230_000), "1.23M")
        XCTAssertEqual(DisplayCopy.formatTokens(1_235_000), "1.24M")
        XCTAssertEqual(DisplayCopy.formatCacheRate(0.255), "26%")
        XCTAssertEqual(DisplayCopy.formatTPS(0), "0.0")
        XCTAssertEqual(DisplayCopy.formatTPS(1.25), "1.3")
        XCTAssertNil(DisplayCopy.formatTPS(-1))
    }

    func testDegradedCopyTableIsExact() {
        XCTAssertEqual(
            DisplayCopy.degradedMessage(availability: .authRequired, failure: nil, source: .account, language: .english),
            "Sign in to Codex"
        )
        XCTAssertEqual(
            DisplayCopy.degradedMessage(availability: .unavailable, failure: "rateLimitUnavailable", source: .account, language: .simplifiedChinese),
            "限额暂不可用"
        )
        XCTAssertEqual(
            DisplayCopy.degradedMessage(availability: .stale, failure: nil, source: .account, language: .english),
            "Account data stale"
        )
        XCTAssertEqual(
            DisplayCopy.degradedMessage(availability: .unknown, failure: nil, source: .local, language: .simplifiedChinese),
            "本机活动未知"
        )
        XCTAssertEqual(
            DisplayCopy.degradedMessage(availability: .unavailable, failure: "sourcePermissionDenied", source: .local, language: .english),
            "Local source unreadable"
        )
    }

    func testFooterUsesAbsoluteLocalTimeAndConnectedCopy() {
        let text = DisplayCopy.footerUpdated(
            composedAt: DisplayFrameFixtures.composedAt,
            calendar: DisplayFrameFixtures.calendar,
            timeZone: DisplayFrameFixtures.timeZone,
            language: .english
        )
        XCTAssertEqual(text, "Updated 08:00")
        XCTAssertEqual(DisplayCopy.footerStatus(language: .simplifiedChinese), "显示器已连接")
    }

    func testSystemLanguageResolvesOnceFromPreferredLanguages() {
        XCTAssertEqual(
            DisplayCopy.resolvedLanguage(preference: .system, preferredLanguages: ["zh-Hans-CN"]),
            .simplifiedChinese
        )
        XCTAssertEqual(
            DisplayCopy.resolvedLanguage(preference: .system, preferredLanguages: ["en-US"]),
            .english
        )
        XCTAssertEqual(
            DisplayCopy.resolvedLanguage(preference: .english, preferredLanguages: ["zh-Hans"]),
            .english
        )
    }
}
