import Foundation

enum ActivityLocation {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrideCodexHomeStorage: URL?

    static var overrideCodexHome: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return overrideCodexHomeStorage
        }
        set {
            lock.lock()
            overrideCodexHomeStorage = newValue
            lock.unlock()
        }
    }

    static func installTestHostIsolationIfNeeded() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return
        }
        if overrideCodexHome != nil {
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usageink-codex-home-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        overrideCodexHome = url
    }

    static func resolvedCodexHome() -> URL {
        if let overrideCodexHome {
            return overrideCodexHome
        }
        if let env = ProcessInfo.processInfo.environment["USAGEINK_CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        installTestHostIsolationIfNeeded()
        if let overrideCodexHome {
            return overrideCodexHome
        }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
    }
}

struct ActivityScanLimits: Sendable, Equatable {
    var maxWallTime: TimeInterval
    var maxFiles: Int
    var maxBytes: Int

    static let specification = ActivityScanLimits(
        maxWallTime: 8,
        maxFiles: 512,
        maxBytes: 64 * 1024 * 1024
    )
}

enum ActivityLayer: String, Sendable, Equatable {
    case sessions
    case archivedSessions = "archived_sessions"

    var rank: Int {
        switch self {
        case .sessions: return 1
        case .archivedSessions: return 0
        }
    }
}
