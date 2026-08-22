import Foundation

enum UsageWindowSlot: String, Sendable, Equatable {
    case primary
    case secondary

    var canonicalIndex: Int {
        switch self {
        case .primary: return 0
        case .secondary: return 1
        }
    }
}

enum LocalMetricKind: String, Sendable, Equatable, CaseIterable {
    case today
    case weekTokens
    case cache
    case tps
}

struct UsageWindowObservation: Sendable, Equatable {
    var slot: UsageWindowSlot
    var usedPercent: Double
    var windowDurationMins: Int
    var resetsAt: Int?
}

struct AccountObservation: Sendable, Equatable {
    var availability: PersistedAvailability
    var failure: String?
    var planType: String?
    var windows: [UsageWindowObservation]

    static let unknown = AccountObservation(
        availability: .unknown,
        failure: nil,
        planType: nil,
        windows: []
    )
}

struct LocalActivityObservation: Sendable, Equatable {
    var availability: PersistedAvailability
    var failure: String?
    var todayTokens: Int?
    var weekTokens: Int?
    var cacheHitRate: Double?
    var tps: Double?
    var coverageComplete: Bool

    static let unknown = LocalActivityObservation(
        availability: .unknown,
        failure: nil,
        todayTokens: nil,
        weekTokens: nil,
        cacheHitRate: nil,
        tps: nil,
        coverageComplete: false
    )
}
