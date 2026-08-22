import XCTest
@testable import UsageInk

final class PersistenceStoreTests: XCTestCase {
    func testSaveCreatesAllowlistedStateWithRequiredPermissions() throws {
        let root = try makeRoot()
        let store = PersistenceStore(root: root)
        var state = ProductState.default
        state.preferences.displayStyle = .balanced
        state.preferences.title = "  Desk\nTitle  "
        try store.save(state)

        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o700)
        XCTAssertEqual(try backupExcluded(root), true)

        let stateURL = root.appendingPathComponent("state.json")
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        XCTAssertEqual(fileAttributes[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertEqual(try backupExcluded(stateURL), true)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), [
            "schemaVersion", "setupDone", "boundDisplay", "preferences", "sources", "refreshRecord",
        ])
        let preferences = try XCTUnwrap(json["preferences"] as? [String: Any])
        XCTAssertEqual(Set(preferences.keys), [
            "displayStyle", "modules", "quotaOrder", "title", "tpsWindowMinutes",
            "dateFormat", "redAccent", "redThreshold", "language", "customCodexPath",
        ])
        XCTAssertEqual(preferences["title"] as? String, "DeskTitle")
        XCTAssertTrue(json["boundDisplay"] is NSNull)
        XCTAssertTrue(preferences["customCodexPath"] is NSNull)

        switch store.load() {
        case .loaded(let loaded):
            XCTAssertEqual(loaded.preferences.displayStyle, .balanced)
            XCTAssertEqual(loaded.preferences.title, "DeskTitle")
            XCTAssertEqual(loaded.preferences, try state.preferences.validated())
        default:
            XCTFail("expected loaded state")
        }
    }

    func testSaveDoesNotDuplicatePreferencesInUserDefaults() throws {
        let defaults = UserDefaults.standard
        let probeKeys = [
            "displayStyle", "title", "tpsWindowMinutes", "redThreshold", "language",
            "customCodexPath", "quotaOrder", "dateFormat", "redAccent",
        ]
        for key in probeKeys {
            defaults.removeObject(forKey: key)
        }
        let root = try makeRoot()
        var state = ProductState.default
        state.preferences.language = .simplifiedChinese
        try PersistenceStore(root: root).save(state)
        for key in probeKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        let source = try String(
            contentsOf: RepoRoot.url().appendingPathComponent("src/Persistence/PersistenceStore.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("UserDefaults"))
    }

    func testCorruptJSONIsQuarantinedOnceThenLoadsDefaults() throws {
        let root = try makeRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stateURL = root.appendingPathComponent("state.json")
        try Data("{".utf8).write(to: stateURL)
        let oldQuarantine = root.appendingPathComponent("state.json.quarantine")
        try Data("old".utf8).write(to: oldQuarantine)

        switch PersistenceStore(root: root).load() {
        case .corrupt(let state):
            XCTAssertEqual(state, .default)
        default:
            XCTFail("expected corrupt load")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertEqual(try String(contentsOf: oldQuarantine, encoding: .utf8), "{")
        let attributes = try FileManager.default.attributesOfItem(atPath: oldQuarantine.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertEqual(try backupExcluded(oldQuarantine), true)
        XCTAssertEqual(
            PersistenceStore(root: root).load().storageClassification,
            nil
        )
    }

    func testUnknownNewerSchemaIsReadOnlyAndNotOverwritten() throws {
        let root = try makeRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = """
        {"schemaVersion":2,"keep":true}
        """
        let stateURL = root.appendingPathComponent("state.json")
        try Data(original.utf8).write(to: stateURL)

        let store = PersistenceStore(root: root)
        let loaded = store.load()
        XCTAssertEqual(loaded, .unsupportedSchema)
        XCTAssertFalse(loaded.isWritable)
        XCTAssertEqual(loaded.storageClassification, .stateVersionUnsupported)
        XCTAssertFalse(loaded.showsFirstRunDisclosure)

        XCTAssertThrowsError(try store.save(.default)) { error in
            XCTAssertEqual(error as? PersistenceError, .readOnlyUnsupportedSchema)
        }
        XCTAssertEqual(try String(contentsOf: stateURL, encoding: .utf8), original)

        try store.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        if case .missing = store.load() {
            XCTAssertTrue(true)
        } else {
            XCTFail("reset should return missing defaults")
        }
    }

    func testExpiredQuarantineIsDeletedUsingInjectedClock() throws {
        let root = try makeRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let quarantine = root.appendingPathComponent("state.json.quarantine")
        try Data("stale".utf8).write(to: quarantine)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: quarantine.path
        )
        let store = PersistenceStore(root: root, now: { now })
        _ = store.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
    }

    func testUnknownFieldsAndInvalidV1ValuesAreCorrupt() throws {
        let root = try makeRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let valid = try ProductStateCodec.encode(.default)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        json["extra"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("state.json"))
        if case .corrupt = PersistenceStore(root: root).load() {
            XCTAssertTrue(true)
        } else {
            XCTFail("unknown field must be corrupt")
        }
    }

    func testSaveRejectsNonExecutableCustomCodexPathAndLoadQuarantinesIt() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("not-exec")
        try Data("x".utf8).write(to: file)
        var state = ProductState.default
        state.preferences.customCodexPath = file.path
        XCTAssertThrowsError(try PersistenceStore(root: root).save(state)) { error in
            XCTAssertEqual(error as? PersistenceError, .invalidCustomCodexPath)
        }

        let executable = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        state.preferences.customCodexPath = executable.path
        try PersistenceStore(root: root).save(state)
        if case .loaded(let loaded) = PersistenceStore(root: root).load() {
            XCTAssertEqual(loaded.preferences.customCodexPath, executable.path)
        } else {
            XCTFail("executable path should load")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
        if case .corrupt = PersistenceStore(root: root).load() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json.quarantine").path))
        } else {
            XCTFail("non-executable stored path should quarantine")
        }
    }

    func testMissingStateIsFirstRunDefaults() throws {
        let loaded = PersistenceStore(root: try makeRoot()).load()
        XCTAssertEqual(loaded, .missing(.default))
        XCTAssertTrue(loaded.showsFirstRunDisclosure)
        XCTAssertTrue(loaded.isWritable)
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageink-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func backupExcluded(_ url: URL) throws -> Bool {
        try XCTUnwrap(url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup)
    }
}

