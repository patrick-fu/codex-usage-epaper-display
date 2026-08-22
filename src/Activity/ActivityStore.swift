import Darwin
import Foundation
import SQLite3

enum ActivityStoreError: Error, Equatable, Sendable {
    case openFailed
    case integrityFailed
    case transactionFailed
}

final class ActivityStore: @unchecked Sendable {
    static let databaseFileName = "activity.sqlite"
    static let filePermission = Int(0o600)

    let root: URL
    private var db: OpaquePointer?
    private var openedURL: URL?

    init(root: URL) {
        self.root = root
    }

    deinit {
        closeDatabase()
    }

    var databaseURL: URL {
        root.appendingPathComponent(Self.databaseFileName)
    }

    func rehydrate(
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone,
        tpsWindowMinutes: Int,
        lastSuccessfulObservationAt: Int?,
        persistedAvailability: PersistedAvailability,
        persistedFailure: String?
    ) -> LocalActivityObservation {
        do {
            try openOrRebuild()
        } catch {
            return LocalActivityObservation(
                availability: .unavailable,
                failure: "unknown",
                todayTokens: nil,
                weekTokens: nil,
                cacheHitRate: nil,
                tps: nil,
                coverageComplete: false
            )
        }
        guard let totals = try? queryTotals(
            now: now,
            calendar: calendar,
            pollStart: now,
            tpsWindowMinutes: tpsWindowMinutes
        ) else {
            return LocalActivityObservation(
                availability: .unavailable,
                failure: "unknown",
                todayTokens: nil,
                weekTokens: nil,
                cacheHitRate: nil,
                tps: nil,
                coverageComplete: false
            )
        }
        let lastSuccess = lastSuccessfulObservationAt ?? (try? maxLastSeenAt())
        if lastSuccess == nil {
            return .unknown
        }
        let availability = LocalActivityMetrics.availability(
            lastSuccessfulObservationAt: lastSuccess,
            now: now
        )
        let coverageComplete = persistedFailure == nil && availability != .unknown
        return LocalActivityObservation(
            availability: availability,
            failure: persistedFailure,
            todayTokens: totals.todayTokens,
            weekTokens: totals.weekTokens,
            cacheHitRate: totals.cacheHitRate(coverageComplete: coverageComplete),
            tps: totals.tps(windowMinutes: tpsWindowMinutes),
            coverageComplete: coverageComplete
        )
    }

    func ingest(
        codexHome: URL,
        pollStart: Date,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone,
        tpsWindowMinutes: Int,
        limits: ActivityScanLimits = .specification,
        prior: LocalActivityObservation
    ) -> LocalActivityObservation {
        do {
            try openOrRebuild()
        } catch {
            return unavailableObservation(prior: prior)
        }
        let cursors: [String: SourceCursorRecord]
        do {
            cursors = try loadCursors()
        } catch {
            return unavailableObservation(prior: prior)
        }
        let plan = ActivityScanner.scan(
            codexHome: codexHome,
            existingCursors: cursors,
            pollStart: pollStart,
            now: now,
            limits: limits
        )
        if plan.status == .budgetExhausted {
            var retained = prior
            retained.availability = prior.todayTokens == nil ? .unavailable : prior.availability
            retained.failure = "sourceScanTimeout"
            retained.coverageComplete = false
            return retained
        }
        if !plan.rootsExisted {
            if prior.todayTokens == nil {
                return .unknown
            }
            return prior
        }
        do {
            try apply(plan, now: now)
        } catch {
            var retained = prior
            retained.failure = "unknown"
            retained.coverageComplete = false
            return retained
        }
        guard let totals = try? queryTotals(
            now: now,
            calendar: calendar,
            pollStart: pollStart,
            tpsWindowMinutes: tpsWindowMinutes
        ) else {
            return unavailableObservation(prior: prior)
        }
        let lastSuccess = Int(now.timeIntervalSince1970.rounded(.towardZero))
        let availability = LocalActivityMetrics.availability(
            lastSuccessfulObservationAt: lastSuccess,
            now: now
        )
        return LocalActivityObservation(
            availability: availability,
            failure: plan.coverageComplete ? nil : plan.failure,
            todayTokens: totals.todayTokens,
            weekTokens: totals.weekTokens,
            cacheHitRate: totals.cacheHitRate(coverageComplete: plan.coverageComplete),
            tps: totals.tps(windowMinutes: tpsWindowMinutes),
            coverageComplete: plan.coverageComplete
        )
    }

