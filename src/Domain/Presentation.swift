#if swift(<6.0)
#error("UsageInk requires Swift 6 language mode")
#endif

import Foundation

enum DisplayStyle: String, Sendable, Equatable, CaseIterable {
    case balanced
    case quotaFocus
    case activityFocus

    var menuTitle: String {
        switch self {
        case .balanced:
            return "Balanced"
        case .quotaFocus:
            return "Quota Focus"
        case .activityFocus:
            return "Activity Focus"
        }
    }
}

enum BindingPresentation: Sendable, Equatable {
    case unbound
    case bound
}

enum SourceAvailability: Sendable, Equatable {
    case unknown
}

enum ResolvedInterfaceLanguage: Sendable, Equatable {
    case english
    case simplifiedChinese

    static func resolveSystem(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> ResolvedInterfaceLanguage {
        guard let first = preferredLanguages.first else {
            return .english
        }
        if first == "zh" || first.hasPrefix("zh-Hans") || first.hasPrefix("zh-CN") {
            return .simplifiedChinese
        }
        return .english
    }
}

struct StatusSummaryFormatter: Sendable, Equatable {
    var language: ResolvedInterfaceLanguage

    func summary(
        account: SourceAvailability,
        local: SourceAvailability,
        displayUnavailable: Bool
    ) -> String {
        var parts = [accountText(account), localText(local)]
        if displayUnavailable {
            parts.append(displayUnavailableText)
        }
        return parts.joined(separator: " · ")
    }

    private func accountText(_ availability: SourceAvailability) -> String {
        switch availability {
        case .unknown:
            return "—"
        }
    }

    private func localText(_ availability: SourceAvailability) -> String {
        switch availability {
        case .unknown:
            switch language {
            case .english:
                return "Local activity unknown"
            case .simplifiedChinese:
                return "本机活动未知"
            }
        }
    }

    private var displayUnavailableText: String {
        switch language {
        case .english:
            return "Display unavailable"
        case .simplifiedChinese:
            return "显示器不可用"
        }
    }
}
