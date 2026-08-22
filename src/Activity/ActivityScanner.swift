import CryptoKit
import Darwin
import Foundation

@_silgen_name("fcntl")
private func usageInkFcntl(
    _ fd: Int32,
    _ cmd: Int32,
    _ ptr: UnsafeMutableRawPointer?
) -> Int32

enum ActivityScanner {
    static func scan(
        codexHome: URL,
        existingCursors: [String: SourceCursorRecord],
        pollStart: Date,
        now: Date,
        limits: ActivityScanLimits = .specification
    ) -> ActivityScanPlan {
        let budget = ScanBudget(limits: limits)
        let first = scanOnce(
            codexHome: codexHome,
            existingCursors: existingCursors,
            pollStart: pollStart,
            now: now,
            budget: budget
        )
        if first.status == .budgetExhausted {
            return first
        }
        if first.failure == "sourceUnreadable" || first.failure == "sourcePermissionDenied" {
            if budget.hasRoom, first.status != .committed || !first.coverageComplete {
                let retryBudget = ScanBudget(limits: limits, consumed: budget)
                let retry = scanOnce(
                    codexHome: codexHome,
                    existingCursors: existingCursors,
                    pollStart: pollStart,
                    now: now,
                    budget: retryBudget
                )
                if retry.status != .budgetExhausted {
                    return retry
                }
            }
        }
        return first
    }

    private static func scanOnce(
        codexHome: URL,
        existingCursors: [String: SourceCursorRecord],
        pollStart: Date,
        now: Date,
        budget: ScanBudget
    ) -> ActivityScanPlan {
        var coverageComplete = true
        var failure: String?
        var rootsExisted = false
        var winners: [String: Candidate] = [:]
        var retainedRootFds: [ActivityLayer: Int32] = [:]
        defer {
            for fd in retainedRootFds.values {
                close(fd)
            }
        }

        for layer in [ActivityLayer.sessions, .archivedSessions] {
            if budget.exhausted {
                return .init(
                    status: .budgetExhausted,
                    coverageComplete: false,
                    failure: "sourceScanTimeout",
                    rebuildSourceKeys: [],
                    facts: [],
                    cursors: [],
                    rootsExisted: rootsExisted
                )
            }
            let rootURL = codexHome.appendingPathComponent(layer.rawValue, isDirectory: true)
            switch enumerate(rootURL: rootURL, layer: layer, budget: budget, coverageComplete: &coverageComplete, failure: &failure) {
            case .missing:
                continue
            case .rejected:
                coverageComplete = false
                rootsExisted = true
            case .candidates(let rootFd, let candidates):
                if let previous = retainedRootFds.updateValue(rootFd, forKey: layer) {
                    close(previous)
                }
                rootsExisted = true
                for candidate in candidates {
                    mergeWinner(candidate, into: &winners)
                }
            case .exhausted:
                return .init(
                    status: .budgetExhausted,
                    coverageComplete: false,
                    failure: "sourceScanTimeout",
                    rebuildSourceKeys: [],
                    facts: [],
                    cursors: [],
                    rootsExisted: rootsExisted
                )
            }
        }

        if !rootsExisted {
            return .init(
                status: .committed,
                coverageComplete: true,
                failure: nil,
                rebuildSourceKeys: [],
                facts: [],
                cursors: [],
                rootsExisted: false
            )
        }

        var facts: [ActivityFactRecord] = []
        var cursors: [SourceCursorRecord] = []
        var rebuilds: [String] = []
        let lastSeenAt = Int(now.timeIntervalSince1970.rounded(.towardZero))

        for sourceKey in winners.keys.sorted() {
            if budget.exhausted {
                return .init(
                    status: .budgetExhausted,
                    coverageComplete: false,
                    failure: "sourceScanTimeout",
                    rebuildSourceKeys: [],
                    facts: [],
                    cursors: [],
                    rootsExisted: true
                )
            }
            guard let candidate = winners[sourceKey] else { continue }
            guard let rootFd = retainedRootFds[candidate.layer] else {
                coverageComplete = false
                if failure == nil { failure = "sourceUnreadable" }
                continue
            }
            let existing = existingCursors[sourceKey]
            switch ingest(
                candidate: candidate,
                rootFd: rootFd,
                existing: existing,
                pollStart: pollStart,
                lastSeenAt: lastSeenAt,
                budget: budget
            ) {
            case .exhausted:
                return .init(
                    status: .budgetExhausted,
                    coverageComplete: false,
                    failure: "sourceScanTimeout",
                    rebuildSourceKeys: [],
                    facts: [],
                    cursors: [],
                    rootsExisted: true
                )
            case .rejected(let code):
                coverageComplete = false
                if failure == nil { failure = code }
            case .ingested(let result):
                if result.rebuild {
                    rebuilds.append(sourceKey)
                }
                if result.partial {
                    coverageComplete = false
                    if failure == nil { failure = result.failure ?? "sourcePartialTail" }
                } else if let code = result.failure {
                    coverageComplete = false
                    if failure == nil { failure = code }
                }
                facts.append(contentsOf: result.facts)
                if let cursor = result.cursor {
                    cursors.append(cursor)
                }
            }
        }

        return .init(
            status: .committed,
            coverageComplete: coverageComplete,
            failure: coverageComplete ? nil : failure,
            rebuildSourceKeys: rebuilds,
            facts: facts,
            cursors: cursors,
            rootsExisted: true
        )
    }

