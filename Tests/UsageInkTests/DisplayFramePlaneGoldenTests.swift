import CoreGraphics
import XCTest
@testable import UsageInk

final class DisplayFramePlaneGoldenTests: XCTestCase {
    func testValidFixturePlaneDigestAndStructuralPixels() throws {
        let frame = try DisplayFrameComposer.compose(DisplayFrameFixtures.input())
        assertPlaneShape(frame)
        assertTitleAndTickerRules(frame)
        assertHeroProgress(frame, percent: 81, fill: .red)
        XCTAssertTrue(
            DisplayFrameFixtures.contains(.red, in: QuotaFocusLayout.heroRect, frame: frame)
        )
        assertDigest(frame, black: DisplayFramePlaneGoldens.validBlackSHA256, red: DisplayFramePlaneGoldens.validRedSHA256, label: "valid")
    }

    func testStaleFixturePlaneDigestKeepsValuesAndPaintsBadges() throws {
        let frame = try DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(account: DisplayFrameFixtures.staleAccount())
        )
        assertPlaneShape(frame)
        assertTitleAndTickerRules(frame)
        assertHeroProgress(frame, percent: 81, fill: .red)
        XCTAssertTrue(
            DisplayFrameFixtures.contains(.black, in: QuotaFocusLayout.heroBadgeRect, frame: frame)
        )
        let ticker = QuotaFocusLayout.tickerCellRects(count: 3)[0]
        XCTAssertTrue(
            DisplayFrameFixtures.contains(
                .black,
                in: QuotaFocusLayout.tickerBadgeRect(in: ticker),
                frame: frame
            )
        )
        XCTAssertEqual(
            DisplayFrameFixtures.ink(atX: Int(ticker.maxX) - 2, y: Int(QuotaFocusLayout.tickerBadgeRect(in: ticker).midY), frame: frame),
            .paper
        )
        assertDigest(frame, black: DisplayFramePlaneGoldens.staleBlackSHA256, red: DisplayFramePlaneGoldens.staleRedSHA256, label: "stale")
    }

    func testBalancedTypicalFixturePlaneDigestAndMargins() throws {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .balanced
        let frame = try DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: preferences))
        assertPlaneShape(frame)
        XCTAssertEqual(DisplayFrameFixtures.ink(atX: 15, y: 150, frame: frame), .paper)
        XCTAssertEqual(DisplayFrameFixtures.ink(atX: 16, y: Int(BalancedLayout.titleRuleRect.minY), frame: frame), .black)
        XCTAssertTrue(DisplayFrameFixtures.contains(.red, in: BalancedLayout.bodyRect, frame: frame))
        assertDigest(
            frame,
            black: DisplayFramePlaneGoldens.balancedValidBlackSHA256,
            red: DisplayFramePlaneGoldens.balancedValidRedSHA256,
            label: "balanced-valid"
        )
    }

    func testActivityFocusTypicalFixturePlaneDigestAndQuotaPlacement() throws {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .activityFocus
        let frame = try DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: preferences))
        assertPlaneShape(frame)
        XCTAssertEqual(DisplayFrameFixtures.ink(atX: 13, y: 150, frame: frame), .paper)
        let quotas = ActivityFocusLayout.quotaRects(count: 2)
        XCTAssertTrue(DisplayFrameFixtures.contains(.red, in: quotas[1], frame: frame))
        XCTAssertFalse(
            DisplayFrameFixtures.contains(
                .red,
                in: ActivityFocusLayout.primaryRect(hasSecondary: true, hasQuotas: true),
                frame: frame
            )
        )
        assertDigest(
            frame,
            black: DisplayFramePlaneGoldens.activityValidBlackSHA256,
            red: DisplayFramePlaneGoldens.activityValidRedSHA256,
            label: "activity-valid"
        )
    }

    func testUnavailableFixtureHasNoQuotaProgressAndNoRedAccent() throws {
        var preferences = DisplayPreferences.default
        preferences.modules.quota = false
        let frame = try DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(
                preferences: preferences,
                account: DisplayFrameFixtures.unavailableAccount(),
                local: DisplayFrameFixtures.unavailableLocal()
            )
        )
        assertPlaneShape(frame)
        assertTitleAndTickerRules(frame)
        XCTAssertFalse(
            DisplayFrameFixtures.contains(.red, in: QuotaFocusLayout.contentRect, frame: frame)
        )
        let inset = QuotaFocusLayout.heroProgressTrackRect.insetBy(dx: 1, dy: 1)
        XCTAssertFalse(DisplayFrameFixtures.contains(.black, in: inset, frame: frame))
        XCTAssertFalse(DisplayFrameFixtures.contains(.red, in: inset, frame: frame))
        XCTAssertEqual(frame.redPlane, Data(repeating: 0xFF, count: 15_000))
        assertDigest(frame, black: DisplayFramePlaneGoldens.unavailableBlackSHA256, red: DisplayFramePlaneGoldens.unavailableRedSHA256, label: "unavailable")
    }

    private func assertPlaneShape(_ frame: DisplayFrame) {
        XCTAssertEqual(frame.blackPlane.count, 15_000)
        XCTAssertEqual(frame.redPlane.count, 15_000)
    }

    private func assertDigest(
        _ frame: DisplayFrame,
        black: String,
        red: String,
        label: String
    ) {
        let blackHex = DisplayFrameFixtures.sha256Hex(frame.blackPlane)
        let redHex = DisplayFrameFixtures.sha256Hex(frame.redPlane)
        XCTAssertEqual(blackHex, black, "\(label) black=\(blackHex) red=\(redHex)")
        XCTAssertEqual(redHex, red, "\(label) black=\(blackHex) red=\(redHex)")
    }

    private func assertTitleAndTickerRules(_ frame: DisplayFrame) {
        let titleY = Int(QuotaFocusLayout.titleRuleRect.minY)
        for x in 14..<386 {
            XCTAssertEqual(
                DisplayFrameFixtures.ink(atX: x, y: titleY, frame: frame),
                .black,
                "title rule x=\(x)"
            )
        }
        XCTAssertEqual(DisplayFrameFixtures.ink(atX: 0, y: titleY, frame: frame), .paper)
        XCTAssertEqual(DisplayFrameFixtures.ink(atX: 399, y: titleY, frame: frame), .paper)

        for y in Int(QuotaFocusLayout.tickerTopRuleRect.minY)..<Int(QuotaFocusLayout.tickerTopRuleRect.maxY) {
            for x in 14..<386 {
                XCTAssertEqual(
                    DisplayFrameFixtures.ink(atX: x, y: y, frame: frame),
                    .black,
                    "ticker top rule y=\(y) x=\(x)"
                )
            }
        }
        for y in Int(QuotaFocusLayout.tickerBottomRuleRect.minY)..<Int(QuotaFocusLayout.tickerBottomRuleRect.maxY) {
            for x in 14..<386 {
                XCTAssertEqual(
                    DisplayFrameFixtures.ink(atX: x, y: y, frame: frame),
                    .black,
                    "ticker bottom rule y=\(y) x=\(x)"
                )
            }
        }
    }

    private func assertHeroProgress(_ frame: DisplayFrame, percent: Int, fill: InkColor) {
        let track = QuotaFocusLayout.heroProgressTrackRect
        XCTAssertEqual(
            DisplayFrameFixtures.ink(atX: Int(track.minX), y: Int(track.minY), frame: frame),
            .black
        )
        XCTAssertEqual(
            DisplayFrameFixtures.ink(atX: Int(track.maxX) - 1, y: Int(track.minY), frame: frame),
            .black
        )
        let innerWidth = Int(track.width - 2) * percent / 100
        let fillX = Int(track.minX) + 1
        let fillY = Int(track.minY) + 1
        XCTAssertEqual(DisplayFrameFixtures.ink(atX: fillX, y: fillY, frame: frame), fill)
        XCTAssertEqual(DisplayFrameFixtures.ink(atX: fillX + innerWidth - 1, y: fillY, frame: frame), fill)
        XCTAssertEqual(DisplayFrameFixtures.ink(atX: fillX + innerWidth, y: fillY, frame: frame), .paper)
    }
}

