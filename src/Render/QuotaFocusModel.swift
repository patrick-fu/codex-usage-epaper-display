import Foundation

struct DisplayFrameInput: Sendable, Equatable {
    var preferences: DisplayPreferences
    var account: AccountObservation
    var localActivity: LocalActivityObservation
    var composedAt: Date
    var calendar: Calendar
    var timeZone: TimeZone
    var preferredLanguages: [String]
}

struct QuotaFocusFrameModel: Sendable, Equatable {
    struct Field: Sendable, Equatable {
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

    var language: ResolvedInterfaceLanguage
    var languageCode: String
    var title: String
    var plan: String?
    var showPlan: Bool
    var hero: Field?
    var ticker: [Field]
    var footerUpdated: String?
    var footerStatus: String?
    var unavailableMark: String?
    var preferences: DisplayPreferences
    var accountAvailability: String
    var accountFailure: String?
    var localAvailability: String
    var localFailure: String?
    var localCoverageComplete: Bool
}

enum QuotaFocusModelBuilder {
    enum Item: Equatable {
        case quota(UsageWindowObservation)
        case local(LocalMetricKind)
    }

    static func build(_ input: DisplayFrameInput) -> QuotaFocusFrameModel {
        var calendar = input.calendar
        calendar.timeZone = input.timeZone
        let language = DisplayCopy.resolvedLanguage(
            preference: input.preferences.language,
            preferredLanguages: input.preferredLanguages
        )
        let modules = input.preferences.modules
        let displayedTitle = modules.title
            ? input.preferences.title
            : "USAGE"
        let plan = modules.plan ? DisplayCopy.displayedPlan(input.account.planType) : nil
        let (heroItem, tickerItems) = select(
            preferences: input.preferences,
            account: input.account,
            local: input.localActivity
        )
        let hero = heroItem.map {
            makeField($0, input: input, calendar: calendar, language: language)
        }
        let ticker = tickerItems.prefix(QuotaFocusLayout.maxTickerCells).map {
            makeField($0, input: input, calendar: calendar, language: language)
        }
        let unavailableMark = hero == nil ? DisplayCopy.emDash : nil
        return QuotaFocusFrameModel(
            language: language,
            languageCode: DisplayCopy.languageCode(language),
            title: displayedTitle,
            plan: plan,
            showPlan: modules.plan,
            hero: hero,
            ticker: Array(ticker),
            footerUpdated: modules.updated
                ? DisplayCopy.footerUpdated(
                    composedAt: input.composedAt,
                    calendar: calendar,
                    timeZone: input.timeZone,
                    language: language
                )
                : nil,
            footerStatus: modules.status ? DisplayCopy.footerStatus(language: language) : nil,
            unavailableMark: unavailableMark,
            preferences: input.preferences,
            accountAvailability: input.account.availability.rawValue,
            accountFailure: input.account.failure,
            localAvailability: input.localActivity.availability.rawValue,
            localFailure: input.localActivity.failure,
            localCoverageComplete: input.localActivity.coverageComplete
        )
    }

    static func select(
        preferences: DisplayPreferences,
        account: AccountObservation,
        local: LocalActivityObservation
    ) -> (Item?, [Item]) {
        let quotaItems = preferences.modules.quota ? returnedWindows(account.windows).map(Item.quota) : []
        let localItems = enabledLocalMetrics(preferences.modules).map(Item.local)
        let preferred = preferences.quotaOrder == .quotaFirst ? quotaItems : localItems
        let fallback = preferences.quotaOrder == .quotaFirst ? localItems : quotaItems
        let usingPreferred = !preferred.isEmpty
        let group = usingPreferred ? preferred : fallback
        let other = usingPreferred ? fallback : []
        guard let hero = pickHero(from: group) else {
            return (nil, [])
        }
        let remaining = group.filter { $0 != hero }
        return (hero, Array((remaining + other).prefix(QuotaFocusLayout.maxTickerCells)))
    }

    static func returnedWindows(_ windows: [UsageWindowObservation]) -> [UsageWindowObservation] {
        let canonical: [UsageWindowSlot] = [.primary, .secondary]
        return canonical.compactMap { slot in
            windows.first { $0.slot == slot && $0.windowDurationMins > 0 }
        }
    }

    private static func enabledLocalMetrics(_ modules: DisplayModules) -> [LocalMetricKind] {
        LocalMetricKind.allCases.filter { kind in
            switch kind {
            case .today: return modules.today
            case .weekTokens: return modules.weekTokens
            case .cache: return modules.cache
            case .tps: return modules.tps
            }
        }
    }

    private static func pickHero(from items: [Item]) -> Item? {
        let windows = items.compactMap { item -> UsageWindowObservation? in
            if case .quota(let window) = item {
                return window
            }
            return nil
        }
        if !windows.isEmpty {
            let hero = windows.max { lhs, rhs in
                if lhs.windowDurationMins != rhs.windowDurationMins {
                    return lhs.windowDurationMins < rhs.windowDurationMins
                }
                return lhs.slot.canonicalIndex < rhs.slot.canonicalIndex
            }!
            return .quota(hero)
        }
        return items.first
    }

    private static func makeField(
        _ item: Item,
        input: DisplayFrameInput,
        calendar: Calendar,
        language: ResolvedInterfaceLanguage
    ) -> QuotaFocusFrameModel.Field {
        switch item {
        case .quota(let window):
            return quotaField(window, input: input, calendar: calendar, language: language)
        case .local(let kind):
            return localField(kind, input: input, language: language)
        }
    }

    private static func quotaField(
        _ window: UsageWindowObservation,
        input: DisplayFrameInput,
        calendar: Calendar,
        language: ResolvedInterfaceLanguage
    ) -> QuotaFocusFrameModel.Field {
        let percent = DisplayCopy.formatPercent(window.usedPercent)
        let text = percent.map { "\($0)%" }
        let badge = DisplayCopy.degradedMessage(
            availability: input.account.availability,
            failure: input.account.failure,
            source: .account,
            language: language
        )
        let hasHistory = text != nil
        let displayed: String
        if let text, hasHistory {
            displayed = text
        } else {
            displayed = DisplayCopy.emDash
        }
        let usesRed: Bool
        if let percent {
            usesRed = quotaUsesRed(percent, preferences: input.preferences)
        } else {
            usesRed = false
        }
        return QuotaFocusFrameModel.Field(
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

    private static func localField(
        _ kind: LocalMetricKind,
        input: DisplayFrameInput,
        language: ResolvedInterfaceLanguage
    ) -> QuotaFocusFrameModel.Field {
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
        return QuotaFocusFrameModel.Field(
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

    private static func quotaUsesRed(_ percent: Int, preferences: DisplayPreferences) -> Bool {
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
