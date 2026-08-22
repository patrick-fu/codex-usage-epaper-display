import CoreGraphics
import XCTest
@testable import UsageInk

final class DisplayFrameComposerTests: XCTestCase {
    func testDefaultQuotaFocusProducesFifteenThousandBytePlanes() throws {
        let frame = try DisplayFrameComposer.compose(DisplayFrameFixtures.input())
        XCTAssertEqual(frame.blackPlane.count, 15_000)
        XCTAssertEqual(frame.redPlane.count, 15_000)
        XCTAssertEqual(frame.fingerprint.count, 64)
    }

    func testBalancedAndActivityFocusComposeFifteenThousandBytePlanes() throws {
        for style in [DisplayStyle.balanced, .activityFocus] {
            var preferences = DisplayPreferences.default
            preferences.displayStyle = style
            let frame = try DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: preferences))
            XCTAssertEqual(frame.blackPlane.count, 15_000)
            XCTAssertEqual(frame.redPlane.count, 15_000)
            XCTAssertEqual(frame.fingerprint.count, 64)
        }
    }

    func testBalancedMarginsStayPaper() throws {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .balanced
        let frame = try DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: preferences))
        for x in 0..<16 {
            XCTAssertEqual(DisplayFrameFixtures.ink(atX: x, y: 150, frame: frame), .paper)
        }
        for x in 384..<400 {
            XCTAssertEqual(DisplayFrameFixtures.ink(atX: x, y: 150, frame: frame), .paper)
        }
        for y in 0..<11 {
            XCTAssertEqual(DisplayFrameFixtures.ink(atX: 200, y: y, frame: frame), .paper)
        }
        XCTAssertTrue(DisplayFrameFixtures.contains(.black, in: BalancedLayout.titleRect, frame: frame))
        XCTAssertTrue(DisplayFrameFixtures.contains(.black, in: BalancedLayout.bodyRect, frame: frame))
        XCTAssertTrue(DisplayFrameFixtures.contains(.black, in: BalancedLayout.footerRect, frame: frame))
    }

    func testActivityFocusRedAccentAppliesOnlyToQuotaCells() throws {
        var always = DisplayPreferences.default
        always.displayStyle = .activityFocus
        always.redAccent = .always
        let frame = try DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: always))
        let quota = ActivityFocusLayout.quotaRects(count: 2)[1]
        XCTAssertTrue(DisplayFrameFixtures.contains(.red, in: quota, frame: frame))
        let primary = ActivityFocusLayout.primaryRect(hasSecondary: true, hasQuotas: true)
        XCTAssertFalse(DisplayFrameFixtures.contains(.red, in: primary, frame: frame))
    }

    func testRedAccentAppliesOnlyToQuotaPercentageAndProgress() throws {
        var off = DisplayPreferences.default
        off.redAccent = .off
        let offFrame = try DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: off))
        XCTAssertFalse(
            DisplayFrameFixtures.contains(.red, in: QuotaFocusLayout.heroRect, frame: offFrame)
        )

        var always = DisplayPreferences.default
        always.redAccent = .always
        let alwaysFrame = try DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: always))
        XCTAssertTrue(
            DisplayFrameFixtures.contains(.red, in: QuotaFocusLayout.heroRect, frame: alwaysFrame)
        )

        var threshold = DisplayPreferences.default
        threshold.redAccent = .threshold
        threshold.redThreshold = 80
        let over = try DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: threshold))
        XCTAssertTrue(DisplayFrameFixtures.contains(.red, in: QuotaFocusLayout.heroRect, frame: over))

        var account = DisplayFrameFixtures.typicalAccount()
        account.windows[1].usedPercent = 20
        let under = try DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(preferences: threshold, account: account)
        )
        XCTAssertFalse(DisplayFrameFixtures.contains(.red, in: QuotaFocusLayout.heroRect, frame: under))
    }

    func testStaleTickerCellRendersValueAndBadge() throws {
        let frame = try DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(account: DisplayFrameFixtures.staleAccount())
        )
        let cells = QuotaFocusLayout.tickerCellRects(count: 3)
        XCTAssertEqual(cells.count, 3)
        let badgeRect = QuotaFocusLayout.tickerBadgeRect(in: cells[0])
        XCTAssertTrue(
            DisplayFrameFixtures.contains(.black, in: badgeRect, frame: frame),
            "stale ticker badge must paint ink"
        )
        XCTAssertTrue(
            DisplayFrameFixtures.contains(
                .black,
                in: QuotaFocusLayout.tickerValueRect(in: cells[0], hasBadge: true),
                frame: frame
            )
        )
        let paddingX = Int(cells[0].maxX) - 2
        let badgeY = Int(badgeRect.midY)
        XCTAssertEqual(
            DisplayFrameFixtures.ink(atX: paddingX, y: badgeY, frame: frame),
            .paper,
            "badge must clip to the ticker cell content rect"
        )
    }

    func testUnavailableTickerRendersEmDashAndCopy() throws {
        var preferences = DisplayPreferences.default
        preferences.modules.quota = false
        let frame = try DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(
                preferences: preferences,
                account: DisplayFrameFixtures.unavailableAccount(),
                local: DisplayFrameFixtures.unavailableLocal()
            )
        )
        XCTAssertTrue(
            DisplayFrameFixtures.contains(.black, in: QuotaFocusLayout.heroRect, frame: frame)
        )
        XCTAssertTrue(
            DisplayFrameFixtures.contains(.black, in: QuotaFocusLayout.heroBadgeRect, frame: frame)
        )
        XCTAssertFalse(
            DisplayFrameFixtures.contains(.red, in: QuotaFocusLayout.heroProgressTrackRect, frame: frame)
        )
        let model = QuotaFocusModelBuilder.build(
            DisplayFrameFixtures.input(
                preferences: preferences,
                account: DisplayFrameFixtures.unavailableAccount(),
                local: DisplayFrameFixtures.unavailableLocal()
            )
        )
        XCTAssertEqual(model.hero?.displayedValue, DisplayCopy.emDash)
        XCTAssertEqual(model.hero?.badge, "Local activity unknown")
    }

    func testMarginsStayPaperAndOverflowDoesNotCrash() throws {
        var preferences = DisplayPreferences.default
        preferences.title = String(repeating: "W", count: 24)
        var account = DisplayFrameFixtures.typicalAccount()
        account.planType = "PLUSPLUSPLUS"
        let frame = try DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(preferences: preferences, account: account)
        )
        for x in 0..<14 {
            XCTAssertEqual(DisplayFrameFixtures.ink(atX: x, y: 150, frame: frame), .paper)
        }
        for x in 386..<400 {
            XCTAssertEqual(DisplayFrameFixtures.ink(atX: x, y: 150, frame: frame), .paper)
        }
        for y in 0..<10 {
            XCTAssertEqual(DisplayFrameFixtures.ink(atX: 200, y: y, frame: frame), .paper)
        }
        XCTAssertTrue(
            DisplayFrameFixtures.contains(.black, in: QuotaFocusLayout.titleRect, frame: frame)
        )
        XCTAssertTrue(
            DisplayFrameFixtures.contains(.black, in: QuotaFocusLayout.footerRect, frame: frame)
        )
    }

    func testChineseCopyStillProducesInkWhenLanguageIsSimplifiedChinese() throws {
        var preferences = DisplayPreferences.default
        preferences.language = .simplifiedChinese
        let frame = try DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(preferences: preferences, preferredLanguages: ["zh-Hans"])
        )
        XCTAssertTrue(
            DisplayFrameFixtures.contains(.black, in: QuotaFocusLayout.heroRect, frame: frame)
        )
        XCTAssertTrue(
            DisplayFrameFixtures.contains(.black, in: QuotaFocusLayout.footerRect, frame: frame)
        )
    }

    func testComposeDoesNotWriteRenderArtifacts() throws {
        let tmp = FileManager.default.temporaryDirectory
        let marker = tmp.appendingPathComponent("usageink-issue-13-marker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: marker.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: marker) }
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
        for style in DisplayStyle.allCases {
            var preferences = DisplayPreferences.default
            preferences.displayStyle = style
            _ = try DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: preferences))
        }
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
        XCTAssertEqual(after, before)
    }

    func testChineseCopyProducesInkForEveryStyle() throws {
        for style in DisplayStyle.allCases {
            var preferences = DisplayPreferences.default
            preferences.displayStyle = style
            preferences.language = .simplifiedChinese
            let frame = try DisplayFrameComposer.compose(
                DisplayFrameFixtures.input(preferences: preferences, preferredLanguages: ["zh-Hans"])
            )
            let rect: CGRect
            switch style {
            case .balanced:
                rect = BalancedLayout.contentRect
            case .quotaFocus:
                rect = QuotaFocusLayout.contentRect
            case .activityFocus:
                rect = ActivityFocusLayout.contentRect
            }
            XCTAssertTrue(DisplayFrameFixtures.contains(.black, in: rect, frame: frame), style.rawValue)
        }
    }
}
