import Darwin
import Foundation

enum PersistenceError: Error, Equatable, Sendable {
    case readOnlyUnsupportedSchema
    case writeFailed
    case invalidCustomCodexPath
}

enum PersistenceLoadResult: Equatable, Sendable {
    case missing(ProductState)
    case loaded(ProductState)
    case corrupt(ProductState)
    case unsupportedSchema

    var state: ProductState {
        switch self {
        case .missing(let state), .loaded(let state), .corrupt(let state):
            return state
        case .unsupportedSchema:
            return .default
        }
    }

    var isWritable: Bool {
        if case .unsupportedSchema = self {
            return false
        }
        return true
    }

    var showsFirstRunDisclosure: Bool {
        switch self {
        case .missing, .corrupt:
            return true
        case .loaded, .unsupportedSchema:
            return false
        }
    }

    var storageClassification: StorageClassification? {
        switch self {
        case .missing, .loaded:
            return nil
        case .corrupt:
            return .stateCorrupt
        case .unsupportedSchema:
            return .stateVersionUnsupported
        }
    }
}

enum PersistenceLocation {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrideRootStorage: URL?

    static var overrideRoot: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return overrideRootStorage
        }
        set {
            lock.lock()
            overrideRootStorage = newValue
            lock.unlock()
        }
    }

    static func resolvedRoot() -> URL {
        if let overrideRoot {
            return overrideRoot
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("com.patrickfu.UsageInk", isDirectory: true)
    }
}

struct PersistenceStore: Sendable {
    static let stateFileName = "state.json"
    static let quarantineFileName = "state.json.quarantine"
    static let temporaryFileName = "state.json.tmp"
    static let quarantineLifetime: TimeInterval = 7 * 24 * 60 * 60
    static let directoryPermission: Int = 0o700
    static let filePermission: Int = 0o600

    var root: URL
    var now: @Sendable () -> Date
    var isExecutable: @Sendable (String) -> Bool

    init(
        root: URL = PersistenceLocation.resolvedRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.root = root
        self.now = now
        self.isExecutable = isExecutable
    }

    var stateURL: URL { root.appendingPathComponent(Self.stateFileName) }
    var quarantineURL: URL { root.appendingPathComponent(Self.quarantineFileName) }
    var temporaryURL: URL { root.appendingPathComponent(Self.temporaryFileName) }

    func load() -> PersistenceLoadResult {
        expireQuarantineIfNeeded()
        let fm = FileManager.default
        guard fm.fileExists(atPath: stateURL.path) else {
            return .missing(.default)
        }
        let data: Data
        do {
            data = try Data(contentsOf: stateURL)
        } catch {
            quarantineExistingState()
            return .corrupt(.default)
        }
        do {
            switch try ProductStateCodec.decode(data) {
            case .unsupportedSchema:
                return .unsupportedSchema
            case .state(let state):
                do {
                    try validateStoredExecutable(state.preferences.customCodexPath)
                    return .loaded(state)
                } catch {
                    quarantineExistingState()
                    return .corrupt(.default)
                }
            }
        } catch {
            quarantineExistingState()
            return .corrupt(.default)
        }
    }

    func save(_ state: ProductState) throws {
        if isExistingFileUnsupportedSchema() {
            throw PersistenceError.readOnlyUnsupportedSchema
        }
        var prepared: ProductState
        do {
            prepared = try state.preparedForWrite()
            try validateStoredExecutable(prepared.preferences.customCodexPath)
        } catch PreferenceValidationError.invalidCustomCodexPath {
            throw PersistenceError.invalidCustomCodexPath
        } catch {
            throw PersistenceError.writeFailed
        }
        do {
            try ensureDirectory()
            let data = try ProductStateCodec.encode(prepared)
            try atomicReplace(with: data)
        } catch {
            throw PersistenceError.writeFailed
        }
    }

    func reset() throws {
        do {
            try ensureDirectory()
            let fm = FileManager.default
            for url in [stateURL, quarantineURL, temporaryURL] where fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        } catch {
            throw PersistenceError.writeFailed
        }
    }

    private func validateStoredExecutable(_ path: String?) throws {
        guard let path else {
            return
        }
        guard isExecutable(path) else {
            throw PreferenceValidationError.invalidCustomCodexPath
        }
    }

    private func isExistingFileUnsupportedSchema() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stateURL.path),
              let data = try? Data(contentsOf: stateURL),
              let decoded = try? ProductStateCodec.decode(data) else {
            return false
        }
        if case .unsupportedSchema = decoded {
            return true
        }
        return false
    }

    private func expireQuarantineIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: quarantineURL.path) else {
            return
        }
        let values = try? quarantineURL.resourceValues(forKeys: [.contentModificationDateKey])
        let modified = values?.contentModificationDate ?? Date.distantPast
        if now().timeIntervalSince(modified) > Self.quarantineLifetime {
            try? fm.removeItem(at: quarantineURL)
        }
    }

    private func quarantineExistingState() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stateURL.path) else {
            return
        }
        try? ensureDirectory()
        if fm.fileExists(atPath: quarantineURL.path) {
            try? fm.removeItem(at: quarantineURL)
        }
        do {
            try fm.moveItem(at: stateURL, to: quarantineURL)
            try applyFileAttributes(to: quarantineURL)
        } catch {
            try? fm.removeItem(at: stateURL)
        }
    }

    private func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.directoryPermission]
            )
        } else {
            try fm.setAttributes([.posixPermissions: Self.directoryPermission], ofItemAtPath: root.path)
        }
        try excludeFromBackup(root)
    }

    private func atomicReplace(with data: Data) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: temporaryURL.path) {
            try fm.removeItem(at: temporaryURL)
        }
        try data.write(to: temporaryURL, options: .noFileProtection)
        try applyFileAttributes(to: temporaryURL)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.synchronize()
        try handle.close()
        try posixRename(from: temporaryURL, to: stateURL)
        try applyFileAttributes(to: stateURL)
        try fsyncDirectory(root)
    }

    private func applyFileAttributes(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: Self.filePermission],
            ofItemAtPath: url.path
        )
        try excludeFromBackup(url)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
    }

    private func posixRename(from: URL, to: URL) throws {
        let status = from.withUnsafeFileSystemRepresentation { fromPath in
            to.withUnsafeFileSystemRepresentation { toPath in
                guard let fromPath, let toPath else {
                    return Int32(-1)
                }
                return rename(fromPath, toPath)
            }
        }
        if status != 0 {
            throw PersistenceError.writeFailed
        }
    }

    private func fsyncDirectory(_ url: URL) throws {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            return open(path, O_RDONLY)
        }
        guard fd >= 0 else {
            throw PersistenceError.writeFailed
        }
        defer { close(fd) }
        if Darwin.fsync(fd) != 0 {
            throw PersistenceError.writeFailed
        }
    }
}