    private static func mergeWinner(_ candidate: Candidate, into winners: inout [String: Candidate]) {
        if let current = winners[candidate.sourceKey] {
            if candidate.layer.rank < current.layer.rank { return }
            if candidate.layer.rank == current.layer.rank, candidate.basename <= current.basename {
                return
            }
        }
        winners[candidate.sourceKey] = candidate
    }

    private enum EnumerationResult {
        case missing
        case rejected
        case exhausted
        case candidates(rootFd: Int32, [Candidate])
    }

    private static func enumerate(
        rootURL: URL,
        layer: ActivityLayer,
        budget: ScanBudget,
        coverageComplete: inout Bool,
        failure: inout String?
    ) -> EnumerationResult {
        let path = rootURL.path
        var rootStat = stat()
        let lstatStatus = path.withCString { lstat($0, &rootStat) }
        if lstatStatus != 0 {
            if errno == ENOENT {
                return .missing
            }
            coverageComplete = false
            if failure == nil {
                failure = errno == EACCES ? "sourcePermissionDenied" : "sourceUnreadable"
            }
            return .rejected
        }
        if (rootStat.st_mode & S_IFMT) == S_IFLNK {
            coverageComplete = false
            if failure == nil { failure = "sourceUnreadable" }
            return .rejected
        }
        if (rootStat.st_mode & S_IFMT) != S_IFDIR {
            coverageComplete = false
            if failure == nil { failure = "sourceUnreadable" }
            return .rejected
        }
        let rootFd = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        if rootFd < 0 {
            coverageComplete = false
            if failure == nil {
                failure = errno == EACCES ? "sourcePermissionDenied" : "sourceUnreadable"
            }
            return .rejected
        }
        var opened = stat()
        guard fstat(rootFd, &opened) == 0,
              opened.st_dev == rootStat.st_dev,
              opened.st_ino == rootStat.st_ino else {
            close(rootFd)
            coverageComplete = false
            if failure == nil { failure = "sourceUnreadable" }
            return .rejected
        }
        let rootReal = filePath(for: rootFd) ?? path
        var visited: Set<FileIdentity> = [FileIdentity(stat: opened)]
        var candidates: [Candidate] = []
        let walk = walkDirectory(
            dirFd: rootFd,
            relative: "",
            rootReal: rootReal,
            layer: layer,
            budget: budget,
            visited: &visited,
            candidates: &candidates,
            coverageComplete: &coverageComplete,
            failure: &failure
        )
        if walk == .exhausted {
            close(rootFd)
            return .exhausted
        }
        return .candidates(rootFd: rootFd, candidates)
    }

