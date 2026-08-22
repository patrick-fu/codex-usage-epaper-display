import XCTest
@testable import UsageInk

final class ActivityIngestionTests: XCTestCase {
    func testAllowlistIgnoresContentAndUsesTotalUsageNotLastUsage() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let content = "{\"timestamp\":\"2026-08-22T00:00:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"content\":\"secret prompt\"}}"
        let session = "{\"timestamp\":\"2026-08-22T00:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"sess-1\",\"model\":\"gpt\"}}"
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [
                content,
                session,
                ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 40, cached: 8, output: 12, reasoning: 3, lastInput: 999, lastOutput: 999),
            ]
        )
        let (store, observation) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(observation.todayTokens, 52, "failure=\(observation.failure ?? "nil") availability=\(observation.availability)")
        let facts = try store.loadFactsForTests()
        XCTAssertEqual(facts.count, 1)
        guard let fact = facts.first else {
            return XCTFail("missing fact")
        }
        XCTAssertEqual(fact.inputDelta, 40)
        XCTAssertEqual(fact.cachedInputDelta, 8)
        XCTAssertEqual(fact.outputDelta, 12)
        XCTAssertEqual(fact.reasoningDelta, 3)
        let sqlite = try Data(contentsOf: root.appendingPathComponent("activity.sqlite"))
        XCTAssertNil(String(data: sqlite, encoding: .utf8)?.contains("secret prompt"))
        XCTAssertFalse(sqlite.contains(Data("sess-1".utf8)))
        XCTAssertFalse(sqlite.contains(Data("rollout-".utf8)))
        XCTAssertFalse(sqlite.contains(Data(ActivityFixtures.uuidA.utf8)))
    }

    func testEqualWatermarkInsertsNothingAndLowerTriggersRebuild() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let url = try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 10, output: 2)]
        )
        let (store, first) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(first.todayTokens, 12)
        try Data((try String(contentsOf: url, encoding: .utf8)
            + ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:01:00.000Z", input: 10, output: 2)
            + "\n").utf8).write(to: url)
        let equal = store.ingest(
            codexHome: home,
            pollStart: now,
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 15,
            prior: first
        )
        XCTAssertEqual(equal.todayTokens, 12)
        XCTAssertEqual(try store.loadFactsForTests().count, 1)
        try Data((ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:02:00.000Z", input: 4, output: 1) + "\n").utf8).write(to: url)
        let rebuilt = store.ingest(
            codexHome: home,
            pollStart: now,
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 15,
            prior: equal
        )
        XCTAssertEqual(rebuilt.todayTokens, 5)
        let rebuiltFacts = try store.loadFactsForTests()
        XCTAssertEqual(rebuiltFacts.count, 1)
        XCTAssertEqual(rebuiltFacts.first?.inputDelta, 4)
    }

    func testPartialTailDoesNotAdvanceCursorAndLeavesTodayFromCommittedLines() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 6, output: 1)],
            incompleteTail: "{\"timestamp\":\"2026-08-22T00:03:00.000Z\",\"type\":\"event_msg\""
        )
        let (store, observation) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(observation.todayTokens, 7)
        XCTAssertEqual(observation.coverageComplete, false)
        XCTAssertEqual(observation.failure, "sourcePartialTail")
        XCTAssertNil(observation.cacheHitRate)
        let cursors = try store.loadCursorsForTests()
        guard let cursor = cursors.first else {
            return XCTFail("missing cursor")
        }
        XCTAssertGreaterThan(cursor.newlineOffset, 0)
        XCTAssertLessThan(cursor.newlineOffset, cursor.sizeBytes)
    }

    func testInvalidTimestampAndAliasMismatchAreMalformed() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let mismatch = "{\"timestamp\":\"2026-08-22T00:00:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"total_token_usage\":{\"input_tokens\":8,\"cached_input_tokens\":1,\"cache_read_tokens\":2,\"output_tokens\":1,\"reasoning_output_tokens\":0}}}"
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [mismatch]
        )
        let (_, observation) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(observation.coverageComplete, false)
        XCTAssertEqual(observation.failure, "sourceMalformed")
        XCTAssertNil(observation.todayTokens)
        XCTAssertEqual(try ActivityStore(root: root).loadFactsForTests().count, 0)
    }

    func testFutureTimestampBeyondFiveMinutesIsRejected() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T01:00:00.000Z", input: 9, output: 1)]
        )
        let (_, observation) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(observation.failure, "sourceMalformed")
        XCTAssertNil(observation.todayTokens)
        XCTAssertEqual(observation.coverageComplete, false)
        XCTAssertEqual(try ActivityStore(root: root).loadFactsForTests().count, 0)
    }

    func testMalformedScanRetainsPriorTokensAndDoesNotApply() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let url = try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 10, output: 2)]
        )
        let (store, first) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(first.todayTokens, 12)
        try Data((ActivityFixtures.tokenLine(timestamp: "2026-08-22T01:00:00.000Z", input: 99, output: 9) + "\n").utf8).write(to: url)
        let rejected = store.ingest(
            codexHome: home,
            pollStart: now,
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 15,
            prior: first
        )
        XCTAssertEqual(rejected.todayTokens, 12)
        XCTAssertEqual(rejected.failure, "sourceMalformed")
        XCTAssertNil(rejected.cacheHitRate)
        XCTAssertEqual(rejected.tps, first.tps)
        XCTAssertEqual(rejected.coverageComplete, false)
        XCTAssertEqual(try store.loadFactsForTests().count, 1)
        XCTAssertEqual(try store.loadFactsForTests().first?.inputDelta, 10)
    }

    func testActiveThenArchiveDoesNotDuplicateFacts() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let basename = ActivityFixtures.rolloutName()
        let url = try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: basename,
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 15, output: 5)]
        )
        let (store, first) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(first.todayTokens, 20)
        let archived = home.appendingPathComponent("archived_sessions").appendingPathComponent(basename)
        try FileManager.default.moveItem(at: url, to: archived)
        let second = store.ingest(
            codexHome: home,
            pollStart: now,
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 15,
            prior: first
        )
        XCTAssertEqual(second.todayTokens, 20)
        XCTAssertEqual(try store.loadFactsForTests().count, 1)
    }
}