    func rebuildDatabase() throws {
        closeDatabase()
        try removeDatabaseFiles()
        try openOrRebuild()
    }

    func destroyDatabase() throws {
        closeDatabase()
        try removeDatabaseFiles()
    }

    func loadCursorsForTests() throws -> [SourceCursorRecord] {
        try openOrRebuild()
        return Array(try loadCursors().values)
    }

    func loadFactsForTests() throws -> [ActivityFactRecord] {
        try openOrRebuild()
        return try loadFacts()
    }

    private func unavailableObservation(prior: LocalActivityObservation) -> LocalActivityObservation {
        if prior.todayTokens == nil {
            return LocalActivityObservation(
                availability: .unavailable,
                failure: "unknown",
                todayTokens: nil,
                weekTokens: nil,
                cacheHitRate: nil,
                tps: nil,
                coverageComplete: false
            )
        }
        var retained = prior
        retained.failure = prior.failure ?? "unknown"
        retained.coverageComplete = false
        return retained
    }

    private func openOrRebuild() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: PersistenceStore.directoryPermission]
        )
        try excludeFromBackup(root)
        if db != nil { return }
        do {
            try openDatabase()
            try applySchema()
            try checkIntegrity()
            try protectSidecars()
        } catch {
            closeDatabase()
            try? removeDatabaseFiles()
            do {
                try openDatabase()
                try applySchema()
                try checkIntegrity()
                try protectSidecars()
            } catch {
                closeDatabase()
                throw ActivityStoreError.openFailed
            }
        }
    }

    private func openDatabase() throws {
        try databaseURL.path.withCString { path in
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
                if let handle { sqlite3_close(handle) }
                throw ActivityStoreError.openFailed
            }
            db = handle
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try chmodPath(databaseURL.path)
        try excludeFromBackup(databaseURL)
    }

    private func applySchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS activity_fact (
          id INTEGER PRIMARY KEY,
          source_key TEXT NOT NULL CHECK(length(source_key)=64 AND source_key NOT GLOB '*[^0-9a-f]*'),
          observed_at INTEGER NOT NULL,
          input_delta INTEGER NOT NULL CHECK(input_delta >= 0),
          cached_input_delta INTEGER NOT NULL CHECK(cached_input_delta >= 0 AND cached_input_delta <= input_delta),
          output_delta INTEGER NOT NULL CHECK(output_delta >= 0),
          reasoning_delta INTEGER NOT NULL CHECK(reasoning_delta >= 0 AND reasoning_delta <= output_delta),
          CHECK(input_delta + output_delta > 0)
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS activity_fact_observed_at ON activity_fact(observed_at);")
        try exec("CREATE INDEX IF NOT EXISTS activity_fact_source_key_observed_at ON activity_fact(source_key, observed_at);")
        try exec("""
        CREATE TABLE IF NOT EXISTS source_cursor (
          source_key TEXT PRIMARY KEY CHECK(length(source_key)=64 AND source_key NOT GLOB '*[^0-9a-f]*'),
          parser_version INTEGER NOT NULL CHECK(parser_version = 1),
          inode_generation INTEGER NOT NULL,
          size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0),
          newline_offset INTEGER NOT NULL CHECK(newline_offset >= 0),
          tail_checksum TEXT NOT NULL CHECK(length(tail_checksum)=64 AND tail_checksum NOT GLOB '*[^0-9a-f]*'),
          input_watermark INTEGER NOT NULL CHECK(input_watermark >= 0),
          cached_input_watermark INTEGER NOT NULL CHECK(cached_input_watermark >= 0),
          output_watermark INTEGER NOT NULL CHECK(output_watermark >= 0),
          reasoning_watermark INTEGER NOT NULL CHECK(reasoning_watermark >= 0),
          last_seen_at INTEGER NOT NULL
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS source_cursor_last_seen_at ON source_cursor(last_seen_at);")
    }

    private func checkIntegrity() throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &statement, nil) == SQLITE_OK else {
            throw ActivityStoreError.integrityFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ActivityStoreError.integrityFailed
        }
        let result = String(cString: sqlite3_column_text(statement, 0))
        if result != "ok" {
            throw ActivityStoreError.integrityFailed
        }
    }

    private func apply(_ plan: ActivityScanPlan, now: Date) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            for key in plan.rebuildSourceKeys {
                try exec("DELETE FROM activity_fact WHERE source_key = '\(key)';")
                try exec("DELETE FROM source_cursor WHERE source_key = '\(key)';")
            }
            for fact in plan.facts {
                try insertFact(fact)
            }
            for cursor in plan.cursors {
                try upsertCursor(cursor)
            }
            let nowSeconds = Int(now.timeIntervalSince1970.rounded(.towardZero))
            try exec(
                "DELETE FROM activity_fact WHERE observed_at < \(nowSeconds - LocalActivityMetrics.factRetentionSeconds);"
            )
            try exec(
                "DELETE FROM source_cursor WHERE last_seen_at < \(nowSeconds - LocalActivityMetrics.cursorRetentionSeconds);"
            )
            try exec("COMMIT;")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw ActivityStoreError.transactionFailed
        }
        try protectSidecars()
    }

    private func insertFact(_ fact: ActivityFactRecord) throws {
        let sql = """
        INSERT INTO activity_fact(
          source_key, observed_at, input_delta, cached_input_delta, output_delta, reasoning_delta
        ) VALUES (?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ActivityStoreError.transactionFailed
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, fact.sourceKey)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(fact.observedAt))
        sqlite3_bind_int64(statement, 3, fact.inputDelta)
        sqlite3_bind_int64(statement, 4, fact.cachedInputDelta)
        sqlite3_bind_int64(statement, 5, fact.outputDelta)
        sqlite3_bind_int64(statement, 6, fact.reasoningDelta)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ActivityStoreError.transactionFailed
        }
    }

    private func upsertCursor(_ cursor: SourceCursorRecord) throws {
        let sql = """
        INSERT INTO source_cursor(
          source_key, parser_version, inode_generation, size_bytes, newline_offset, tail_checksum,
          input_watermark, cached_input_watermark, output_watermark, reasoning_watermark, last_seen_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source_key) DO UPDATE SET
          parser_version=excluded.parser_version,
          inode_generation=excluded.inode_generation,
          size_bytes=excluded.size_bytes,
          newline_offset=excluded.newline_offset,
          tail_checksum=excluded.tail_checksum,
          input_watermark=excluded.input_watermark,
          cached_input_watermark=excluded.cached_input_watermark,
          output_watermark=excluded.output_watermark,
          reasoning_watermark=excluded.reasoning_watermark,
          last_seen_at=excluded.last_seen_at;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ActivityStoreError.transactionFailed
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, cursor.sourceKey)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(cursor.parserVersion))
        sqlite3_bind_int64(statement, 3, cursor.inodeGeneration)
        sqlite3_bind_int64(statement, 4, cursor.sizeBytes)
        sqlite3_bind_int64(statement, 5, cursor.newlineOffset)
        bindText(statement, 6, cursor.tailChecksum)
        sqlite3_bind_int64(statement, 7, cursor.inputWatermark)
        sqlite3_bind_int64(statement, 8, cursor.cachedInputWatermark)
        sqlite3_bind_int64(statement, 9, cursor.outputWatermark)
        sqlite3_bind_int64(statement, 10, cursor.reasoningWatermark)
        sqlite3_bind_int64(statement, 11, sqlite3_int64(cursor.lastSeenAt))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ActivityStoreError.transactionFailed
        }
    }

    private func loadCursors() throws -> [String: SourceCursorRecord] {
        let sql = """
        SELECT source_key, parser_version, inode_generation, size_bytes, newline_offset, tail_checksum,
               input_watermark, cached_input_watermark, output_watermark, reasoning_watermark, last_seen_at
        FROM source_cursor;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ActivityStoreError.openFailed
        }
        defer { sqlite3_finalize(statement) }
        var result: [String: SourceCursorRecord] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let record = SourceCursorRecord(
                sourceKey: textColumn(statement, 0),
                parserVersion: Int(sqlite3_column_int64(statement, 1)),
                inodeGeneration: sqlite3_column_int64(statement, 2),
                sizeBytes: sqlite3_column_int64(statement, 3),
                newlineOffset: sqlite3_column_int64(statement, 4),
                tailChecksum: textColumn(statement, 5),
                inputWatermark: sqlite3_column_int64(statement, 6),
                cachedInputWatermark: sqlite3_column_int64(statement, 7),
                outputWatermark: sqlite3_column_int64(statement, 8),
                reasoningWatermark: sqlite3_column_int64(statement, 9),
                lastSeenAt: Int(sqlite3_column_int64(statement, 10))
            )
            result[record.sourceKey] = record
        }
        return result
    }

    private func loadFacts() throws -> [ActivityFactRecord] {
        let sql = """
        SELECT source_key, observed_at, input_delta, cached_input_delta, output_delta, reasoning_delta
        FROM activity_fact ORDER BY id;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ActivityStoreError.openFailed
        }
        defer { sqlite3_finalize(statement) }
        var facts: [ActivityFactRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            facts.append(
                ActivityFactRecord(
                    sourceKey: textColumn(statement, 0),
                    observedAt: Int(sqlite3_column_int64(statement, 1)),
                    inputDelta: sqlite3_column_int64(statement, 2),
                    cachedInputDelta: sqlite3_column_int64(statement, 3),
                    outputDelta: sqlite3_column_int64(statement, 4),
                    reasoningDelta: sqlite3_column_int64(statement, 5)
                )
            )
        }
        return facts
    }

    private func maxLastSeenAt() throws -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(last_seen_at) FROM source_cursor;", -1, &statement, nil) == SQLITE_OK else {
            throw ActivityStoreError.openFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func queryTotals(
        now: Date,
        calendar: Calendar,
        pollStart: Date,
        tpsWindowMinutes: Int
    ) throws -> LocalTotals {
        guard let today = LocalActivityMetrics.dayRange(containing: now, calendar: calendar),
              let week = LocalActivityMetrics.weekRange(containing: now, calendar: calendar) else {
            throw ActivityStoreError.openFailed
        }
        let tps = LocalActivityMetrics.tpsRange(pollStart: pollStart, windowMinutes: tpsWindowMinutes)
        return LocalTotals(
            todayInput: try sum(column: "input_delta", range: today),
            todayOutput: try sum(column: "output_delta", range: today),
            todayCachedInput: try sum(column: "cached_input_delta", range: today),
            weekInput: try sum(column: "input_delta", range: week),
            weekOutput: try sum(column: "output_delta", range: week),
            windowOutput: try sumClosed(column: "output_delta", range: tps)
        )
    }

    private func sum(column: String, range: Range<Int>) throws -> Int64 {
        let sql = "SELECT COALESCE(SUM(\(column)), 0) FROM activity_fact WHERE observed_at >= ? AND observed_at < ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ActivityStoreError.openFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(range.lowerBound))
        sqlite3_bind_int64(statement, 2, sqlite3_int64(range.upperBound))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ActivityStoreError.openFailed
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func sumClosed(column: String, range: ClosedRange<Int>) throws -> Int64 {
        let sql = "SELECT COALESCE(SUM(\(column)), 0) FROM activity_fact WHERE observed_at >= ? AND observed_at <= ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ActivityStoreError.openFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(range.lowerBound))
        sqlite3_bind_int64(statement, 2, sqlite3_int64(range.upperBound))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ActivityStoreError.openFailed
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ActivityStoreError.transactionFailed
        }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }

    private func textColumn(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func closeDatabase() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    private func removeDatabaseFiles() throws {
        let names = [
            Self.databaseFileName,
            Self.databaseFileName + "-wal",
            Self.databaseFileName + "-shm",
            Self.databaseFileName + "-journal",
        ]
        for name in names {
            let url = root.appendingPathComponent(name)
            try? SecureStateFile.removeRegularFileIfPresent(at: url)
        }
    }

    private func protectSidecars() throws {
        let names = [
            Self.databaseFileName,
            Self.databaseFileName + "-wal",
            Self.databaseFileName + "-shm",
        ]
        for name in names {
            let url = root.appendingPathComponent(name)
            var st = stat()
            let exists = url.path.withCString { lstat($0, &st) == 0 }
            if exists {
                try chmodPath(url.path)
                try excludeFromBackup(url)
            }
        }
    }

    private func chmodPath(_ path: String) throws {
        let fd = path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        if fd >= 0 {
            _ = fchmod(fd, mode_t(Self.filePermission))
            close(fd)
        } else {
            _ = path.withCString { chmod($0, mode_t(Self.filePermission)) }
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
    }
}
