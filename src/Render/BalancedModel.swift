import Foundation

struct BalancedFrameModel: Sendable, Equatable {
    var language: ResolvedInterfaceLanguage
    var languageCode: String
    var title: String
    var plan: String?
    var showPlan: Bool
    var entries: [DisplayField]
    var body: [DisplayField] { entries }
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

enum BalancedModelBuilder {
    typealias Item = DisplayItem

    static func build(_ input: DisplayFrameInput) -> BalancedFrameModel {
        let resolved = DisplayChromeBuilder.resolve(input)
        let modules = input.preferences.modules
        let items = Array(select(preferences: input.preferences, account: input.account).prefix(BalancedLayout.maxEntries))
        let entries = items.map {
            DisplayFieldFactory.makeField(
                $0,
                input: input,
                calendar: resolved.calendar,
                language: resolved.language
            )
        }
        return BalancedFrameModel(
            language: resolved.language,
            languageCode: DisplayCopy.languageCode(resolved.language),
            title: DisplayChromeBuilder.displayedTitle(modules: modules, title: input.preferences.title),
            plan: modules.plan ? DisplayCopy.displayedPlan(input.account.planType) : nil,
            showPlan: modules.plan,
            entries: entries,
            footerUpdated: modules.updated
                ? DisplayCopy.footerUpdated(
                    composedAt: input.composedAt,
                    calendar: resolved.calendar,
                    timeZone: input.timeZone,
                    language: resolved.language
                )
                : nil,
            footerStatus: modules.status ? DisplayCopy.footerStatus(language: resolved.language) : nil,
            unavailableMark: entries.isEmpty ? DisplayCopy.emDash : nil,
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
        local: LocalActivityObservation = .unknown
    ) -> [Item] {
        _ = local
        let quotaItems = preferences.modules.quota
            ? DisplayFieldFactory.returnedWindows(account.windows).map(DisplayItem.quota)
            : []
        let localItems = DisplayFieldFactory.enabledLocalMetrics(preferences.modules).map(DisplayItem.local)
        let ordered = preferences.quotaOrder == .quotaFirst
            ? quotaItems + localItems
            : localItems + quotaItems
        return Array(ordered.prefix(BalancedLayout.maxEntries))
    }
}
