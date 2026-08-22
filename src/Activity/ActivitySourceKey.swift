import CryptoKit
import Foundation

enum ActivitySourceKey {
    static let rolloutPrefix = "rollout-"
    static let jsonlSuffix = ".jsonl"
    static let timestampPrefixLength = 20
    static let parserVersion = 1
    static let namespace = "codex-rollout-v1"

    static func canonicalRolloutId(basename: String) -> String? {
        guard basename.hasPrefix(rolloutPrefix) else { return nil }
        guard basename.hasSuffix(jsonlSuffix) else { return nil }
        guard !basename.contains(".jsonl.") else { return nil }
        let stem = String(basename.dropLast(jsonlSuffix.count))
        let afterRollout = stem.dropFirst(rolloutPrefix.count)
        guard afterRollout.count > timestampPrefixLength else { return nil }
        let afterTimestamp = afterRollout.dropFirst(timestampPrefixLength)
        let uuidPart = afterTimestamp.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? ""
        guard isLowercaseUUID(uuidPart) else { return nil }
        return uuidPart
    }

    static func sourceKey(canonicalRolloutId: String) -> String {
        var data = Data(namespace.utf8)
        data.append(0)
        data.append(Data(canonicalRolloutId.utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sourceKey(basename: String) -> String? {
        guard let id = canonicalRolloutId(basename: basename) else { return nil }
        return sourceKey(canonicalRolloutId: id)
    }

    private static func isLowercaseUUID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return false }
        let lengths = [8, 4, 4, 4, 12]
        for (part, length) in zip(parts, lengths) {
            guard part.count == length else { return false }
            guard part.unicodeScalars.allSatisfy({ scalar in
                (scalar >= "0" && scalar <= "9") || (scalar >= "a" && scalar <= "f")
            }) else {
                return false
            }
        }
        return true
    }
}
