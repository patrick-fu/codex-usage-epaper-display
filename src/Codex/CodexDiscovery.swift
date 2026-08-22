import Foundation

struct CodexVersion: Sendable, Equatable, Comparable {
    var major: Int
    var minor: Int
    var patch: Int

    static let minimum = CodexVersion(major: 0, minor: 147, patch: 0)

    static func < (lhs: CodexVersion, rhs: CodexVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }

    static func parse(_ raw: String) -> CodexVersion? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        let candidate: Substring
        if tokens.count >= 2, tokens[0] == "codex-cli" {
            candidate = tokens[1]
        } else if let first = tokens.first {
            candidate = first
        } else {
            return nil
        }
        let core = candidate.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first ?? candidate
        let parts = core.split(separator: ".")
        guard parts.count >= 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else {
            return nil
        }
        return CodexVersion(major: major, minor: minor, patch: patch)
    }
}

struct CodexResolvedBinary: Sendable, Equatable {
    var path: String
    var version: CodexVersion
}

struct CodexDiscovery: Sendable {
    var isExecutable: @Sendable (String) -> Bool
    var pathEnvironment: String
    var homeDirectory: String
    var runVersion: @Sendable (String) -> Result<String, CodexFailure>

    func resolve(explicitPath: String?) -> Result<CodexResolvedBinary, CodexFailure> {
        let candidates: [String]
        if let explicitPath {
            candidates = [explicitPath]
        } else {
            var found: [String] = []
            for directory in pathEnvironment.split(separator: ":", omittingEmptySubsequences: true) {
                found.append((directory as NSString).appendingPathComponent("codex"))
            }
            found.append("/opt/homebrew/bin/codex")
            found.append("/usr/local/bin/codex")
            found.append((homeDirectory as NSString).appendingPathComponent(".local/bin/codex"))
            candidates = found
        }

        for path in candidates {
            guard isExecutable(path) else {
                continue
            }
            switch runVersion(path) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let output):
                guard let version = CodexVersion.parse(output) else {
                    return .failure(.versionTooOld)
                }
                if version < .minimum {
                    return .failure(.versionTooOld)
                }
                return .success(CodexResolvedBinary(path: path, version: version))
            }
        }

        return .failure(.binaryMissing)
    }
}
