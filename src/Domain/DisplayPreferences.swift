import Foundation

enum QuotaOrder: String, Sendable, Equatable, CaseIterable {
    case quotaFirst
    case activityFirst
}

enum DateFormatPreference: String, Sendable, Equatable, CaseIterable {
    case relative
    case absolute
}

enum RedAccent: String, Sendable, Equatable, CaseIterable {
    case off
    case threshold
    case always
}

enum InterfaceLanguagePreference: String, Sendable, Equatable, CaseIterable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
}

enum PreferenceValidationError: Error, Equatable, Sendable {
    case invalidTPSWindowMinutes
    case invalidRedThreshold
    case invalidCustomCodexPath
}

struct DisplayModules: Sendable, Equatable {
    var title: Bool
    var plan: Bool
    var quota: Bool
    var today: Bool
    var weekTokens: Bool
    var cache: Bool
    var tps: Bool
    var updated: Bool
    var status: Bool

    static let `default` = DisplayModules(
        title: true,
        plan: true,
        quota: true,
        today: true,
        weekTokens: true,
        cache: false,
        tps: false,
        updated: true,
        status: true
    )
}

struct DisplayPreferences: Sendable, Equatable {
    var displayStyle: DisplayStyle
    var modules: DisplayModules
    var quotaOrder: QuotaOrder
    var title: String
    var tpsWindowMinutes: Int
    var dateFormat: DateFormatPreference
    var redAccent: RedAccent
    var redThreshold: Int
    var language: InterfaceLanguagePreference
    var customCodexPath: String?

    static let titleGraphemeLimit = 24
    static let customCodexPathMaxUTF8Bytes = 4096
    static let allowedTPSWindowMinutes = [3, 15, 60]
    static let redThresholdRange = 50...100
    static let redThresholdStep = 5

    static let `default` = DisplayPreferences(
        displayStyle: .quotaFocus,
        modules: .default,
        quotaOrder: .quotaFirst,
        title: "CODEX USAGE",
        tpsWindowMinutes: 15,
        dateFormat: .relative,
        redAccent: .threshold,
        redThreshold: 80,
        language: .system,
        customCodexPath: nil
    )

    static func sanitizedTitle(_ raw: String) -> String {
        let withoutNewlines = raw.components(separatedBy: .newlines).joined()
        let trimmed = withoutNewlines.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= titleGraphemeLimit {
            return trimmed
        }
        return String(trimmed.prefix(titleGraphemeLimit))
    }

    func validated() throws -> DisplayPreferences {
        var result = self
        result.title = Self.sanitizedTitle(title)
        result.customCodexPath = try Self.validatedCustomCodexPath(customCodexPath)
        guard Self.allowedTPSWindowMinutes.contains(result.tpsWindowMinutes) else {
            throw PreferenceValidationError.invalidTPSWindowMinutes
        }
        guard Self.redThresholdRange.contains(result.redThreshold),
              result.redThreshold.isMultiple(of: Self.redThresholdStep) else {
            throw PreferenceValidationError.invalidRedThreshold
        }
        return result
    }

    private static func validatedCustomCodexPath(_ raw: String?) throws -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        guard trimmed.hasPrefix("/"),
              !trimmed.contains("\0"),
              trimmed.utf8.count <= customCodexPathMaxUTF8Bytes else {
            throw PreferenceValidationError.invalidCustomCodexPath
        }
        return trimmed
    }
}
