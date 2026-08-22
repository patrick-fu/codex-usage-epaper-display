import Foundation

struct DisplayField: Sendable, Equatable {
    var id: String
    var label: String
    var displayedValue: String
    var semanticValue: String?
    var secondaryText: String?
    var badge: String?
    var availability: String
    var usesRed: Bool
    var progressPercent: Int?
    var slot: String?
    var windowDurationMins: String?
    var resetsAt: String?
    var coverageComplete: Bool?
    var isQuota: Bool
}

enum DisplayItem: Equatable {
    case quota(UsageWindowObservation)
    case local(LocalMetricKind)
}

enum IntegerSplit {
    static func split(_ length: Int, into count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let base = length / count
        let remainder = length % count
        return (0..<count).map { index in
            base + (index < remainder ? 1 : 0)
        }
    }
}

enum DisplayChromeBuilder {
    static func displayedTitle(modules: DisplayModules, title: String) -> String {
        modules.title ? title : "USAGE"
    }

    static func resolve(_ input: DisplayFrameInput) -> (
        language: ResolvedInterfaceLanguage,
        calendar: Calendar
    ) {
        var calendar = input.calendar
        calendar.timeZone = input.timeZone
        let language = DisplayCopy.resolvedLanguage(
            preference: input.preferences.language,
            preferredLanguages: input.preferredLanguages
        )
        return (language, calendar)
    }
}

enum DisplayFieldFactory {
    static func returnedWindows(_ windows: [UsageWindowObservation]) -> [UsageWindowObservation] {
        let canonical: [UsageWindowSlot] = [.primary, .secondary]
        return canonical.compactMap { slot in
            windows.first { $0.slot == slot && $0.windowDurationMins > 0 }
        }
    }

    static func enabledLocalMetrics(_ modules: DisplayModules) -> [LocalMetricKind] {
        LocalMetricKind.allCases.filter { kind in
            switch kind {
            case .today: return modules.today
            case .weekTokens: return modules.weekTokens
            case .cache: return modules.cache
            case .tps: return modules.tps
            }
        }
    }

    static func makeField(
        _ item: DisplayItem,
        input: DisplayFrameInput,
        calendar: Calendar,
        language: ResolvedInterfaceLanguage
    ) -> DisplayField {
        switch item {
        case .quota(let window):
            return quotaField(window, input: input, calendar: calendar, language: language)
        case .local(let kind):
            return localField(kind, input: input, language: language)
        }
    }

    static func quotaField(
        _ window: UsageWindowObservation,
        input: DisplayFrameInput,
        calendar: Calendar,
        language: ResolvedInterfaceLanguage
    ) -> DisplayField {
        let percent = DisplayCopy.formatPercent(window.usedPercent)
        let text = percent.map { "\($0)%" }
        let badge = DisplayCopy.degradedMessage(
            availability: input.account.availability,
            failure: input.account.failure,
            source: .account,
            language: language
        )
        let hasHistory = text != nil
        let displayed = text ?? DisplayCopy.emDash
        let usesRed: Bool
        if let percent {
            usesRed = quotaUsesRed(percent, preferences: input.preferences)
        } else {
            usesRed = false
        }
        return DisplayField(
            id: "quota.\(window.slot.rawValue)",
            label: DisplayCopy.windowLabel(durationMinutes: window.windowDurationMins, language: language),
            displayedValue: displayed,
            semanticValue: text,
            secondaryText: DisplayCopy.resetText(
                resetsAt: window.resetsAt,
                composedAt: input.composedAt,
                dateFormat: input.preferences.dateFormat,
                calendar: calendar,
                timeZone: input.timeZone,
                language: language
            ),
            badge: hasHistory ? (input.account.availability == .stale ? badge : nil) : badge,
            availability: input.account.availability.rawValue,
            usesRed: usesRed,
            progressPercent: percent,
            slot: window.slot.rawValue,
            windowDurationMins: String(window.windowDurationMins),
            resetsAt: window.resetsAt.flatMap { seconds in
                DisplayCopy.date(fromUnixSeconds: seconds, calendar: calendar).map { _ in String(seconds) }
            },
            coverageComplete: nil,
            isQuota: true
        )
    }

    static func localField(
        _ kind: LocalMetricKind,
        input: DisplayFrameInput,
        language: ResolvedInterfaceLanguage
    ) -> DisplayField {
        let observation = input.localActivity
        let semantic: String?
        switch kind {
        case .today:
            semantic = observation.todayTokens.map(DisplayCopy.formatTokens)
        case .weekTokens:
            semantic = observation.weekTokens.map(DisplayCopy.formatTokens)
        case .cache:
            if observation.coverageComplete, let rate = observation.cacheHitRate {
                semantic = DisplayCopy.formatCacheRate(rate)
            } else {
                semantic = nil
            }
        case .tps:
            semantic = observation.tps.flatMap(DisplayCopy.formatTPS)
        }
        let hasHistory = semantic != nil
        let badge = DisplayCopy.degradedMessage(
            availability: observation.availability,
            failure: observation.failure,
            source: .local,
            language: language
        )
        return DisplayField(
            id: "local.\(kind.rawValue)",
            label: DisplayCopy.localLabel(kind: kind, language: language),
            displayedValue: semantic ?? DisplayCopy.emDash,
            semanticValue: semantic,
            secondaryText: nil,
            badge: hasHistory ? (observation.availability == .stale ? badge : nil) : badge,
            availability: observation.availability.rawValue,
            usesRed: false,
            progressPercent: nil,
            slot: nil,
            windowDurationMins: nil,
            resetsAt: nil,
            coverageComplete: kind == .cache ? observation.coverageComplete : nil,
            isQuota: false
        )
    }

    static func quotaUsesRed(_ percent: Int, preferences: DisplayPreferences) -> Bool {
        switch preferences.redAccent {
        case .off:
            return false
        case .always:
            return true
        case .threshold:
            return percent >= preferences.redThreshold
        }
    }
}
