import XCTest
@testable import UsageInk

final class LocalActivityObservationTests: XCTestCase {
    func testTodayAndWeekUseMacCalendarMondayAndCountInputPlusOutputOnce() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = Date(timeIntervalSince1970: 1_787_421_600) // 2026-08-22 18:00 UTC / 11:00 PDT Saturday
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [
                ActivityFixtures.tokenLine(timestamp: "2026-08-17T20:00:00.000Z", input: 10, cached: 4, output: 6, reasoning: 2),
                ActivityFixtures.tokenLine(timestamp: "2026-08-22T16:00:00.000Z", input: 13, cached: 5, output: 8, reasoning: 2),
            ]
        )
        let (_, observation) = ActivityFixtures.ingest(home: home, root: root, now: now, timeZone: timeZone)
        XCTAssertEqual(observation.weekTokens, 21)
        XCTAssertEqual(observation.todayTokens, 5)
        XCTAssertEqual(observation.cacheHitRate ?? -1, 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertTrue(observation.coverageComplete)
    }

    func testTimezoneChangeRebinsTheSameFacts() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800) // 2026-08-22 00:00 UTC
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-21T22:00:00.000Z", input: 5, output: 5)]
        )
        let (store, utc) = ActivityFixtures.ingest(
            home: home,
            root: root,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(utc.todayTokens, 0)
        XCTAssertEqual(utc.weekTokens, 10)
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let shifted = store.rehydrate(
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: shanghai),
            timeZone: shanghai,
            tpsWindowMinutes: 15,
            lastSuccessfulObservationAt: Int(now.timeIntervalSince1970),
            persistedAvailability: .fresh,
            persistedFailure: nil
        )
        XCTAssertEqual(shifted.todayTokens, 10)
        XCTAssertEqual(shifted.weekTokens, 10)
    }

    func testDSTBoundaryKeepsFactsOnTheLocalDay() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = Date(timeIntervalSince1970: 1_773_007_200) // 2026-03-08 22:00 UTC / 15:00 PDT
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [
                ActivityFixtures.tokenLine(timestamp: "2026-03-08T08:30:00.000Z", input: 1, output: 1),
                ActivityFixtures.tokenLine(timestamp: "2026-03-08T10:30:00.000Z", input: 4, output: 2),
            ]
        )
        let (_, observation) = ActivityFixtures.ingest(home: home, root: root, now: now, timeZone: timeZone)
        XCTAssertEqual(observation.todayTokens, 6)
    }

    func testUnknownStaleUnavailableAndPartialAreDistinctFromCompleteZero() throws {
        XCTAssertNil(LocalActivityObservation.unknown.todayTokens)
        XCTAssertEqual(LocalActivityObservation.unknown.availability, .unknown)
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let (_, zero) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(zero.todayTokens, 0)
        XCTAssertEqual(zero.availability, .fresh)
        XCTAssertTrue(zero.coverageComplete)
        XCTAssertEqual(
            LocalActivityMetrics.availability(
                lastSuccessfulObservationAt: Int(now.timeIntervalSince1970) - 20 * 60,
                now: now
            ),
            .stale
        )
        XCTAssertEqual(
            LocalActivityMetrics.availability(
                lastSuccessfulObservationAt: Int(now.timeIntervalSince1970) - 19 * 60,
                now: now
            ),
            .fresh
        )
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 1, output: 0)],
            incompleteTail: "{not-complete"
        )
        let (_, partial) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(partial.todayTokens, 1)
        XCTAssertEqual(partial.coverageComplete, false)
        XCTAssertEqual(partial.failure, "sourcePartialTail")
        XCTAssertNotEqual(partial.availability, .unknown)
    }

    func testMissingIsolatedRootsStayUnknown() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageink-missing-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let (_, observation) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(observation.availability, .unknown)
        XCTAssertNil(observation.todayTokens)
        XCTAssertNil(observation.weekTokens)
        XCTAssertNotEqual(observation.availability, .fresh)
    }

    func testTimeoutKeepsPriorObservationTime() {
        let prior = LocalActivitySourceRecord(
            lastSuccessfulObservationAt: 1_787_356_800,
            availability: .fresh,
            failure: nil
        )
        let timeout = LocalActivityObservation(
            availability: .fresh,
            failure: "sourceScanTimeout",
            todayTokens: 33,
            weekTokens: 33,
            cacheHitRate: nil,
            tps: 0,
            coverageComplete: false
        )
        let later = Date(timeIntervalSince1970: 1_787_356_800 + 600)
        let retained = LocalActivitySourceRecord.capturing(
            observation: timeout,
            at: later,
            prior: prior
        )
        XCTAssertEqual(retained.lastSuccessfulObservationAt, 1_787_356_800)
        XCTAssertEqual(retained.failure, "sourceScanTimeout")
        let partial = LocalActivityObservation(
            availability: .fresh,
            failure: "sourcePartialTail",
            todayTokens: 33,
            weekTokens: 33,
            cacheHitRate: nil,
            tps: 0,
            coverageComplete: false
        )
        let committed = LocalActivitySourceRecord.capturing(
            observation: partial,
            at: later,
            prior: prior
        )
        XCTAssertEqual(committed.lastSuccessfulObservationAt, 1_787_356_800 + 600)
        let unreadable = LocalActivityObservation(
            availability: .fresh,
            failure: "sourceUnreadable",
            todayTokens: 33,
            weekTokens: 33,
            cacheHitRate: nil,
            tps: 0,
            coverageComplete: false
        )
        let blocked = LocalActivitySourceRecord.capturing(
            observation: unreadable,
            at: later,
            prior: prior
        )
        XCTAssertEqual(blocked.lastSuccessfulObservationAt, 1_787_356_800)
        XCTAssertEqual(blocked.failure, "sourceUnreadable")
        let malformed = LocalActivityObservation(
            availability: .fresh,
            failure: "sourceMalformed",
            todayTokens: 33,
            weekTokens: 33,
            cacheHitRate: nil,
            tps: 0,
            coverageComplete: false
        )
        let malformedRecord = LocalActivitySourceRecord.capturing(
            observation: malformed,
            at: later,
            prior: prior
        )
        XCTAssertEqual(malformedRecord.lastSuccessfulObservationAt, 1_787_356_800)
    }
}
