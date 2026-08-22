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

    func testStyleChangeAltersFingerprintAndElapsedTimeDoesNot() throws {
        var balanced = DisplayPreferences.default
        balanced.displayStyle = .balanced
        var activity = DisplayPreferences.default
        activity.displayStyle = .activityFocus
        let quota = try DisplayFrameComposer.compose(DisplayFrameFixtures.input()).fingerprint
        let balancedPrint = try DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(preferences: balanced)
        ).fingerprint
        let activityPrint = try DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(preferences: activity)
        ).fingerprint
        XCTAssertNotEqual(quota, balancedPrint)
        XCTAssertNotEqual(quota, activityPrint)
        XCTAssertNotEqual(balancedPrint, activityPrint)
        let laterBalanced = try DisplayFrameComposer.compose(
            DisplayFrameFixtures.input(
                preferences: balanced,
                composedAt: DisplayFrameFixtures.composedAt.addingTimeInterval(3_600)
            )
        ).fingerprint
        XCTAssertEqual(balancedPrint, laterBalanced)
    }

    func testBalancedVisibleRolesAreBodyAndDisabledTitleKeepsPreferenceTitle() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .balanced
        preferences.modules.title = false
        let document = FrameFingerprint.document(
            BalancedModelBuilder.build(DisplayFrameFixtures.input(preferences: preferences))
        )
        guard case .object(let root) = document, case .array(let visible) = root["visible"] else {
            return XCTFail("visible")
        }
        XCTAssertEqual(root["title"], .string("CODEX USAGE"))
        XCTAssertEqual(root["style"], .string("balanced"))
        assertField(visible[0], "id", .string("title"))
        assertField(visible[0], "value", .string("USAGE"))
        assertField(visible[2], "role", .string("body"))
        assertField(visible[2], "id", .string("quota.primary"))
    }

    func testActivityFocusVisibleRolesAndUnusedQuotaOrderStillEnterRoot() {
        var preferences = DisplayPreferences.default
        preferences.displayStyle = .activityFocus
        preferences.quotaOrder = .activityFirst
        let document = FrameFingerprint.document(
            ActivityFocusModelBuilder.build(DisplayFrameFixtures.input(preferences: preferences))
        )
        guard case .object(let root) = document, case .array(let visible) = root["visible"] else {
            return XCTFail("visible")
        }
        XCTAssertEqual(root["style"], .string("activityFocus"))
        XCTAssertEqual(root["quotaOrder"], .string("activityFirst"))
        assertField(visible[2], "id", .string("local.today"))
        assertField(visible[2], "role", .string("primary"))
        assertField(visible[3], "role", .string("secondary"))
        assertField(visible[4], "role", .string("quota"))
        let json = CanonicalJSON.stringify(document)
        XCTAssertFalse(json.contains("Updated "))
        XCTAssertFalse(json.contains("Resets in"))
    }

    func testEnabledCacheAndTPSValuesCoverageAndLookbackEnterFingerprint() throws {
        var preferences = DisplayPreferences.default
        preferences.modules.cache = true
        preferences.modules.tps = true
        let baseInput = DisplayFrameFixtures.input(preferences: preferences)
        let document = FrameFingerprint.document(QuotaFocusModelBuilder.build(baseInput))
        guard case .object(let root) = document, case .array(let visible) = root["visible"] else {
            return XCTFail("visible")
        }
        XCTAssertEqual(root["tpsWindowMinutes"], .string("15"))
        guard case .object(let modules) = root["modules"] else {
            return XCTFail("modules")
        }
        XCTAssertEqual(modules["cache"], .bool(true))
        XCTAssertEqual(modules["tps"], .bool(true))
        XCTAssertEqual(root["localCoverageComplete"], .bool(true))
        let cache = visible.first { value in
            if case .object(let object) = value { return object["id"] == .string("local.cache") }
            return false
        }
        let tps = visible.first { value in
            if case .object(let object) = value { return object["id"] == .string("local.tps") }
            return false
        }
        assertField(cache ?? .null, "value", .string("26%"))
        assertField(cache ?? .null, "coverageComplete", .bool(true))
        assertField(tps ?? .null, "value", .string("1.3"))

        var lookback = preferences
        lookback.tpsWindowMinutes = 3
        let lookbackPrint = CanonicalJSON.stringify(
            FrameFingerprint.document(QuotaFocusModelBuilder.build(DisplayFrameFixtures.input(preferences: lookback)))
        )
        XCTAssertNotEqual(CanonicalJSON.stringify(document), lookbackPrint)
        XCTAssertTrue(lookbackPrint.contains("\"tpsWindowMinutes\":\"3\""))

        let incomplete = LocalActivityObservation(
            availability: .fresh,
            failure: "sourcePartialTail",
            todayTokens: 1_500,
            weekTokens: 12_000,
            cacheHitRate: 0.255,
            tps: 1.25,
            coverageComplete: false
        )
        let incompleteDocument = FrameFingerprint.document(
            QuotaFocusModelBuilder.build(DisplayFrameFixtures.input(preferences: preferences, local: incomplete))
        )
        XCTAssertNotEqual(CanonicalJSON.stringify(document), CanonicalJSON.stringify(incompleteDocument))
        guard case .object(let incompleteRoot) = incompleteDocument, case .array(let incompleteVisible) = incompleteRoot["visible"] else {
            return XCTFail("incomplete visible")
        }
        let incompleteCache = incompleteVisible.first { value in
            if case .object(let object) = value { return object["id"] == .string("local.cache") }
            return false
        }
        assertField(incompleteCache ?? .null, "value", .null)
        assertField(incompleteCache ?? .null, "coverageComplete", .bool(false))
        XCTAssertEqual(incompleteRoot["localCoverageComplete"], .bool(false))

        let unknownPrint = FrameFingerprint.document(
            QuotaFocusModelBuilder.build(DisplayFrameFixtures.input(preferences: preferences, local: .unknown))
        )
        guard case .object(let unknownRoot) = unknownPrint, case .array(let unknownVisible) = unknownRoot["visible"] else {
            return XCTFail("unknown visible")
        }
        let unknownTPS = unknownVisible.first { value in
            if case .object(let object) = value { return object["id"] == .string("local.tps") }
            return false
        }
        assertField(unknownTPS ?? .null, "value", .null)
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
