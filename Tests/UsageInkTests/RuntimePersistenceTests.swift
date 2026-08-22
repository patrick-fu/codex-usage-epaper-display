import XCTest
@testable import UsageInk

final class RuntimePersistenceTests: XCTestCase {
    func testRestartRestoresPreferencesWithInvalidPanelTrustAndNoBLESession() throws {
        let root = try makeRoot()
        let store = PersistenceStore(root: root)
        var state = ProductState.default
        state.preferences.displayStyle = .activityFocus
        state.preferences.quotaOrder = .activityFirst
        state.preferences.tpsWindowMinutes = 60
        state.preferences.language = .english
        state.preferences.redThreshold = 50
        state.preferences.modules.cache = true
        state.setupDone = true
        state.refreshRecord = RefreshRecord(
            lastSucceededFingerprint: "abc",
            lastSuccessfulRefreshAt: 1_700_000_000
        )
        state.boundDisplay = BoundDisplayRecord(identifier: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", displayName: "Desk")
        try store.save(state)

        let box = SnapshotBox()
        let started = expectation(description: "start")
        let runtime = UsageInkRuntime(language: .english, store: store) { snapshot in
            box.snapshot = snapshot
            started.fulfill()
        }
        runtime.start()
        wait(for: [started], timeout: 1.0)

        let snapshot = try XCTUnwrap(box.snapshot)
        XCTAssertEqual(snapshot.preferences.displayStyle, .activityFocus)
        XCTAssertEqual(snapshot.preferences.quotaOrder, .activityFirst)
        XCTAssertEqual(snapshot.preferences.tpsWindowMinutes, 60)
        XCTAssertEqual(snapshot.preferences.language, .english)
        XCTAssertEqual(snapshot.preferences.redThreshold, 50)
        XCTAssertTrue(snapshot.preferences.modules.cache)
        XCTAssertEqual(snapshot.displayStyle, .activityFocus)
        XCTAssertEqual(snapshot.panelTrust, .invalid)
        XCTAssertFalse(snapshot.hasReadyWakeupConfiguration)
        XCTAssertEqual(snapshot.binding, .unbound)
        XCTAssertFalse(snapshot.showsFirstRunDisclosure)
        XCTAssertTrue(snapshot.isPersistenceWritable)
    }

    func testSavingPreferencesBatchSurvivesANewRuntime() throws {
        let root = try makeRoot()
        let store = PersistenceStore(root: root)
        let first = SnapshotBox()
        let started = expectation(description: "start")
        let saved = expectation(description: "saved")
        let runtime = UsageInkRuntime(language: .english, store: store) { snapshot in
            let count = first.append(snapshot)
            if count == 1 {
                started.fulfill()
            } else {
                saved.fulfill()
            }
        }
        runtime.start()
        wait(for: [started], timeout: 1.0)
        XCTAssertTrue(first.snapshot?.showsFirstRunDisclosure ?? false)
        XCTAssertEqual(first.snapshot?.panelTrust, .invalid)

        var preferences = DisplayPreferences.default
        preferences.displayStyle = .balanced
        preferences.title = "INK BOARD"
        preferences.dateFormat = .absolute
        preferences.redAccent = .always
        runtime.submit(.savePreferences(preferences))
        wait(for: [saved], timeout: 1.0)
        XCTAssertFalse(first.snapshot?.showsFirstRunDisclosure ?? true)

        let restarted = expectation(description: "restart")
        let secondBox = SnapshotBox()
        let second = UsageInkRuntime(language: .english, store: store) { snapshot in
            secondBox.snapshot = snapshot
            restarted.fulfill()
        }
        second.start()
        wait(for: [restarted], timeout: 1.0)
        XCTAssertEqual(secondBox.snapshot?.preferences.displayStyle, .balanced)
        XCTAssertEqual(secondBox.snapshot?.preferences.title, "INK BOARD")
        XCTAssertEqual(secondBox.snapshot?.preferences.dateFormat, .absolute)
        XCTAssertEqual(secondBox.snapshot?.preferences.redAccent, .always)
        XCTAssertEqual(secondBox.snapshot?.panelTrust, .invalid)
        XCTAssertFalse(secondBox.snapshot?.hasReadyWakeupConfiguration ?? true)
        XCTAssertEqual(secondBox.snapshot?.binding, .unbound)
        XCTAssertFalse(secondBox.snapshot?.showsFirstRunDisclosure ?? true)
    }

    func testMenuStyleChangePersists() throws {
        let root = try makeRoot()
        let store = PersistenceStore(root: root)
        let box = SnapshotBox()
        let started = expectation(description: "start")
        let changed = expectation(description: "changed")
        let runtime = UsageInkRuntime(language: .english, store: store) { snapshot in
            let count = box.append(snapshot)
            if count == 1 {
                started.fulfill()
            } else {
                changed.fulfill()
            }
        }
        runtime.start()
        wait(for: [started], timeout: 1.0)
        runtime.submit(.setDisplayStyle(.balanced))
        wait(for: [changed], timeout: 1.0)

        let restarted = expectation(description: "restart")
        let secondBox = SnapshotBox()
        UsageInkRuntime(language: .english, store: store) { snapshot in
            secondBox.snapshot = snapshot
            restarted.fulfill()
        }.start()
        wait(for: [restarted], timeout: 1.0)
        XCTAssertEqual(secondBox.snapshot?.displayStyle, .balanced)
        XCTAssertEqual(secondBox.snapshot?.panelTrust, .invalid)
    }

    func testUnsupportedSchemaDoesNotGetOverwrittenByPreferenceSave() throws {
        let root = try makeRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = "{\"schemaVersion\":9}"
        let url = root.appendingPathComponent("state.json")
        try Data(original.utf8).write(to: url)
        let store = PersistenceStore(root: root)
        let box = SnapshotBox()
        let started = expectation(description: "start")
        let saved = expectation(description: "saved")
        let runtime = UsageInkRuntime(language: .english, store: store) { snapshot in
            let count = box.append(snapshot)
            if count == 1 {
                started.fulfill()
            } else {
                saved.fulfill()
            }
        }
        runtime.start()
        wait(for: [started], timeout: 1.0)
        XCTAssertFalse(box.snapshot?.isPersistenceWritable ?? true)
        XCTAssertEqual(box.snapshot?.storageClassification, .stateVersionUnsupported)
        runtime.submit(.savePreferences(.default))
        wait(for: [saved], timeout: 1.0)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageink-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: RuntimeSnapshot?
    private var _count = 0

    var snapshot: RuntimeSnapshot? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _snapshot
        }
        set {
            lock.lock()
            _snapshot = newValue
            lock.unlock()
        }
    }

    func append(_ snapshot: RuntimeSnapshot) -> Int {
        lock.lock()
        defer { lock.unlock() }
        _snapshot = snapshot
        _count += 1
        return _count
    }
}
