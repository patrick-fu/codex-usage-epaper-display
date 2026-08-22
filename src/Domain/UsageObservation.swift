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

enum ObservationAvailability: String, Sendable, Equatable {
    case unknown
    case fresh
    case stale
    case authRequired
    case unavailable
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
    var availability: ObservationAvailability
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
    var availability: ObservationAvailability
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

    func value(for kind: LocalMetricKind) -> Double? {
        switch kind {
        case .today:
            return todayTokens.map(Double.init)
        case .weekTokens:
            return weekTokens.map(Double.init)
        case .cache:
            return cacheHitRate
        case .tps:
            return tps
        }
    }
}
