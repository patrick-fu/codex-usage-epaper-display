import CoreGraphics
import XCTest
@testable import UsageInk

final class DisplayFrameComposerTests: XCTestCase {
    func testDefaultQuotaFocusProducesFifteenThousandBytePlanes() {
        let frame = DisplayFrameComposer.compose(DisplayFrameFixtures.input())
        XCTAssertEqual(frame.blackPlane.count, 15_000)
        XCTAssertEqual(frame.redPlane.count, 15_000)
        XCTAssertEqual(frame.fingerprint.count, 64)
    }

    func testRedAccentAppliesOnlyToQuotaPercentageAndProgress() {
        var off = DisplayPreferences.default
        off.redAccent = .off
        let offFrame = DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: off))
        XCTAssertFalse(
            DisplayFrameFixtures.contains(.red, in: QuotaFocusLayout.heroRect, frame: offFrame)
        )

        var always = DisplayPreferences.default
        always.redAccent = .always
        let alwaysFrame = DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: always))
        XCTAssertTrue(
            DisplayFrameFixtures.contains(.red, in: QuotaFocusLayout.heroRect, frame: alwaysFrame)
        )

        var threshold = DisplayPreferences.default
        threshold.redAccent = .threshold
        threshold.redThreshold = 80
        let over = DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: threshold))
        XCTAssertTrue(DisplayFrameFixtures.contains(.red, in: QuotaFocusLayout.heroRect, frame: over))

        var account = DisplayFrameFixtures.typicalAccount()
        account.windows[1].usedPercent = 20
        let under = DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(preferences: threshold, account: account)
        )
        XCTAssertFalse(DisplayFrameFixtures.contains(.red, in: QuotaFocusLayout.heroRect, frame: under))
    }

    func testMarginsStayPaperAndOverflowDoesNotCrash() {
        var preferences = DisplayPreferences.default
        preferences.title = String(repeating: "W", count: 24)
        var account = DisplayFrameFixtures.typicalAccount()
        account.planType = "PLUSPLUSPLUS"
        let frame = DisplayFrameComposer.compose(
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

    func testChineseCopyStillProducesInkWhenLanguageIsSimplifiedChinese() {
        var preferences = DisplayPreferences.default
        preferences.language = .simplifiedChinese
        let frame = DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(preferences: preferences, preferredLanguages: ["zh-Hans"])
        )
        XCTAssertTrue(
            DisplayFrameFixtures.contains(.black, in: QuotaFocusLayout.heroRect, frame: frame)
        )
        XCTAssertTrue(
            DisplayFrameFixtures.contains(.black, in: QuotaFocusLayout.footerRect, frame: frame)
        )
    }

    func testComposeDoesNotWriteRenderArtifacts() {
        let tmp = FileManager.default.temporaryDirectory
        let marker = tmp.appendingPathComponent("usageink-issue-13-marker-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FileManager().createFile(atPath: marker.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: marker) }
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
        _ = DisplayFrameComposer.compose(DisplayFrameFixtures.input())
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
        XCTAssertEqual(after, before)
    }

    func testRenderSourcesNeverWritePlanesOrImages() throws {
        let render = RepoRoot.url().appendingPathComponent("src/Render")
        let forbidden = [
            "writeToFile",
            "pngData",
            "tiffRepresentation",
            "CGImageDestination",
            "NSBitmapImageRep",
            "NSImage",
        ]
        let files = try FileManager.default.contentsOfDirectory(atPath: render.path)
        XCTAssertFalse(files.isEmpty)
        for name in files where name.hasSuffix(".swift") {
            let text = try String(
                contentsOf: render.appendingPathComponent(name),
                encoding: .utf8
            )
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(name) contains \(token)")
            }
        }
    }
}
