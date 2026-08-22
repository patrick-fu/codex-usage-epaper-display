import XCTest
@testable import UsageInk

final class LocalActivityPresentationTests: XCTestCase {
    func testMenuAndFrameShowNormalizedTotalsWithoutSourceIdentity() throws {
        let observation = LocalActivityObservation(
            availability: .fresh,
            failure: nil,
            todayTokens: 1_500,
            weekTokens: 12_000,
            cacheHitRate: nil,
            tps: 0,
            coverageComplete: true
        )
        let english = StatusSummaryFormatter(language: .english).summary(
            account: SourceAvailability.unknown,
            local: observation,
            displayUnavailable: false
        )
        XCTAssertEqual(english, "— · Local Today 1.5K · Local This Week 12K")
        let chinese = StatusSummaryFormatter(language: .simplifiedChinese).summary(
            account: SourceAvailability.unknown,
            local: observation,
            displayUnavailable: false
        )
        XCTAssertEqual(chinese, "— · 本机今日 1.5K · 本机本周 12K")
        let model = QuotaFocusModelBuilder.build(DisplayFrameFixtures.input(local: observation))
        let today = model.ticker.first { $0.id == "local.today" } ?? model.hero
        XCTAssertEqual(today?.displayedValue, "1.5K")
        XCTAssertEqual(today?.label, "Local Today")
        XCTAssertFalse(today?.displayedValue.contains("rollout") ?? true)
        let frame = try DisplayFrameComposer.compose(DisplayFrameFixtures.input(local: observation))
        XCTAssertFalse(frame.fingerprint.contains(ActivityFixtures.uuidA))
        XCTAssertFalse(frame.fingerprint.contains("sessions"))
    }

