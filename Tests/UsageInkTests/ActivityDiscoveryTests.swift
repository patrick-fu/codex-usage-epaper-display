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
        XCTAssertEqual(observation.todayTokens, 22)
        XCTAssertEqual(observation.coverageComplete, false)
        XCTAssertEqual(observation.failure, "sourceUnreadable")
        XCTAssertFalse((try ActivityStore(root: root).loadFactsForTests()).contains { $0.sourceKey != ActivityFixtures.sourceKeyA })
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
        XCTAssertTrue(observation.coverageComplete)
        XCTAssertNil(observation.failure)
    }
}