    private enum WalkStatus {
        case ok
        case exhausted
    }

    private static func walkDirectory(
        dirFd: Int32,
        relative: String,
        rootReal: String,
        layer: ActivityLayer,
        budget: ScanBudget,
        visited: inout Set<FileIdentity>,
        candidates: inout [Candidate],
        coverageComplete: inout Bool,
        failure: inout String?
    ) -> WalkStatus {
        if budget.exhausted { return .exhausted }
        let cloned = dup(dirFd)
        if cloned < 0 {
            coverageComplete = false
            if failure == nil { failure = "sourceUnreadable" }
            return .ok
        }
        guard let dir = fdopendir(cloned) else {
            close(cloned)
            coverageComplete = false
            if failure == nil { failure = "sourceUnreadable" }
            return .ok
        }
        defer { closedir(dir) }
        while true {
            if budget.exhausted { return .exhausted }
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 {
                    coverageComplete = false
                    if failure == nil { failure = "sourceUnreadable" }
                }
                break
            }
            var nameBytes = entry.pointee.d_name
            let name = withUnsafeBytes(of: &nameBytes) { raw -> String in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                    return ""
                }
                return String(cString: base)
            }
            if name == "." || name == ".." { continue }
            var childStat = stat()
            let childStatus = name.withCString { fstatat(dirFd, $0, &childStat, AT_SYMLINK_NOFOLLOW) }
            if childStatus != 0 {
                coverageComplete = false
                if failure == nil {
                    failure = errno == EACCES ? "sourcePermissionDenied" : "sourceUnreadable"
                }
                continue
            }
            let type = childStat.st_mode & S_IFMT
            if type == S_IFLNK {
                coverageComplete = false
                if failure == nil { failure = "sourceUnreadable" }
                continue
            }
            if type == S_IFDIR {
                let identity = FileIdentity(stat: childStat)
                if visited.contains(identity) {
                    coverageComplete = false
                    if failure == nil { failure = "sourceUnreadable" }
                    continue
                }
                visited.insert(identity)
                let childFd = name.withCString { openat(dirFd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
                if childFd < 0 {
                    coverageComplete = false
                    if failure == nil {
                        failure = errno == EACCES ? "sourcePermissionDenied" : "sourceUnreadable"
                    }
                    continue
                }
                var opened = stat()
                if fstat(childFd, &opened) != 0
                    || opened.st_dev != childStat.st_dev
                    || opened.st_ino != childStat.st_ino {
                    close(childFd)
                    coverageComplete = false
                    if failure == nil { failure = "sourceUnreadable" }
                    continue
                }
                let childRelative = relative.isEmpty ? name : relative + "/" + name
                let nested = walkDirectory(
                    dirFd: childFd,
                    relative: childRelative,
                    rootReal: rootReal,
                    layer: layer,
                    budget: budget,
                    visited: &visited,
                    candidates: &candidates,
                    coverageComplete: &coverageComplete,
                    failure: &failure
                )
                close(childFd)
                if nested == .exhausted { return .exhausted }
                continue
            }
            if type != S_IFREG {
                continue
            }
            if !budget.consumeFile() {
                return .exhausted
            }
            if childStat.st_nlink > 1 {
                coverageComplete = false
                if failure == nil { failure = "sourceUnreadable" }
                continue
            }
            guard let sourceKey = ActivitySourceKey.sourceKey(basename: name) else {
                continue
            }
            let childRelative = relative.isEmpty ? name : relative + "/" + name
            candidates.append(
                Candidate(
                    sourceKey: sourceKey,
                    layer: layer,
                    basename: name,
                    relativePath: childRelative,
                    rootPath: rootReal,
                    device: childStat.st_dev,
                    inode: childStat.st_ino,
                    size: childStat.st_size
                )
            )
        }
        return .ok
    }