enum DisplayFramePlaneGoldens {
    // SHA-256 of the 15,000-byte planes from DisplayFrameComposer for the
    // frozen DisplayFrameFixtures at composedAt=1704067200, TZ=+8.
    // Independent geometry contracts in this file audit rules, progress, badge,
    // red threshold, and polarity; these digests lock the remaining bytes.
    static let validBlackSHA256 = "40593e948a28a40298631cdd33a1c504654386c1c2387d196960b8b77495b78e"
    static let validRedSHA256 = "74de3553ba1a1a9109c0fc8fb201c27cb383555dbc52f6a97b5f3fb829c2885b"
    static let staleBlackSHA256 = "14e83df5111daa2ee20b0cba1ac21aa014a04f0152780882874673d91e3078d4"
    static let staleRedSHA256 = "74de3553ba1a1a9109c0fc8fb201c27cb383555dbc52f6a97b5f3fb829c2885b"
    static let unavailableBlackSHA256 = "74f8daf673ff1f02a5c6dd0730b1490b38fb7f68f287d666ec5a5d7f934655b1"
    static let unavailableRedSHA256 = "bfc5b164e72195f43728bf37b07bce2be21f37d3169c62437c342ce397a9826f"
    static let balancedValidBlackSHA256 = "db3a692e8775dcada1fd43333fdd6a1f905cf039ad59a67847c09e858886e4c0"
    static let balancedValidRedSHA256 = "159b06f13bfd71150af45cb69851eceaaeb77ad6e82ff1af9c0f83db4aed2592"
    static let activityValidBlackSHA256 = "d8f8d695fab2fa49161f8862e60ba899d2c0385a36448ba3b55e004328cb802b"
    static let activityValidRedSHA256 = "c5e8037471ae1a187a7fb3ff54329fea3d8d185cb7846756a1d5c05165ab1ab3"
}
