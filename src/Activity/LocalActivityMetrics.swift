import Foundation

enum LocalActivityMetrics {
    static let staleAgeSeconds = 20 * 60
    static let factRetentionSeconds = 8 * 24 * 60 * 60
    static let cursorRetentionSeconds = 30 * 24 * 60 * 60

    static func isoCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static func dayRange(containing date: Date, calendar: Calendar) -> Range<Int>? {
        unixRange(of: .day, containing: date, calendar: calendar)
    }

    static func weekRange(containing date: Date, calendar: Calendar) -> Range<Int>? {
        unixRange(of: .weekOfYear, containing: date, calendar: calendar)
    }

    static func tpsRange(pollStart: Date, windowMinutes: Int) -> ClosedRange<Int> {
        let end = Int(pollStart.timeIntervalSince1970.rounded(.towardZero))
        let start = end - windowMinutes * 60
        return start...end
    }

    static func availability(lastSuccessfulObservationAt: Int?, now: Date) -> PersistedAvailability {
        guard let lastSuccessfulObservationAt else {
            return .unknown
        }
        let age = Int(now.timeIntervalSince1970.rounded(.towardZero)) - lastSuccessfulObservationAt
        if age >= staleAgeSeconds {
            return .stale
        }
        return .fresh
    }

    private static func unixRange(
        of component: Calendar.Component,
        containing date: Date,
        calendar: Calendar
    ) -> Range<Int>? {
        guard let interval = calendar.dateInterval(of: component, for: date) else {
            return nil
        }
        let start = Int(interval.start.timeIntervalSince1970.rounded(.towardZero))
        let end = Int(interval.end.timeIntervalSince1970.rounded(.towardZero))
        guard end > start else {
            return nil
        }
        return start..<end
    }
}

struct ActivityFactRecord: Sendable, Equatable {
    var sourceKey: String
    var observedAt: Int
    var inputDelta: Int64
    var cachedInputDelta: Int64
    var outputDelta: Int64
    var reasoningDelta: Int64
}

struct SourceCursorRecord: Sendable, Equatable {
    var sourceKey: String
    var parserVersion: Int
    var inodeGeneration: Int64
    var sizeBytes: Int64
    var newlineOffset: Int64
    var tailChecksum: String
    var inputWatermark: Int64
    var cachedInputWatermark: Int64
    var outputWatermark: Int64
    var reasoningWatermark: Int64
    var lastSeenAt: Int
}

enum ActivityScanStatus: Sendable, Equatable {
    case committed
    case budgetExhausted
    case transactionFailed
}

struct ActivityScanPlan: Sendable, Equatable {
    var status: ActivityScanStatus
    var coverageComplete: Bool
    var failure: String?
    var rebuildSourceKeys: [String]
    var facts: [ActivityFactRecord]
    var cursors: [SourceCursorRecord]
    var rootsExisted: Bool

    var commitsResults: Bool {
        guard status == .committed else { return false }
        switch failure {
        case nil, "sourcePartialTail", "sourceRollbackRebuild":
            return true
        default:
            return false
        }
    }

    func discardingUncommittedResults() -> ActivityScanPlan {
        guard !commitsResults else { return self }
        var copy = self
        copy.rebuildSourceKeys = []
        copy.facts = []
        copy.cursors = []
        return copy
    }
}

struct LocalTotals: Sendable, Equatable {
    var todayInput: Int64
    var todayOutput: Int64
    var todayCachedInput: Int64
    var weekInput: Int64
    var weekOutput: Int64
    var windowOutput: Int64

    var todayTokens: Int { saturatingInt(todayInput + todayOutput) }
    var weekTokens: Int { saturatingInt(weekInput + weekOutput) }

    func cacheHitRate(coverageComplete: Bool) -> Double? {
        guard coverageComplete, todayInput > 0 else { return nil }
        return Double(todayCachedInput) / Double(todayInput)
    }

    func tps(windowMinutes: Int) -> Double {
        Double(windowOutput) / Double(windowMinutes * 60)
    }

    private func saturatingInt(_ value: Int64) -> Int {
        if value > Int64(Int.max) { return Int.max }
        if value < 0 { return 0 }
        return Int(value)
    }
}
