import XCTest
@testable import UsageInk

final class FrameFingerprintTests: XCTestCase {
    func testFingerprintIsLowercaseHexSHA256() {
        let fingerprint = DisplayFrameComposer.compose(DisplayFrameFixtures.input()).fingerprint
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertTrue(fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testElapsedTimeAloneDoesNotChangeFingerprint() {
        let first = DisplayFrameComposer.compose(DisplayFrameFixtures.input()).fingerprint
        let later = DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(composedAt: DisplayFrameFixtures.composedAt.addingTimeInterval(3_600))
        ).fingerprint
        XCTAssertEqual(first, later)
    }

    func testRelativeCountdownChangeIsExcludedWhileAbsoluteResetIsIncluded() {
        let base = DisplayFrameFixtures.typicalAccount()
        let first = DisplayFrameComposer.compose(DisplayFrameFixtures.input(account: base)).fingerprint
        var shiftedReset = base
        shiftedReset.windows[1].resetsAt = (base.windows[1].resetsAt ?? 0) + 60
        let changedReset = DisplayFrameComposer.compose(DisplayFrameFixtures.input(account: shiftedReset)).fingerprint
        XCTAssertNotEqual(first, changedReset)
    }

    func testFingerprintChangesWithVisibleSemantics() {
        let base = DisplayFrameComposer.compose(DisplayFrameFixtures.input()).fingerprint

        var zh = DisplayPreferences.default
        zh.language = .simplifiedChinese
        XCTAssertNotEqual(base, DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: zh)).fingerprint)

        var activityFirst = DisplayPreferences.default
        activityFirst.quotaOrder = .activityFirst
        XCTAssertNotEqual(base, DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: activityFirst)).fingerprint)

        var account = DisplayFrameFixtures.typicalAccount()
        account.windows[1].usedPercent = 90
        XCTAssertNotEqual(base, DisplayFrameComposer.compose(DisplayFrameFixtures.input(account: account)).fingerprint)

        account = DisplayFrameFixtures.typicalAccount()
        account.availability = .stale
        XCTAssertNotEqual(base, DisplayFrameComposer.compose(DisplayFrameFixtures.input(account: account)).fingerprint)

        var titled = DisplayPreferences.default
        titled.title = "USAGEINK"
        XCTAssertNotEqual(base, DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: titled)).fingerprint)

        var red = DisplayPreferences.default
        red.redThreshold = 50
        XCTAssertNotEqual(base, DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: red)).fingerprint)

        var tpsOn = DisplayPreferences.default
        tpsOn.modules.tps = true
        tpsOn.tpsWindowMinutes = 3
        XCTAssertNotEqual(base, DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: tpsOn)).fingerprint)
    }

    func testFooterModuleFlagsAreVisiblePreferencesButClockTextIsNotHashed() {
        var noFooter = DisplayPreferences.default
        noFooter.modules.updated = false
        noFooter.modules.status = false
        let withFooter = DisplayFrameComposer.compose(DisplayFrameFixtures.input()).fingerprint
        let withoutFooter = DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: noFooter)).fingerprint
        XCTAssertNotEqual(withFooter, withoutFooter)
    }
}