    func testRuntimeSnapshotPublishesLocalObservationFromSyntheticSources() throws {
        let home = try ActivityFixtures.makeHome()
        let root = try ActivityFixtures.makeStoreRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: root) }
        try ActivityFixtures.writeRollout(
            home: home,
            layer: .sessions,
            basename: ActivityFixtures.rolloutName(),
            lines: [ActivityFixtures.tokenLine(timestamp: "2026-08-22T00:00:00.000Z", input: 8, output: 2)]
        )
        let now = Date(timeIntervalSince1970: 1_787_356_800)
        let started = expectation(description: "start")
        let box = PresentationSnapshotBox()
        let runtime = UsageInkRuntime(
            language: .english,
            store: PersistenceStore(root: root),
            activityStore: ActivityStore(root: root),
            codexHome: home,
            now: { now },
            timeZone: TimeZone(secondsFromGMT: 0)!
        ) { snapshot in
            box.snapshot = snapshot
            started.fulfill()
        }
        runtime.start()
        wait(for: [started], timeout: 2.0)
        XCTAssertEqual(box.snapshot?.localActivity.todayTokens, 10)
        XCTAssertEqual(box.snapshot?.statusSummary, "— · Local Today 10 · Local This Week 10")
        let model = QuotaFocusModelBuilder.build(
            DisplayFrameFixtures.input(local: box.snapshot?.localActivity ?? .unknown)
        )
        XCTAssertEqual(model.ticker.first { $0.id == "local.today" }?.displayedValue ?? model.hero?.displayedValue, "10")
        XCTAssertFalse(box.snapshot?.statusSummary.contains(ActivityFixtures.uuidA) ?? false)
        XCTAssertFalse(box.snapshot?.statusSummary.contains("jsonl") ?? false)
    }

    func testCacheAndTPSLabelsAndValuesRenderHonestly() {
        var preferences = DisplayPreferences.default
        preferences.modules.cache = true
        preferences.modules.tps = true
        let complete = LocalActivityObservation(
            availability: .fresh,
            failure: nil,
            todayTokens: 10,
            weekTokens: 10,
            cacheHitRate: 0,
            tps: 0,
            coverageComplete: true
        )
        let quota = QuotaFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, local: complete)
        )
        XCTAssertEqual(quota.ticker.first { $0.id == "local.cache" }?.label, "Cache hit rate")
        XCTAssertEqual(quota.ticker.first { $0.id == "local.cache" }?.displayedValue, "0%")
        XCTAssertEqual(quota.ticker.first { $0.id == "local.tps" }?.label, "TPS")
        XCTAssertEqual(quota.ticker.first { $0.id == "local.tps" }?.displayedValue, "0.0")
        XCTAssertEqual(quota.ticker.first { $0.id == "local.tps" }?.semanticValue, "0.0")

        let chinese = QuotaFocusModelBuilder.build(
            DisplayFrameFixtures.input(
                preferences: preferences,
                local: complete,
                preferredLanguages: ["zh-Hans"]
            )
        )
        XCTAssertEqual(chinese.ticker.first { $0.id == "local.cache" }?.label, "缓存命中率")
        XCTAssertEqual(chinese.ticker.first { $0.id == "local.tps" }?.label, "TPS")

        let unknown = LocalActivityObservation.unknown
        let missing = QuotaFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, local: unknown)
        )
        XCTAssertEqual(missing.ticker.first { $0.id == "local.cache" }?.displayedValue, DisplayCopy.emDash)
        XCTAssertEqual(missing.ticker.first { $0.id == "local.tps" }?.displayedValue, DisplayCopy.emDash)
        XCTAssertNil(missing.ticker.first { $0.id == "local.cache" }?.semanticValue)
        XCTAssertNil(missing.ticker.first { $0.id == "local.tps" }?.semanticValue)
        XCTAssertNotEqual(missing.ticker.first { $0.id == "local.tps" }?.displayedValue, "0.0")
        XCTAssertNotEqual(missing.ticker.first { $0.id == "local.cache" }?.displayedValue, "0%")

        let incomplete = LocalActivityObservation(
            availability: .fresh,
            failure: "sourcePartialTail",
            todayTokens: 10,
            weekTokens: 10,
            cacheHitRate: 0,
            tps: 0.1,
            coverageComplete: false
        )
        let partial = QuotaFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, local: incomplete)
        )
        XCTAssertEqual(partial.ticker.first { $0.id == "local.cache" }?.displayedValue, DisplayCopy.emDash)
        XCTAssertEqual(partial.ticker.first { $0.id == "local.tps" }?.displayedValue, "0.1")
        XCTAssertEqual(partial.ticker.first { $0.id == "local.today" }?.displayedValue, "10")

        let outputOnly = LocalActivityObservation(
            availability: .fresh,
            failure: nil,
            todayTokens: 5,
            weekTokens: 5,
            cacheHitRate: nil,
            tps: 0,
            coverageComplete: true
        )
        let noInput = QuotaFocusModelBuilder.build(
            DisplayFrameFixtures.input(preferences: preferences, local: outputOnly)
        )
        XCTAssertEqual(noInput.ticker.first { $0.id == "local.cache" }?.displayedValue, DisplayCopy.emDash)
        XCTAssertNotEqual(noInput.ticker.first { $0.id == "local.cache" }?.displayedValue, "0%")
        XCTAssertEqual(noInput.ticker.first { $0.id == "local.tps" }?.displayedValue, "0.0")
        XCTAssertEqual(noInput.ticker.first { $0.id == "local.today" }?.displayedValue, "5")
    }

    func testCompleteZeroIsNotUnknownCopy() {
        let zero = LocalActivityObservation(
            availability: .fresh,
            failure: nil,
            todayTokens: 0,
            weekTokens: 0,
            cacheHitRate: nil,
            tps: 0,
            coverageComplete: true
        )
        XCTAssertEqual(
            StatusSummaryFormatter(language: .english).summary(account: SourceAvailability.unknown, local: zero, displayUnavailable: false),
            "— · Local Today 0 · Local This Week 0"
        )
        XCTAssertEqual(
            StatusSummaryFormatter(language: .english).summary(account: SourceAvailability.unknown, local: LocalActivityObservation.unknown, displayUnavailable: false),
            "— · Local activity unknown"
        )
    }
}

private final class PresentationSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: RuntimeSnapshot?
    var snapshot: RuntimeSnapshot? {
        get { lock.lock(); defer { lock.unlock() }; return _snapshot }
        set { lock.lock(); _snapshot = newValue; lock.unlock() }
    }
}
