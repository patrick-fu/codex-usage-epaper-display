import XCTest
@testable import UsageInk

final class FrameFingerprintTests: XCTestCase {
    func testCanonicalJSONContainsVisibleFieldsAndExcludesClocks() throws {
        let input = DisplayFrameFixtures.input()
        let model = QuotaFocusModelBuilder.build(input)
        let document = FrameFingerprint.document(model)
        guard case .object(let root) = document else {
            return XCTFail("root must be an object")
        }

        XCTAssertEqual(root["v"], .int(1))
        XCTAssertEqual(root["language"], .string("en"))
        XCTAssertEqual(root["style"], .string("quotaFocus"))
        XCTAssertEqual(root["title"], .string("CODEX USAGE"))
        XCTAssertEqual(root["quotaOrder"], .string("quotaFirst"))
        XCTAssertEqual(root["dateFormat"], .string("relative"))
        XCTAssertEqual(root["redAccent"], .string("threshold"))
        XCTAssertEqual(root["redThreshold"], .string("80"))
        XCTAssertEqual(root["tpsWindowMinutes"], .string("15"))
        XCTAssertEqual(root["accountAvailability"], .string("fresh"))
        XCTAssertEqual(root["localAvailability"], .string("fresh"))

        guard case .object(let modules) = root["modules"] else {
            return XCTFail("modules object")
        }
        XCTAssertEqual(modules["quota"], .bool(true))
        XCTAssertEqual(modules["tps"], .bool(false))
        XCTAssertEqual(modules["updated"], .bool(true))

        guard case .array(let visible) = root["visible"] else {
            return XCTFail("visible array")
        }
        assertField(visible[0], "id", .string("title"))
        assertField(visible[1], "id", .string("plan"))
        assertField(visible[2], "id", .string("quota.secondary"))
        assertField(visible[2], "role", .string("hero"))
        assertField(visible[2], "value", .string("81%"))
        assertField(visible[2], "windowDurationMins", .string("10080"))
        assertField(
            visible[2],
            "resetsAt",
            .string(String(Int(DisplayFrameFixtures.composedAt.timeIntervalSince1970) + 86_400))
        )
        assertField(visible[3], "id", .string("quota.primary"))
        assertField(visible[3], "role", .string("ticker"))
        assertField(visible[4], "id", .string("local.today"))
        assertField(visible[5], "id", .string("local.weekTokens"))

        let json = CanonicalJSON.stringify(document)
        XCTAssertFalse(json.contains("Updated "))
        XCTAssertFalse(json.contains("Resets in"))
        XCTAssertFalse(json.contains("Display connected"))
        XCTAssertEqual(
            try DisplayFrameComposer.compose(input).fingerprint,
            FrameFingerprint.hexSHA256(of: model)
        )
    }

    func testQuotaOrderFieldTracksThePreferenceDirectly() {
        var preferences = DisplayPreferences.default
        preferences.quotaOrder = .activityFirst
        let document = FrameFingerprint.document(
            QuotaFocusModelBuilder.build(DisplayFrameFixtures.input(preferences: preferences))
        )
        guard case .object(let root) = document else {
            return XCTFail("root must be an object")
        }
        XCTAssertEqual(root["quotaOrder"], .string("activityFirst"))
        guard case .array(let visible) = root["visible"] else {
            return XCTFail("visible array")
        }
        assertField(visible[2], "id", .string("local.today"))
        assertField(visible[2], "role", .string("hero"))
    }

    func testElapsedTimeAloneDoesNotChangeFingerprint() throws {
        let first = try DisplayFrameComposer.compose(DisplayFrameFixtures.input()).fingerprint
        let later = try DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(composedAt: DisplayFrameFixtures.composedAt.addingTimeInterval(3_600))
        ).fingerprint
        XCTAssertEqual(first, later)
    }

    func testAbsoluteResetChangeIsPresentInCanonicalJSON() {
        var shifted = DisplayFrameFixtures.typicalAccount()
        shifted.windows[1].resetsAt = (shifted.windows[1].resetsAt ?? 0) + 60
        let base = FrameFingerprint.document(
            QuotaFocusModelBuilder.build(DisplayFrameFixtures.input())
        )
        let changed = FrameFingerprint.document(
            QuotaFocusModelBuilder.build(DisplayFrameFixtures.input(account: shifted))
        )
        XCTAssertNotEqual(CanonicalJSON.stringify(base), CanonicalJSON.stringify(changed))
        guard case .object(let root) = changed, case .array(let visible) = root["visible"] else {
            return XCTFail("visible")
        }
        assertField(
            visible[2],
            "resetsAt",
            .string(String(Int(DisplayFrameFixtures.composedAt.timeIntervalSince1970) + 86_460))
        )
    }

    func testFingerprintIsLowercaseHexSHA256() throws {
        let fingerprint = try DisplayFrameComposer.compose(DisplayFrameFixtures.input()).fingerprint
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertTrue(fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    private func assertField(
        _ value: CanonicalJSON.Value,
        _ key: String,
        _ expected: CanonicalJSON.Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .object(let object) = value else {
            return XCTFail("expected object", file: file, line: line)
        }
        XCTAssertEqual(object[key], expected, file: file, line: line)
    }
}
