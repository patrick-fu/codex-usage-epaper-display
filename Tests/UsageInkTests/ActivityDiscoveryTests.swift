import Darwin
import XCTest
@testable import UsageInk

final class ActivityDiscoveryTests: XCTestCase {
    func testSessionsWinOverArchiveAndLexicographicallyGreatestBasenameWins() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let ts = "2026-08-22T00:00:00.000Z"
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .archivedSessions,
            basename: ActivityFixtures.rolloutName(timestamp: "2026-08-22T00-00-00-", uuid: ActivityFixtures.uuidA),
            lines: [ActivityFixtures.tokenLine(timestamp: ts, input: 50, output: 5)]
        )
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(timestamp: "2026-08-21T00-00-00-", uuid: ActivityFixtures.uuidA),
            lines: [ActivityFixtures.tokenLine(timestamp: ts, input: 10, output: 1)]
        )
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(timestamp: "2026-08-23T00-00-00-", uuid: ActivityFixtures.uuidA, revert: true),
            lines: [ActivityFixtures.tokenLine(timestamp: ts, input: 80, output: 8)]
        )
        let (_, observation) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(observation.todayTokens, 88)
        XCTAssertEqual(observation.weekTokens, 88)
        XCTAssertEqual(observation.availability, .fresh)
        XCTAssertTrue(observation.coverageComplete)
        XCTAssertEqual(observation.cacheHitRate, 0)
        let store = ActivityStore(root: root)
        XCTAssertEqual(try store.loadCursorsForTests().count, 1)
        XCTAssertEqual(try store.loadFactsForTests().count, 1)
    }

    func testSymlinkAndHardlinkAreRejectedAndDoNotFollow() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(uuid: ActivityFixtures.uuidA),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 20, output: 2)]
        )
        let other = try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(timestamp: "2026-08-22T01-00-00-", uuid: ActivityFixtures.uuidB),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 9, output: 1)]
        )
        let symlinkURL = home.appendingPathComponent("sessions")
            .appendingPathComponent(ActivityFixtures.rolloutName(timestamp: "2026-08-22T03-00-00-", uuid: ActivityFixtures.uuidB))
        XCTAssertEqual(other.path.withCString { src in symlinkURL.path.withCString { dst in symlink(src, dst) } }, 0)
        let hardURL = home.appendingPathComponent("sessions")
            .appendingPathComponent(ActivityFixtures.rolloutName(timestamp: "2026-08-22T04-00-00-", uuid: "cccccccc-dddd-eeee-ffff-000000000000"))
        XCTAssertEqual(other.path.withCString { src in hardURL.path.withCString { dst in Darwin.link(src, dst) } }, 0)
        let (_, observation) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertNil(observation.todayTokens)
        XCTAssertNil(observation.cacheHitRate)
        XCTAssertEqual(observation.coverageComplete, false)
        XCTAssertEqual(observation.failure, "sourceUnreadable")
        XCTAssertEqual(try ActivityStore(root: root).loadFactsForTests().count, 0)
    }

    func testCoverageRejectionRollsBackAndRetainsPriorTokens() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(uuid: ActivityFixtures.uuidA),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 20, output: 2)]
        )
        let (store, first) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(first.todayTokens, 22)
        let extra = try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(timestamp: "2026-08-22T01-00-00-", uuid: ActivityFixtures.uuidB),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 9, output: 1)]
        )
        let symlinkURL = home.appendingPathComponent("sessions")
            .appendingPathComponent(ActivityFixtures.rolloutName(timestamp: "2026-08-22T03-00-00-", uuid: ActivityFixtures.uuidB))
        XCTAssertEqual(extra.path.withCString { src in symlinkURL.path.withCString { dst in symlink(src, dst) } }, 0)
        let rejected = store.ingest(
            codexHome: home,
            pollStart: now,
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 15,
            prior: first
        )
        XCTAssertEqual(rejected.todayTokens, 22)
        XCTAssertEqual(rejected.failure, "sourceUnreadable")
        XCTAssertEqual(rejected.coverageComplete, false)
        XCTAssertNil(rejected.cacheHitRate)
        XCTAssertEqual(rejected.tps, first.tps)
        XCTAssertEqual(try store.loadFactsForTests().count, 1)
        XCTAssertEqual(try store.loadFactsForTests().first?.sourceKey, ActivityFixtures.sourceKeyA)
    }

    func testPartialTailThenBlockingRejectionRollsBackPriorFactsAndCursors() throws {
        try assertMixedOrderRejectionRetainsPrior(
            firstSource: .partialTail(uuid: ActivityFixtures.uuidB),
            secondSource: .malformed(uuid: ActivityFixtures.uuidA)
        )
    }

    func testBlockingThenPartialTailRejectionRollsBackPriorFactsAndCursors() throws {
        try assertMixedOrderRejectionRetainsPrior(
            firstSource: .malformed(uuid: ActivityFixtures.uuidB),
            secondSource: .partialTail(uuid: ActivityFixtures.uuidA)
        )
    }

    private enum MixedSource {
        case partialTail(uuid: String)
        case malformed(uuid: String)
    }

    private func assertMixedOrderRejectionRetainsPrior(
        firstSource: MixedSource,
        secondSource: MixedSource
    ) throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(uuid: ActivityFixtures.uuidA),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 20, output: 2)]
        )
        let (store, first) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(first.todayTokens, 22)
        let priorFacts = try store.loadFactsForTests()
        let priorCursors = try store.loadCursorsForTests().sorted { $0.sourceKey < $1.sourceKey }
        XCTAssertEqual(priorFacts.count, 1)
        XCTAssertEqual(priorFacts.first?.sourceKey, ActivityFixtures.sourceKeyA)
        XCTAssertEqual(priorCursors.count, 1)
        XCTAssertEqual(priorCursors.first?.lastSeenAt, Int(now.timeIntervalSince1970.rounded(.towardZero)))

        try writeMixedSource(firstSource, home: home)
        try writeMixedSource(secondSource, home: home)
        let rejected = store.ingest(
            codexHome: home,
            pollStart: now,
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 15,
            prior: first
        )
        let retainedCursors = try store.loadCursorsForTests().sorted { $0.sourceKey < $1.sourceKey }
        XCTAssertEqual(rejected.failure, "sourceMalformed")
        XCTAssertEqual(rejected.todayTokens, 22)
        XCTAssertEqual(rejected.coverageComplete, false)
        XCTAssertEqual(try store.loadFactsForTests(), priorFacts)
        XCTAssertEqual(retainedCursors, priorCursors)
        XCTAssertEqual(retainedCursors.first?.newlineOffset, priorCursors.first?.newlineOffset)
        XCTAssertEqual(retainedCursors.first?.lastSeenAt, priorCursors.first?.lastSeenAt)
        XCTAssertEqual(retainedCursors.first?.sourceKey, ActivityFixtures.sourceKeyA)
    }

    private func writeMixedSource(_ source: MixedSource, home: URL) throws {
        switch source {
        case .partialTail(let uuid):
            let timestamp = uuid == ActivityFixtures.uuidA ? "2026-08-22T00-00-00-" : "2026-08-22T01-00-00-"
            let lines = uuid == ActivityFixtures.uuidA
                ? [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 20, output: 2)]
                : [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 9, output: 1)]
            try ActivityFixtures.writeRollout(
                home: home,
                layer: .sessions,
                basename: ActivityFixtures.rolloutName(timestamp: timestamp, uuid: uuid),
                lines: lines,
                incompleteTail: "{\"timestamp\":\"2026-08-22T00:03:00.000Z\",\"type\":\"event_msg\""
            )
        case .malformed(let uuid):
            let timestamp = uuid == ActivityFixtures.uuidA ? "2026-08-22T00-00-00-" : "2026-08-22T01-00-00-"
            try ActivityFixtures.writeRollout(
                home: home,
                layer: .sessions,
                basename: ActivityFixtures.rolloutName(timestamp: timestamp, uuid: uuid),
                lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T01:00:00.000Z", input: 99, output: 9)]
            )
        }
    }

    func testByteBudgetIsChargedBeforeReadAndIncludesChecksum() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 30, output: 3)]
        )
        let (_, observation) = ActivityFixtures.ingest(
            home: home,
            root: root,
            now: now,
            limits: ActivityScanLimits(maxWallTime: 8, maxFiles: 512, maxBytes: 16)
        )
        XCTAssertEqual(observation.failure, "sourceScanTimeout")
        XCTAssertNil(observation.todayTokens)
        XCTAssertEqual(try ActivityStore(root: root).loadFactsForTests().count, 0)
    }

    func testBudgetExhaustionRollsBackAndRetainsPriorObservation() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 30, output: 3)]
        )
        let (store, first) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(first.todayTokens, 33)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(timestamp: "2026-08-24T00-00-00-", uuid: ActivityFixtures.uuidB),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 90, output: 9)]
        )
        let exhausted = store.ingest(
            codexHome: home,
            pollStart: now,
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 15,
            limits: ActivityScanLimits(maxWallTime: 8, maxFiles: 0, maxBytes: 64 * 1024 * 1024),
            prior: first
        )
        XCTAssertEqual(exhausted.failure, "sourceScanTimeout")
        XCTAssertEqual(exhausted.todayTokens, 33)
        XCTAssertEqual(try store.loadFactsForTests().count, 1)
    }

    func testEmptyExistingRootsAreCompleteZero() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let (_, observation) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(observation.availability, .fresh)
        XCTAssertEqual(observation.todayTokens, 0)
        XCTAssertEqual(observation.weekTokens, 0)
        XCTAssertEqual(observation.tps, 0)
        XCTAssertNil(observation.cacheHitRate)
        XCTAssertTrue(observation.coverageComplete)
        XCTAssertNil(observation.failure)
    }
}
