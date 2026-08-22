import XCTest
@testable import UsageInk

final class ActivityStoreTests: XCTestCase {
    func testDatabaseSchemaPermissionsAndNoDerivedState() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 3, output: 1)]
        )
        let (_, observation) = ActivityFixtures.ingest(home: home, root: root, now: now)
        XCTAssertEqual(observation.todayTokens, 4)
        let db = root.appendingPathComponent("activity.sqlite")
        let attributes = try FileManager.default.attributesOfItem(atPath: db.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
        let excluded = try db.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true)
        let persistence = PersistenceStore(root: root)
        var state = ProductState.default
        state.localActivity = LocalActivitySourceRecord(
            lastSuccessfulObservationAt: 1_787_356_800,
            availability: .fresh,
            failure: nil
        )
        try persistence.save(state)
        let data = try Data(contentsOf: root.appendingPathComponent("state.json"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("todayTokens"))
        XCTAssertFalse(json.contains("cacheHitRate"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sources = try XCTUnwrap(object["sources"] as? [String: Any])
        let local = try XCTUnwrap(sources["localActivity"] as? [String: Any])
        XCTAssertEqual(Set(local.keys), ["availability", "failure", "lastSuccessfulObservationAt"])
        XCTAssertNil(local["todayTokens"])
        XCTAssertNil(local["weekTokens"])
        XCTAssertNil(local["cacheHitRate"])
        XCTAssertNil(local["tps"])
        switch persistence.load() {
        case .loaded(let loaded):
            XCTAssertEqual(loaded.localActivity.availability, .fresh)
            XCTAssertNil(loaded.preferences.customCodexPath)
        default:
            XCTFail("expected loaded state")
        }
    }

    func testPruneIsAtomicWithIngest() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let old = Date(timeIntervalSince1970: 1_787_356_800 - 9 * 24 * 60 * 60)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: iso(old), input: 100, output: 20)]
        )
        let (store, first) = ActivityFixtures.ingest(home: home, root: root, now: old)
        XCTAssertEqual(first.todayTokens, 120)
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [
                ActivityFixtures.tokenLine(timestamp: iso(old), input: 100, output: 20),
                ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 110, output: 21),
            ]
        )
        let second = store.ingest(
            codexHome: home,
            pollStart: now,
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 15,
            prior: first
        )
        XCTAssertEqual(second.todayTokens, 11)
        let facts = try store.loadFactsForTests()
        XCTAssertEqual(facts.count, 1)
        guard let fact = facts.first else {
            return XCTFail("missing fact")
        }
        XCTAssertEqual(fact.inputDelta, 10)
    }

    func testCorruptDatabaseIsRebuiltFromSources() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 7, output: 2)]
        )
        _ = ActivityFixtures.ingest(home: home, root: root, now: now)
        let db = root.appendingPathComponent("activity.sqlite")
        try Data("not a database".utf8).write(to: db)
        let rebuilt = ActivityStore(root: root)
        let observation = rebuilt.ingest(
            codexHome: home,
            pollStart: now,
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 15,
            prior: .unknown
        )
        XCTAssertEqual(observation.todayTokens, 9)
        XCTAssertEqual(observation.availability, .fresh)
    }

    func testStartupRehydrateUsesSqliteNotStateFreshness() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 2, output: 2)]
        )
        _ = ActivityFixtures.ingest(home: home, root: root, now: now)
        let store = ActivityStore(root: root)
        let rehydrated = store.rehydrate(
            now: now,
            calendar: ActivityFixtures.calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            tpsWindowMinutes: 15,
            lastSuccessfulObservationAt: nil,
            persistedAvailability: .unknown,
            persistedFailure: nil
        )
        XCTAssertEqual(rehydrated.todayTokens, 4)
        XCTAssertEqual(rehydrated.availability, .fresh)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
