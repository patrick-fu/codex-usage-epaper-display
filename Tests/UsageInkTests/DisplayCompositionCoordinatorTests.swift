import XCTest
@testable import UsageInk

final class DisplayCompositionCoordinatorTests: XCTestCase {
    func testIdleSavesCoalesceToALaterAutomaticRequestWithoutComposing() {
        var session = DisplayCompositionSession()
        let original = DisplayFrameFixtures.input()
        var first = DisplayPreferences.default
        first.displayStyle = .balanced
        DisplayCompositionCoordinator.applyConfiguration(
            session: &session,
            preferences: first,
            fallbackInput: original
        )
        XCTAssertNil(session.inFlightFrame)
        XCTAssertEqual(session.pendingAutomatic?.preferences.displayStyle, .balanced)
        XCTAssertEqual(session.pendingAutomatic?.account, original.account)

        var second = first
        second.displayStyle = .activityFocus
        second.title = "IDLE LATEST"
        DisplayCompositionCoordinator.applyConfiguration(
            session: &session,
            preferences: second,
            fallbackInput: original
        )
        XCTAssertNil(session.inFlightFrame)
        XCTAssertEqual(session.pendingAutomatic?.preferences.displayStyle, .activityFocus)
        XCTAssertEqual(session.pendingAutomatic?.preferences.title, "IDLE LATEST")
        XCTAssertEqual(session.pendingAutomatic?.localActivity, original.localActivity)
    }

    func testInFlightFrameIsNotMutatedByLaterConfigurationChanges() throws {
        var session = DisplayCompositionSession()
        let original = DisplayFrameFixtures.input()
        let frame = try DisplayCompositionCoordinator.beginInFlight(session: &session, input: original)
        XCTAssertEqual(session.inFlightFrame, frame)
        XCTAssertEqual(session.inFlightInput, original)

        var next = DisplayPreferences.default
        next.displayStyle = .balanced
        next.title = "NEW TITLE"
        DisplayCompositionCoordinator.applyConfiguration(session: &session, preferences: next)
        DisplayCompositionCoordinator.applyConfiguration(session: &session, preferences: next)

        XCTAssertEqual(session.inFlightFrame, frame)
        XCTAssertEqual(session.inFlightFrame?.fingerprint, frame.fingerprint)
        XCTAssertEqual(session.inFlightInput, original)
        XCTAssertEqual(session.pendingAutomatic?.preferences, next)
        XCTAssertEqual(session.pendingAutomatic?.account, original.account)
        XCTAssertEqual(session.pendingAutomatic?.composedAt, original.composedAt)
    }

    func testMultipleSavesKeepLatestPreferencesForTheNextAutomaticRequest() throws {
        var session = DisplayCompositionSession()
        var first = DisplayPreferences.default
        first.displayStyle = .balanced
        var second = first
        second.displayStyle = .activityFocus
        second.title = "LATEST"
        let original = DisplayFrameFixtures.input()
        _ = try DisplayCompositionCoordinator.beginInFlight(session: &session, input: original)
        DisplayCompositionCoordinator.applyConfiguration(session: &session, preferences: first)
        DisplayCompositionCoordinator.applyConfiguration(session: &session, preferences: second)

        let pending = DisplayCompositionCoordinator.finishInFlight(session: &session)
        XCTAssertNil(session.inFlightFrame)
        XCTAssertNil(session.pendingAutomatic)
        XCTAssertEqual(pending?.preferences.displayStyle, .activityFocus)
        XCTAssertEqual(pending?.preferences.title, "LATEST")
        XCTAssertEqual(pending?.localActivity, original.localActivity)

        let nextFrame = try DisplayFrameComposer.compose(try XCTUnwrap(pending))
        XCTAssertNotEqual(nextFrame.fingerprint, try DisplayFrameComposer.compose(original).fingerprint)
        XCTAssertEqual(
            nextFrame.fingerprint,
            try DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: second)).fingerprint
        )
    }
}

final class DisplayCompositionRuntimeTests: XCTestCase {
    func testRuntimeSavesCoalesceWithoutMutatingTheInFlightFrame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let box = CompositionSnapshotBox()
        let started = expectation(description: "start")
        let saved = expectation(description: "saved")
        saved.expectedFulfillmentCount = 2
        let runtime = UsageInkRuntime(language: .english, store: PersistenceStore(root: root)) { snapshot in
            let count = box.append(snapshot)
            if count == 1 {
                started.fulfill()
            } else {
                saved.fulfill()
            }
        }
        runtime.start()
        wait(for: [started], timeout: 1.0)

        let original = DisplayFrameFixtures.input()
        let frozen = try runtime.beginInFlightComposition(original)
        var first = DisplayPreferences.default
        first.displayStyle = .balanced
        runtime.submit(.savePreferences(first))
        var second = first
        second.displayStyle = .activityFocus
        second.title = "LATEST"
        runtime.submit(.savePreferences(second))
        wait(for: [saved], timeout: 1.0)

        let stillFrozen = try XCTUnwrap(runtime.inFlightFrame)
        XCTAssertEqual(stillFrozen, frozen)
        XCTAssertEqual(runtime.pendingAutomaticInput?.preferences.title, "LATEST")
        XCTAssertEqual(runtime.pendingAutomaticInput?.preferences.displayStyle, .activityFocus)

        let pending = try XCTUnwrap(runtime.finishInFlightComposition())
        XCTAssertNil(runtime.inFlightFrame)
        XCTAssertEqual(pending.preferences.title, "LATEST")
        let next = try DisplayFrameComposer.compose(pending)
        XCTAssertEqual(
            next.fingerprint,
            try DisplayFrameComposer.compose(DisplayFrameFixtures.input(preferences: second)).fingerprint
        )
    }

    func testIdleRuntimeSavesEnqueueLatestAutomaticRequest() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let box = CompositionSnapshotBox()
        let started = expectation(description: "start")
        let saved = expectation(description: "saved")
        saved.expectedFulfillmentCount = 2
        let runtime = UsageInkRuntime(language: .english, store: PersistenceStore(root: root)) { snapshot in
            let count = box.append(snapshot)
            if count == 1 {
                started.fulfill()
            } else {
                saved.fulfill()
            }
        }
        runtime.start()
        wait(for: [started], timeout: 1.0)

        var first = DisplayPreferences.default
        first.displayStyle = .balanced
        runtime.submit(.savePreferences(first))
        var second = first
        second.displayStyle = .activityFocus
        second.title = "IDLE LATEST"
        runtime.submit(.savePreferences(second))
        wait(for: [saved], timeout: 1.0)

        XCTAssertNil(runtime.inFlightFrame)
        XCTAssertEqual(runtime.pendingAutomaticInput?.preferences.displayStyle, .activityFocus)
        XCTAssertEqual(runtime.pendingAutomaticInput?.preferences.title, "IDLE LATEST")
    }
}

private final class CompositionSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [RuntimeSnapshot] = []

    func append(_ snapshot: RuntimeSnapshot) -> Int {
        lock.lock()
        defer { lock.unlock() }
        snapshots.append(snapshot)
        return snapshots.count
    }
}
