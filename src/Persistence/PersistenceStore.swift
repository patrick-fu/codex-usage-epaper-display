import Darwin
import Foundation

enum PersistenceError: Error, Equatable, Sendable {
    case readOnlyUnsupportedSchema
    case writeFailed
    case invalidCustomCodexPath
    case symlinkRejected
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
        if case .missing = self {
            return true
        }
        return false
    }

    var shouldPresentSettingsOnLaunch: Bool {
        switch self {
        case .missing, .corrupt, .unsupportedSchema:
            return true
        case .loaded:
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

    static func installTestHostIsolationIfNeeded() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return
        }
        if overrideRoot != nil {
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usageink-testhost-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        overrideRoot = url
    }

    static func productionRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("com.patrickfu.UsageInk", isDirectory: true)
    }

    static func resolvedRoot() -> URL {
        if let overrideRoot {
            return overrideRoot
        }
        if let env = ProcessInfo.processInfo.environment["USAGEINK_STATE_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        installTestHostIsolationIfNeeded()
        if let overrideRoot {
            return overrideRoot
        }
        return productionRoot()
    }
}

private final class SaveErrorSlot: @unchecked Sendable {
    var value: PersistenceError?
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
    private let saveErrorSlot = SaveErrorSlot()

    var simulatedSaveError: PersistenceError? {
        get { saveErrorSlot.value }
        nonmutating set { saveErrorSlot.value = newValue }
    }

    init(
        root: URL = PersistenceLocation.resolvedRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        simulatedSaveError: PersistenceError? = nil
    ) {
        self.root = root
        self.now = now
        self.isExecutable = isExecutable
        self.saveErrorSlot.value = simulatedSaveError
    }

    var stateURL: URL { root.appendingPathComponent(Self.stateFileName) }
    var quarantineURL: URL { root.appendingPathComponent(Self.quarantineFileName) }
    var temporaryURL: URL { root.appendingPathComponent(Self.temporaryFileName) }

    func load() -> PersistenceLoadResult {
        expireQuarantineIfNeeded()
        do {
            guard try pathExists(stateURL) else {
                return .missing(.default)
            }
        } catch PersistenceError.symlinkRejected {
            return .corrupt(.default)
        } catch {
            return quarantineExistingState()
        }
        let data: Data
        do {
            data = try SecureStateFile.readRegularFile(at: stateURL)
        } catch PersistenceError.symlinkRejected {
            return .corrupt(.default)
        } catch {
            return quarantineExistingState()
        }
        do {
            switch try ProductStateCodec.decode(data) {
            case .unsupportedSchema:
                return .unsupportedSchema
            case .state(let state):
                if let path = state.preferences.customCodexPath, !isExecutable(path) {
                    return .loaded(state)
                }
                return .loaded(state)
            }
        } catch {
            return quarantineExistingState()
        }
    }

    func save(_ state: ProductState) throws {
        if let simulatedSaveError {
            throw simulatedSaveError
        }
        if isExistingFileUnsupportedSchema() {
            throw PersistenceError.readOnlyUnsupportedSchema
        }
        let prepared: ProductState
        do {
            prepared = try state.preparedForWrite()
        } catch PreferenceValidationError.invalidCustomCodexPath {
            throw PersistenceError.invalidCustomCodexPath
        } catch {
            throw PersistenceError.writeFailed
        }
        do {
            try ensureDirectory()
            let data = try ProductStateCodec.encode(prepared)
            try atomicReplace(with: data)
        } catch PersistenceError.symlinkRejected {
            throw PersistenceError.writeFailed
        } catch PersistenceError.writeFailed {
            throw PersistenceError.writeFailed
        } catch PersistenceError.readOnlyUnsupportedSchema {
            throw PersistenceError.readOnlyUnsupportedSchema
        } catch PersistenceError.invalidCustomCodexPath {
            throw PersistenceError.invalidCustomCodexPath
        } catch {
            throw PersistenceError.writeFailed
        }
    }

    func reset() throws {
        do {
            try ensureDirectory()
            try SecureStateFile.removeRegularFileIfPresent(at: stateURL)
            try SecureStateFile.removeRegularFileIfPresent(at: quarantineURL)
            try SecureStateFile.removeRegularFileIfPresent(at: temporaryURL)
        } catch {
            throw PersistenceError.writeFailed
        }
    }

    private func isExistingFileUnsupportedSchema() -> Bool {
        guard let data = try? SecureStateFile.readRegularFile(at: stateURL),
              let decoded = try? ProductStateCodec.decode(data) else {
            return false
        }
        if case .unsupportedSchema = decoded {
            return true
        }
        return false
    }

    private func expireQuarantineIfNeeded() {
        guard let modified = try? SecureStateFile.modificationDate(at: quarantineURL) else {
            return
        }
        if now().timeIntervalSince(modified) > Self.quarantineLifetime {
            try? SecureStateFile.removeRegularFileIfPresent(at: quarantineURL)
        }
    }

