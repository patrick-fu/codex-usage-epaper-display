import XCTest
@testable import UsageInk

final class DisplayPreferencesTests: XCTestCase {
    func testDefaultsMatchSection31() {
        let preferences = DisplayPreferences.default
        XCTAssertEqual(preferences.displayStyle, .quotaFocus)
        XCTAssertEqual(preferences.modules.title, true)
        XCTAssertEqual(preferences.modules.plan, true)
        XCTAssertEqual(preferences.modules.quota, true)
        XCTAssertEqual(preferences.modules.today, true)
        XCTAssertEqual(preferences.modules.weekTokens, true)
        XCTAssertEqual(preferences.modules.cache, false)
        XCTAssertEqual(preferences.modules.tps, false)
        XCTAssertEqual(preferences.modules.updated, true)
        XCTAssertEqual(preferences.modules.status, true)
        XCTAssertEqual(preferences.quotaOrder, .quotaFirst)
        XCTAssertEqual(preferences.title, "CODEX USAGE")
        XCTAssertEqual(preferences.tpsWindowMinutes, 15)
        XCTAssertEqual(preferences.dateFormat, .relative)
        XCTAssertEqual(preferences.redAccent, .threshold)
        XCTAssertEqual(preferences.redThreshold, 80)
        XCTAssertEqual(preferences.language, .system)
        XCTAssertNil(preferences.customCodexPath)
    }

    func testValidatedTitleTrimsWhitespaceRemovesNewlinesAndLimitsGraphemes() throws {
        var preferences = DisplayPreferences.default
        preferences.title = "  Hello\nWorld\r  "
        XCTAssertEqual(try preferences.validated().title, "HelloWorld")

        preferences.title = String(repeating: "你", count: 25)
        XCTAssertEqual(try preferences.validated().title, String(repeating: "你", count: 24))
        XCTAssertEqual(try preferences.validated().title.count, 24)
    }

    func testValidatedRejectsDisallowedTPSWindowsAndThresholds() {
        var preferences = DisplayPreferences.default
        preferences.tpsWindowMinutes = 30
        XCTAssertThrowsError(try preferences.validated()) { error in
            XCTAssertEqual(error as? PreferenceValidationError, .invalidTPSWindowMinutes)
        }

        preferences = .default
        preferences.redThreshold = 81
        XCTAssertThrowsError(try preferences.validated()) { error in
            XCTAssertEqual(error as? PreferenceValidationError, .invalidRedThreshold)
        }

        preferences.redThreshold = 45
        XCTAssertThrowsError(try preferences.validated()) { error in
            XCTAssertEqual(error as? PreferenceValidationError, .invalidRedThreshold)
        }
    }

    func testValidatedAcceptsBoundaryThresholdsAndAllowedTPSWindows() throws {
        for minutes in [3, 15, 60] {
            var preferences = DisplayPreferences.default
            preferences.tpsWindowMinutes = minutes
            XCTAssertEqual(try preferences.validated().tpsWindowMinutes, minutes)
        }
        for threshold in [50, 55, 100] {
            var preferences = DisplayPreferences.default
            preferences.redThreshold = threshold
            XCTAssertEqual(try preferences.validated().redThreshold, threshold)
        }
    }

    func testCustomCodexPathMustBeAbsoluteWithoutNULAndWithinUTF8Limit() {
        var preferences = DisplayPreferences.default
        preferences.customCodexPath = "usr/bin/true"
        XCTAssertThrowsError(try preferences.validated()) { error in
            XCTAssertEqual(error as? PreferenceValidationError, .invalidCustomCodexPath)
        }

        preferences.customCodexPath = "/tmp/codex\0bin"
        XCTAssertThrowsError(try preferences.validated()) { error in
            XCTAssertEqual(error as? PreferenceValidationError, .invalidCustomCodexPath)
        }

        preferences.customCodexPath = "/" + String(repeating: "a", count: 4096)
        XCTAssertThrowsError(try preferences.validated()) { error in
            XCTAssertEqual(error as? PreferenceValidationError, .invalidCustomCodexPath)
        }

        preferences.customCodexPath = "   "
        XCTAssertNil(try preferences.validated().customCodexPath)
    }
}
