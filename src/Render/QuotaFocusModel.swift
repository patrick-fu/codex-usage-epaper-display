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
    typealias Field = DisplayField

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
    typealias Item = DisplayItem

    static func build(_ input: DisplayFrameInput) -> QuotaFocusFrameModel {
        var calendar = input.calendar
        calendar.timeZone = input.timeZone
        let language = DisplayCopy.resolvedLanguage(
            preference: input.preferences.language,
            preferredLanguages: input.preferredLanguages
        )
        let modules = input.preferences.modules
        let displayedTitle = DisplayChromeBuilder.displayedTitle(
            modules: modules,
            title: input.preferences.title
        )
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
        let quotaItems = preferences.modules.quota ? returnedWindows(account.windows).map(DisplayItem.quota) : []
        let localItems = DisplayFieldFactory.enabledLocalMetrics(preferences.modules).map(DisplayItem.local)
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
        DisplayFieldFactory.returnedWindows(windows)
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
    ) -> DisplayField {
        DisplayFieldFactory.makeField(item, input: input, calendar: calendar, language: language)
    }
}