    private func quarantineExistingState() -> PersistenceLoadResult {
        do {
            try ensureDirectory()
            try SecureStateFile.quarantineRegularFile(
                from: stateURL,
                to: quarantineURL,
                mode: mode_t(Self.filePermission)
            )
            try excludeFromBackup(quarantineURL)
        } catch {
            return .corrupt(.default)
        }
        return .corrupt(.default)
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
        var attributeError: Error?
        do {
            try SecureStateFile.writeRegularFile(
                data,
                to: temporaryURL,
                mode: mode_t(Self.filePermission)
            )
            do {
                try excludeFromBackup(temporaryURL)
            } catch {
                attributeError = error
            }
        } catch {
            try fsyncDirectory(root)
            throw PersistenceError.writeFailed
        }
        do {
            try posixRename(from: temporaryURL, to: stateURL)
        } catch {
            try fsyncDirectory(root)
            throw PersistenceError.writeFailed
        }
        try fsyncDirectory(root)
        if attributeError != nil {
            throw PersistenceError.writeFailed
        }
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
            return open(path, O_RDONLY | O_DIRECTORY)
        }
        guard fd >= 0 else {
            throw PersistenceError.writeFailed
        }
        defer { close(fd) }
        if Darwin.fsync(fd) != 0 {
            throw PersistenceError.writeFailed
        }
    }

    private func pathExists(_ url: URL) throws -> Bool {
        try SecureStateFile.existsRegularOrAbsent(at: url)
    }
}

enum SecureStateFile {
    static func existsRegularOrAbsent(at url: URL) throws -> Bool {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw PersistenceError.writeFailed
            }
            var st = stat()
            if lstat(path, &st) != 0 {
                if errno == ENOENT {
                    return false
                }
                throw PersistenceError.writeFailed
            }
            let type = st.st_mode & S_IFMT
            if type == S_IFLNK {
                throw PersistenceError.symlinkRejected
            }
            return true
        }
    }

    static func modificationDate(at url: URL) throws -> Date? {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return nil
            }
            var st = stat()
            if lstat(path, &st) != 0 {
                return nil
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                return nil
            }
            return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        }
    }

    static func readRegularFile(at url: URL) throws -> Data {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw PersistenceError.writeFailed
            }
            var linkStat = stat()
            if lstat(path, &linkStat) != 0 {
                throw PersistenceError.writeFailed
            }
            if (linkStat.st_mode & S_IFMT) == S_IFLNK {
                throw PersistenceError.symlinkRejected
            }
            let fd = open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else {
                throw PersistenceError.writeFailed
            }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                throw PersistenceError.writeFailed
            }
            let size = Int(st.st_size)
            var data = Data(count: size)
            if size == 0 {
                return data
            }
            try data.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < size {
                    let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), size - offset)
                    if n <= 0 {
                        throw PersistenceError.writeFailed
                    }
                    offset += n
                }
            }
            return data
        }
    }

    static func writeRegularFile(_ data: Data, to url: URL, mode: mode_t) throws {
        try removeRegularFileIfPresent(at: url)
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw PersistenceError.writeFailed
            }
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
            guard fd >= 0 else {
                throw PersistenceError.writeFailed
            }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                throw PersistenceError.writeFailed
            }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                let total = data.count
                while offset < total {
                    let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), total - offset)
                    if n <= 0 {
                        throw PersistenceError.writeFailed
                    }
                    offset += n
                }
            }
            if fchmod(fd, mode) != 0 {
                throw PersistenceError.writeFailed
            }
            if Darwin.fsync(fd) != 0 {
                throw PersistenceError.writeFailed
            }
        }
    }

    static func removeRegularFileIfPresent(at url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw PersistenceError.writeFailed
            }
            var st = stat()
            if lstat(path, &st) != 0 {
                if errno == ENOENT {
                    return
                }
                throw PersistenceError.writeFailed
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                throw PersistenceError.symlinkRejected
            }
            if unlink(path) != 0, errno != ENOENT {
                throw PersistenceError.writeFailed
            }
        }
    }

    static func quarantineRegularFile(from source: URL, to destination: URL, mode: mode_t) throws {
        let data: Data
        do {
            data = try readRegularFile(at: source)
        } catch PersistenceError.symlinkRejected {
            throw PersistenceError.symlinkRejected
        }
        let temp = destination.appendingPathExtension("tmp")
        try writeRegularFile(data, to: temp, mode: mode)
        let renamed = temp.withUnsafeFileSystemRepresentation { fromPath in
            destination.withUnsafeFileSystemRepresentation { toPath in
                guard let fromPath, let toPath else {
                    return Int32(-1)
                }
                return rename(fromPath, toPath)
            }
        }
        if renamed != 0 {
            try? removeRegularFileIfPresent(at: temp)
            throw PersistenceError.writeFailed
        }
        var destStat = stat()
        let chmodOK = destination.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else {
                return false
            }
            if lstat(path, &destStat) != 0 {
                return false
            }
            if (destStat.st_mode & S_IFMT) == S_IFLNK {
                return false
            }
            let fd = open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else {
                return false
            }
            defer { close(fd) }
            return fchmod(fd, mode) == 0
        }
        if !chmodOK {
            throw PersistenceError.writeFailed
        }
        try removeRegularFileIfPresent(at: source)
    }
}
