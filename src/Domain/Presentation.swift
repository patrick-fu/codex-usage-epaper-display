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
        local: LocalActivityObservation = .unknown,
        displayUnavailable: Bool,
        bleLink: BLELinkState = .unbound,
        classification: BLEClassification? = nil
    ) -> String {
        summary(
            account: AccountObservation(availability: .unknown, failure: nil, planType: nil, windows: []),
            local: local,
            displayUnavailable: displayUnavailable,
            bleLink: bleLink,
            classification: classification
        )
    }

    func summary(
        account: AccountObservation,
        local: SourceAvailability,
        displayUnavailable: Bool,
        bleLink: BLELinkState = .unbound,
        classification: BLEClassification? = nil
    ) -> String {
        summary(
            account: account,
            local: LocalActivityObservation.unknown,
            displayUnavailable: displayUnavailable,
            bleLink: bleLink,
            classification: classification
        )
    }

    func summary(
        account: AccountObservation,
        local: LocalActivityObservation,
        displayUnavailable: Bool,
        bleLink: BLELinkState = .unbound,
        classification: BLEClassification? = nil
    ) -> String {
        var parts = [accountText(account), localText(local)]
        if let linkText = bleLink.menuText(language: language) {
            parts.append(linkText)
        }
        if let classification, classification == .firmwareIncompatible {
            parts.append(classification.menuText(language: language))
        } else if displayUnavailable {
            if bleLink.menuText(language: language) == nil {
                parts.append(displayUnavailableText)
            }
            if let classification {
                parts.append(classification.menuText(language: language))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func accountText(_ account: AccountObservation) -> String {
        switch account.failure {
        case "authRequired":
            return localized("Sign in to Codex", "请在 Codex 登录")
        case "binaryMissing":
            return localized("Codex not found", "未找到 Codex")
        case "versionTooOld":
            return localized("Update Codex", "请升级 Codex")
        case "protocolIncompatible":
            return localized("Codex incompatible", "Codex 协议不兼容")
        case "rateLimitUnavailable":
            return localized("Quota unavailable", "限额暂不可用")
        default:
            break
        }
        switch account.availability {
        case .authRequired:
            return localized("Sign in to Codex", "请在 Codex 登录")
        case .stale:
            return localized("Account data stale", "账户数据已过期")
        case .unknown, .fresh, .unavailable:
            return "—"
        }
    }

    private func localized(_ english: String, _ chinese: String) -> String {
        language == .english ? english : chinese
    }

    private func localText(_ observation: LocalActivityObservation) -> String {
        if let today = observation.todayTokens, let week = observation.weekTokens {
            let todayText = MetricFormatting.formatTokens(today)
            let weekText = MetricFormatting.formatTokens(week)
            switch language {
            case .english:
                return "Local Today \(todayText) · Local This Week \(weekText)"
            case .simplifiedChinese:
                return "本机今日 \(todayText) · 本机本周 \(weekText)"
            }
        }
        if let failure = observation.failure {
            switch failure {
            case "sourceUnreadable", "sourcePermissionDenied":
                return language == .english ? "Local source unreadable" : "本机来源不可读"
            case "sourceUnavailable":
                return language == .english ? "Local source unavailable" : "本机来源不可用"
            case "sourceMalformed", "sourcePartialTail":
                return language == .english ? "Local data partial" : "本机数据不完整"
            default:
                break
            }
        }
        switch observation.availability {
        case .unavailable:
            return language == .english ? "Local source unavailable" : "本机来源不可用"
        case .unknown, .fresh, .stale, .authRequired:
            return language == .english ? "Local activity unknown" : "本机活动未知"
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