    private enum IngestResult {
        case exhausted
        case rejected(String)
        case ingested(FileIngest)
    }

    private struct FileIngest {
        var rebuild: Bool
        var partial: Bool
        var failure: String?
        var facts: [ActivityFactRecord]
        var cursor: SourceCursorRecord?
    }

    private static func ingest(
        candidate: Candidate,
        rootFd: Int32,
        existing: SourceCursorRecord?,
        pollStart: Date,
        lastSeenAt: Int,
        budget: ScanBudget
    ) -> IngestResult {
        let fileFd = openRelative(rootFd: rootFd, relative: candidate.relativePath)
        if fileFd < 0 {
            return .rejected(errno == EACCES ? "sourcePermissionDenied" : "sourceUnreadable")
        }
        defer { close(fileFd) }
        var opened = stat()
        guard fstat(fileFd, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_dev == candidate.device,
              opened.st_ino == candidate.inode else {
            return .rejected("sourceUnreadable")
        }
        if let real = filePath(for: fileFd) {
            if real != candidate.rootPath && !real.hasPrefix(candidate.rootPath + "/") {
                return .rejected("sourceUnreadable")
            }
        }
        if opened.st_nlink > 1 {
            return .rejected("sourceUnreadable")
        }

        var rebuild = false
        var cursor = existing
        if let existing {
            if existing.parserVersion != ActivitySourceKey.parserVersion
                || existing.inodeGeneration != Int64(opened.st_ino)
                || existing.sizeBytes > opened.st_size {
                rebuild = true
                cursor = nil
            } else if !tailChecksumMatches(fd: fileFd, existing: existing, budget: budget) {
                rebuild = true
                cursor = nil
            }
        }

        let startOffset = cursor?.newlineOffset ?? 0
        switch readJSONL(
            fd: fileFd,
            startOffset: startOffset,
            sourceKey: candidate.sourceKey,
            watermarks: cursor.map {
                TokenCounters(
                    input: $0.inputWatermark,
                    cachedInput: $0.cachedInputWatermark,
                    output: $0.outputWatermark,
                    reasoning: $0.reasoningWatermark
                )
            } ?? TokenCounters(input: 0, cachedInput: 0, output: 0, reasoning: 0),
            pollStart: pollStart,
            budget: budget
        ) {
        case .exhausted:
            return .exhausted
        case .result(let parsed):
            if parsed.lowered {
                if !rebuild {
                    return ingestRebuilt(
                        fd: fileFd,
                        candidate: candidate,
                        opened: opened,
                        pollStart: pollStart,
                        lastSeenAt: lastSeenAt,
                        budget: budget
                    )
                }
            }
            let checksum = checksumTail(fd: fileFd, newlineOffset: parsed.newlineOffset, budget: budget)
            guard let checksum else { return .exhausted }
            let next = SourceCursorRecord(
                sourceKey: candidate.sourceKey,
                parserVersion: ActivitySourceKey.parserVersion,
                inodeGeneration: Int64(opened.st_ino),
                sizeBytes: opened.st_size,
                newlineOffset: parsed.newlineOffset,
                tailChecksum: checksum,
                inputWatermark: parsed.watermarks.input,
                cachedInputWatermark: parsed.watermarks.cachedInput,
                outputWatermark: parsed.watermarks.output,
                reasoningWatermark: parsed.watermarks.reasoning,
                lastSeenAt: lastSeenAt
            )
            return .ingested(
                FileIngest(
                    rebuild: rebuild || parsed.lowered,
                    partial: parsed.partial,
                    failure: parsed.failure,
                    facts: parsed.facts,
                    cursor: next
                )
            )
        }
    }

    private static func ingestRebuilt(
        fd: Int32,
        candidate: Candidate,
        opened: stat,
        pollStart: Date,
        lastSeenAt: Int,
        budget: ScanBudget
    ) -> IngestResult {
        switch readJSONL(
            fd: fd,
            startOffset: 0,
            sourceKey: candidate.sourceKey,
            watermarks: TokenCounters(input: 0, cachedInput: 0, output: 0, reasoning: 0),
            pollStart: pollStart,
            budget: budget
        ) {
        case .exhausted:
            return .exhausted
        case .result(let parsed):
            let checksum = checksumTail(fd: fd, newlineOffset: parsed.newlineOffset, budget: budget)
            guard let checksum else { return .exhausted }
            let next = SourceCursorRecord(
                sourceKey: candidate.sourceKey,
                parserVersion: ActivitySourceKey.parserVersion,
                inodeGeneration: Int64(opened.st_ino),
                sizeBytes: opened.st_size,
                newlineOffset: parsed.newlineOffset,
                tailChecksum: checksum,
                inputWatermark: parsed.watermarks.input,
                cachedInputWatermark: parsed.watermarks.cachedInput,
                outputWatermark: parsed.watermarks.output,
                reasoningWatermark: parsed.watermarks.reasoning,
                lastSeenAt: lastSeenAt
            )
            return .ingested(
                FileIngest(
                    rebuild: true,
                    partial: parsed.partial,
                    failure: parsed.failure,
                    facts: parsed.facts,
                    cursor: next
                )
            )
        }
    }

    private enum ReadStatus {
        case exhausted
        case result(ParsedFile)
    }

    private struct ParsedFile {
        var facts: [ActivityFactRecord]
        var watermarks: TokenCounters
        var newlineOffset: Int64
        var partial: Bool
        var lowered: Bool
        var failure: String?
    }

    private static func readJSONL(
        fd: Int32,
        startOffset: Int64,
        sourceKey: String,
        watermarks: TokenCounters,
        pollStart: Date,
        budget: ScanBudget
    ) -> ReadStatus {
        var offset = startOffset
        var completeOffset = startOffset
        var current = watermarks
        var facts: [ActivityFactRecord] = []
        var leftover = Data()
        var partial = false
        var failure: String?
        var lowered = false
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            if budget.exhausted { return .exhausted }
            let n = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress, raw.count, offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return .result(
                    ParsedFile(
                        facts: facts,
                        watermarks: current,
                        newlineOffset: completeOffset,
                        partial: true,
                        lowered: lowered,
                        failure: "sourceUnreadable"
                    )
                )
            }
            if n == 0 { break }
            if !budget.consumeBytes(n) { return .exhausted }
            offset += Int64(n)
            leftover.append(contentsOf: buffer.prefix(n))
            while let newline = leftover.firstIndex(of: 0x0A) {
                let lineData = leftover.prefix(upTo: newline)
                leftover.removeSubrange(...newline)
                completeOffset = offset - Int64(leftover.count)
                let line = String(decoding: lineData, as: UTF8.self)
                switch TokenCountParser.parseLine(line, pollStart: pollStart) {
                case .ignored:
                    continue
                case .malformed:
                    partial = true
                    if failure == nil { failure = "sourceMalformed" }
                case .counters(let observedAt, let total):
                    if total.input < current.input
                        || total.cachedInput < current.cachedInput
                        || total.output < current.output
                        || total.reasoning < current.reasoning {
                        lowered = true
                        return .result(
                            ParsedFile(
                                facts: [],
                                watermarks: watermarks,
                                newlineOffset: startOffset,
                                partial: false,
                                lowered: true,
                                failure: "sourceRollbackRebuild"
                            )
                        )
                    }
                    let inputDelta = total.input - current.input
                    let cachedDelta = total.cachedInput - current.cachedInput
                    let outputDelta = total.output - current.output
                    let reasoningDelta = total.reasoning - current.reasoning
                    current = total
                    if cachedDelta > inputDelta || reasoningDelta > outputDelta {
                        partial = true
                        if failure == nil { failure = "sourceMalformed" }
                        continue
                    }
                    if inputDelta + outputDelta > 0 {
                        facts.append(
                            ActivityFactRecord(
                                sourceKey: sourceKey,
                                observedAt: observedAt,
                                inputDelta: inputDelta,
                                cachedInputDelta: cachedDelta,
                                outputDelta: outputDelta,
                                reasoningDelta: reasoningDelta
                            )
                        )
                    }
                }
            }
        }
        if !leftover.isEmpty {
            partial = true
            if failure == nil { failure = "sourcePartialTail" }
        }
        return .result(
            ParsedFile(
                facts: facts,
                watermarks: current,
                newlineOffset: completeOffset,
                partial: partial,
                lowered: lowered,
                failure: failure
            )
        )
    }

    private static func tailChecksumMatches(
        fd: Int32,
        existing: SourceCursorRecord,
        budget: ScanBudget
    ) -> Bool {
        guard let actual = checksumTail(fd: fd, newlineOffset: existing.newlineOffset, budget: budget) else {
            return false
        }
        return actual == existing.tailChecksum
    }

    private static func checksumTail(fd: Int32, newlineOffset: Int64, budget: ScanBudget) -> String? {
        let length = min(Int64(4096), max(0, newlineOffset))
        if length == 0 {
            return SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        }
        if budget.exhausted { return nil }
        var data = Data(count: Int(length))
        let start = newlineOffset - length
        let n = data.withUnsafeMutableBytes { raw in
            pread(fd, raw.baseAddress, Int(length), start)
        }
        if n != length {
            return nil
        }
        if !budget.consumeBytes(Int(n)) { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func filePath(for fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let status = buffer.withUnsafeMutableBytes { raw in
            usageInkFcntl(fd, F_GETPATH, raw.baseAddress)
        }
        guard status == 0 else { return nil }
        if let end = buffer.firstIndex(of: 0) {
            return String(decoding: buffer[..<end], as: UTF8.self)
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    private static func openRelative(rootFd: Int32, relative: String) -> Int32 {
        var fd = dup(rootFd)
        if fd < 0 { return -1 }
        let parts = relative.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            let flags: Int32 = isLast ? (O_RDONLY | O_NOFOLLOW) : (O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            let next = part.withCString { openat(fd, $0, flags) }
            close(fd)
            if next < 0 { return -1 }
            fd = next
        }
        return fd
    }
}

private struct Candidate {
    var sourceKey: String
    var layer: ActivityLayer
    var basename: String
    var relativePath: String
    var rootPath: String
    var device: dev_t
    var inode: ino_t
    var size: off_t
}

private struct FileIdentity: Hashable {
    var device: dev_t
    var inode: ino_t

    init(stat value: stat) {
        device = value.st_dev
        inode = value.st_ino
    }
}

private final class ScanBudget {
    let deadline: Date
    let maxFiles: Int
    let maxBytes: Int
    var files: Int
    var bytes: Int

    init(limits: ActivityScanLimits, consumed: ScanBudget? = nil) {
        deadline = consumed?.deadline ?? Date().addingTimeInterval(limits.maxWallTime)
        maxFiles = limits.maxFiles
        maxBytes = limits.maxBytes
        files = consumed?.files ?? 0
        bytes = consumed?.bytes ?? 0
    }

    var exhausted: Bool {
        Date() >= deadline || files > maxFiles || bytes > maxBytes
    }

    var hasRoom: Bool {
        !exhausted
    }

    func consumeFile() -> Bool {
        files += 1
        return !exhausted && Date() < deadline
    }

    func consumeBytes(_ count: Int) -> Bool {
        bytes += count
        return !exhausted && Date() < deadline
    }
}
