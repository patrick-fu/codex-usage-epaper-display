import Foundation

struct ActivityFocusFrameModel: Sendable, Equatable {
    var language: ResolvedInterfaceLanguage
    var languageCode: String
    var title: String
    var plan: String?
    var showPlan: Bool
    var primary: DisplayField?
    var secondary: [DisplayField]
    var quotas: [DisplayField]
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

enum ActivityFocusModelBuilder {
    static func build(_ input: DisplayFrameInput) -> ActivityFocusFrameModel {
        let resolved = DisplayChromeBuilder.resolve(input)
        let modules = input.preferences.modules
        let localKinds = DisplayFieldFactory.enabledLocalMetrics(modules)
        let primaryKind = localKinds.first
        let secondaryKinds = Array(localKinds.dropFirst().prefix(ActivityFocusLayout.maxSecondaryCells))
        let quotaWindows = modules.quota ? DisplayFieldFactory.returnedWindows(input.account.windows) : []
        let primary = primaryKind.map {
            DisplayFieldFactory.localField($0, input: input, language: resolved.language)
        }
        let secondary = secondaryKinds.map {
            DisplayFieldFactory.localField($0, input: input, language: resolved.language)
        }
        let quotas = quotaWindows.map {
            DisplayFieldFactory.quotaField(
                $0,
                input: input,
                calendar: resolved.calendar,
                language: resolved.language
            )
        }
        let hasContent = primary != nil || !quotas.isEmpty
        return ActivityFocusFrameModel(
            language: resolved.language,
            languageCode: DisplayCopy.languageCode(resolved.language),
            title: DisplayChromeBuilder.displayedTitle(modules: modules, title: input.preferences.title),
            plan: modules.plan ? DisplayCopy.displayedPlan(input.account.planType) : nil,
            showPlan: modules.plan,
            primary: primary,
            secondary: secondary,
            quotas: quotas,
            footerUpdated: modules.updated
                ? DisplayCopy.footerUpdated(
                    composedAt: input.composedAt,
                    calendar: resolved.calendar,
                    timeZone: input.timeZone,
                    language: resolved.language
                )
                : nil,
            footerStatus: modules.status ? DisplayCopy.footerStatus(language: resolved.language) : nil,
            unavailableMark: hasContent ? nil : DisplayCopy.emDash,
            preferences: input.preferences,
            accountAvailability: input.account.availability.rawValue,
            accountFailure: input.account.failure,
            localAvailability: input.localActivity.availability.rawValue,
            localFailure: input.localActivity.failure,
            localCoverageComplete: input.localActivity.coverageComplete
        )
    }
}
