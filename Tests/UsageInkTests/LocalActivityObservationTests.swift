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

    func testCacheHitRateUsesTodayTokenWeightedCachedInputAndNeverZeroForUnavailable() throws {
        let totalsZeroInput = LocalTotals(
            todayInput: 0,
            todayOutput: 7,
            todayCachedInput: 0,
            weekInput: 0,
            weekOutput: 7,
            windowOutput: 0
        )
        XCTAssertNil(totalsZeroInput.cacheHitRate(coverageComplete: true))
        XCTAssertEqual(totalsZeroInput.todayTokens, 7)
        XCTAssertEqual(totalsZeroInput.tps(windowMinutes: 15), 0)

        let completeZeroCache = LocalTotals(
            todayInput: 8,
            todayOutput: 2,
            todayCachedInput: 0,
            weekInput: 8,
            weekOutput: 2,
            windowOutput: 2
        )
        XCTAssertEqual(completeZeroCache.cacheHitRate(coverageComplete: true), 0)
        XCTAssertNil(completeZeroCache.cacheHitRate(coverageComplete: false))

        let weighted = LocalTotals(
            todayInput: 13,
            todayOutput: 8,
            todayCachedInput: 5,
            weekInput: 13,
            weekOutput: 8,
            windowOutput: 90
        )
        XCTAssertEqual(weighted.cacheHitRate(coverageComplete: true) ?? -1, 5.0 / 13.0, accuracy: 1e-12)
        XCTAssertEqual(weighted.tps(windowMinutes: 15), 0.1)
        XCTAssertEqual(weighted.tps(windowMinutes: 3), 0.5)
        XCTAssertEqual(weighted.tps(windowMinutes: 60), 0.025)

        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 0, cached: 0, output: 5, reasoning: 2)]
        )
        let (_, observation) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(observation.todayTokens, 5)
        XCTAssertEqual(observation.tps, 5.0 / 900.0)
        XCTAssertNil(observation.cacheHitRate)
        XCTAssertTrue(observation.coverageComplete)
    }

    func testCompleteCachedZeroIsZeroPercentNotUnavailable() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 8, cached: 0, output: 2)]
        )
        let (_, observation) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(observation.cacheHitRate, 0)
        XCTAssertTrue(observation.coverageComplete)
        XCTAssertEqual(observation.todayTokens, 10)
    }

    func testTPSWindowsAreInclusiveAtPollStartAndDivideByFullElapsedSeconds() throws {
        let pollStart = 1_787_356_800 + 15 * 60
        XCTAssertEqual(
            LocalActivityMetrics.tpsRange(pollStart: Date(timeIntervalSince1970: TimeInterval(pollStart)), windowMinutes: 15),
            (pollStart - 900)...pollStart
        )
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: TimeInterval(pollStart))
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [
                ActivityFixtures.tokenLine(
                    timestamp: ActivityFixtures.isoUTC(pollStart - 900),
                    input: 10,
                    cached: 4,
                    output: 90,
                    reasoning: 12
                ),
                ActivityFixtures.tokenLine(
                    timestamp: ActivityFixtures.isoUTC(pollStart - 901),
                    input: 11,
                    cached: 4,
                    output: 190,
                    reasoning: 12
                ),
            ]
        )
        let (store, fifteen) = ActivityFixtures.ingest(home: home, root: root, now: now, tpsWindowMinutes: 15)
        XCTAssertEqual(fifteen.tps, 90.0 / 900.0)
        XCTAssertEqual(fifteen.cacheHitRate ?? -1, 4.0 / 10.0, accuracy: 1e-12)
        let three = store.rehydrate(
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 3,
            lastSuccessfulObservationAt: Int(now.timeIntervalSince1970),
            persistedAvailability: .fresh,
            persistedFailure: nil
        )
        XCTAssertEqual(three.tps, 0)
        let sixty = store.rehydrate(
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 60,
            lastSuccessfulObservationAt: Int(now.timeIntervalSince1970),
            persistedAvailability: .fresh,
            persistedFailure: nil
        )
        XCTAssertEqual(sixty.tps, 190.0 / 3600.0)
    }

    func testTPSIncludesExactBoundsAndExcludesFactsAfterPollStart() throws {
        let pollStart = 1_787_356_800 + 3 * 60
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: TimeInterval(pollStart))
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [
                ActivityFixtures.tokenLine(timestamp: ActivityFixtures.isoUTC(pollStart - 180), input: 1, output: 30),
                ActivityFixtures.tokenLine(timestamp: ActivityFixtures.isoUTC(pollStart), input: 2, output: 50),
                ActivityFixtures.tokenLine(timestamp: ActivityFixtures.isoUTC(pollStart + 1), input: 3, output: 80),
            ]
        )
        let (_, observation) = ActivityFixtures.ingest(home: home, root: root, now: now, tpsWindowMinutes: 3)
        XCTAssertEqual(observation.tps, 50.0 / 180.0)
        XCTAssertEqual(observation.todayTokens, 83)
        XCTAssertTrue(observation.coverageComplete)
    }

    func testMatchingCachedAliasesContributeToTodayCacheRate() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let line = """
        {"timestamp":"2026-08-22T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","total_token_usage":{"input_tokens":20,"cache_read_input_tokens":5,"cache_read_tokens":5,"output_tokens":1,"reasoning_output_tokens":0}}}
        """
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [line]
        )
        let (_, observation) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(observation.cacheHitRate ?? -1, 0.25, accuracy: 1e-12)
        XCTAssertEqual(observation.todayTokens, 21)
        XCTAssertTrue(observation.coverageComplete)
    }

    func testMalformedRetentionNilsCacheAndRequeriesTPSForCurrentWindow() throws {
        let pollStart = 1_787_356_800 + 15 * 60
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: TimeInterval(pollStart))
        let url = try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: ActivityFixtures.isoUTC(pollStart - 900), input: 10, cached: 4, output: 90)]
        )
        let (store, first) = ActivityFixtures.ingest(home: home, root: root, now: now, tpsWindowMinutes: 15)
        XCTAssertEqual(first.tps ?? -1, 90.0 / 900.0, accuracy: 1e-12)
        XCTAssertEqual(first.cacheHitRate ?? -1, 0.4, accuracy: 1e-12)
        try Data((ActivityFixtures.tokenLine(timestamp: ActivityFixtures.isoUTC(pollStart + 3600), input: 99, output: 9) + "\n").utf8).write(to: url)
        let rejected = store.ingest(
            codexHome: home,
            pollStart: now,
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 3,
            prior: first
        )
        XCTAssertEqual(rejected.failure, "sourceMalformed")
        XCTAssertEqual(rejected.todayTokens, 100)
        XCTAssertEqual(rejected.tps, 0)
        XCTAssertNil(rejected.cacheHitRate)
        XCTAssertEqual(rejected.coverageComplete, false)
        XCTAssertEqual(try store.loadFactsForTests().count, 1)
    }

    func testTimezoneChangeDoesNotChangeElapsedTPS() throws {
        let pollStart = 1_787_356_800 + 15 * 60
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: TimeInterval(pollStart))
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: ActivityFixtures.isoUTC(pollStart - 60), input: 2, output: 45)]
        )
        let (store, utc) = ActivityFixtures.ingest(
            home: home,
            root: root,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 15
        )
        let shanghai = store.rehydrate(
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(identifier: "Asia/Shanghai")!),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!,
            tpsWindowMinutes: 15,
            lastSuccessfulObservationAt: Int(now.timeIntervalSince1970),
            persistedAvailability: .fresh,
            persistedFailure: nil
        )
        XCTAssertEqual(utc.tps, 45.0 / 900.0)
        XCTAssertEqual(shanghai.tps, utc.tps)
    }
}
