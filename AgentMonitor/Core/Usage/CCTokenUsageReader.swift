import Combine
import Foundation
import SQLite3

enum TokenUsageRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case last24Hours
    case last30Days

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "今天"
        case .last24Hours: "24h"
        case .last30Days: "30 天"
        }
    }

    fileprivate func window(now: Date, calendar: Calendar) -> TokenUsageWindow {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return TokenUsageWindow(queryStart: start, start: start, displayEnd: end, component: .hour)
        case .last24Hours:
            let queryStart = now.addingTimeInterval(-24 * 60 * 60)
            let start = calendar.dateInterval(of: .hour, for: queryStart)?.start ?? queryStart
            let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            let end = calendar.date(byAdding: .hour, value: 1, to: currentHour) ?? now
            return TokenUsageWindow(queryStart: queryStart, start: start, displayEnd: end, component: .hour)
        case .last30Days:
            let currentDay = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -29, to: currentDay) ?? now
            let end = calendar.date(byAdding: .day, value: 1, to: currentDay) ?? now
            return TokenUsageWindow(queryStart: start, start: start, displayEnd: end, component: .day)
        }
    }
}

enum InputTokenSemantics: Int64, Sendable {
    case legacy = 0
    case total = 1
    case fresh = 2
}

struct TokenUsageRecord: Sendable, Equatable {
    static let cacheInclusiveAppTypes: Set<String> = ["codex", "gemini", "grokbuild"]
    static let includedAccountingStatus = "included"
    static let pendingAccountingStatus = "pending"
    static let duplicateAccountingStatus = "duplicate"

    let timestamp: Date
    let appType: String
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    var inputTokenSemantics: Int64 = 0
    var model: String = "unknown"
    var accountingStatus: String = TokenUsageRecord.includedAccountingStatus
    var accountingReason: String? = nil

    var normalizedInputTokens: Int64 {
        Self.normalizedInput(
            appType: appType,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            semantics: inputTokenSemantics
        )
    }

    var cacheTokens: Int64 {
        let read = max(0, cacheReadTokens)
        let creation = max(0, cacheCreationTokens)
        guard Self.cacheInclusiveAppTypes.contains(appType.lowercased()) else {
            return read + creation
        }
        if inputTokenSemantics == InputTokenSemantics.fresh.rawValue {
            return read + creation
        }
        if inputTokenSemantics == InputTokenSemantics.total.rawValue {
            return min(max(0, inputTokens), read + creation)
        }
        // Legacy providers include cache reads in input, while cache creation
        // is an additional billable counter.
        return min(max(0, inputTokens), read) + creation
    }

    static func normalizedInput(
        appType: String,
        inputTokens: Int64,
        cacheReadTokens: Int64,
        cacheCreationTokens: Int64,
        semantics: Int64
    ) -> Int64 {
        let normalizedInput = max(0, inputTokens)
        guard cacheInclusiveAppTypes.contains(appType.lowercased()),
              semantics != InputTokenSemantics.fresh.rawValue else {
            return normalizedInput
        }

        if semantics == InputTokenSemantics.total.rawValue {
            let effectiveCache = min(
                normalizedInput,
                max(0, cacheReadTokens) + max(0, cacheCreationTokens)
            )
            return normalizedInput - effectiveCache
        }

        // Legacy providers report cache reads inside input, while cache
        // creation is an additional counter. Clamp only the inclusive read
        // portion so malformed rows cannot inflate the displayed total.
        return normalizedInput - min(normalizedInput, max(0, cacheReadTokens))
    }

}

struct TokenUsageModelTotals: Sendable, Equatable {
    var inputTokens: Int64 = 0
    var cacheTokens: Int64 = 0
    var outputTokens: Int64 = 0

    var totalTokens: Int64 {
        inputTokens + cacheTokens + outputTokens
    }

    mutating func add(_ record: TokenUsageRecord) {
        inputTokens += record.normalizedInputTokens
        cacheTokens += record.cacheTokens
        outputTokens += max(0, record.outputTokens)
    }
}

struct TokenUsageReviewSummary: Sendable, Equatable {
    let count: Int
    let tokens: Int64
    let reasons: [String: Int]

    static let empty = TokenUsageReviewSummary(count: 0, tokens: 0, reasons: [:])
}

struct TokenUsageBucket: Identifiable, Sendable, Equatable {
    let start: Date
    var inputTokens: Int64 = 0
    var cacheTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var models: [String: TokenUsageModelTotals] = [:]
    var pendingModels: [String: TokenUsageModelTotals] = [:]
    var pendingCount: Int = 0
    var pendingReasons: [String: Int] = [:]
    var pendingCountsByModel: [String: Int] = [:]
    var pendingReasonsByModel: [String: [String: Int]] = [:]

    var id: Date { start }
    var totalTokens: Int64 { inputTokens + cacheTokens + outputTokens }
    var pendingTokens: Int64 {
        pendingModels.values.reduce(0) { $0 + $1.totalTokens }
    }

    mutating func add(_ record: TokenUsageRecord) {
        let modelID = TokenModelCatalog.canonicalID(record.model)
        switch record.accountingStatus.lowercased() {
        case TokenUsageRecord.includedAccountingStatus:
            inputTokens += record.normalizedInputTokens
            cacheTokens += record.cacheTokens
            outputTokens += max(0, record.outputTokens)
            models[modelID, default: TokenUsageModelTotals()].add(record)
        case TokenUsageRecord.pendingAccountingStatus:
            pendingModels[modelID, default: TokenUsageModelTotals()].add(record)
            pendingCount += 1
            let reason = record.accountingReason?.isEmpty == false
                ? record.accountingReason!
                : "待核对"
            pendingReasons[reason, default: 0] += 1
            pendingCountsByModel[modelID, default: 0] += 1
            var reasonCounts = pendingReasonsByModel[modelID, default: [:]]
            reasonCounts[reason, default: 0] += 1
            pendingReasonsByModel[modelID] = reasonCounts
        default:
            // Duplicate and otherwise excluded rows remain available to the
            // diagnostics view, but never inflate the main chart.
            break
        }
    }

    func filtered(model: String?) -> TokenUsageBucket {
        guard let model else { return self }
        let modelID = TokenModelCatalog.canonicalID(model)
        var copy = self
        let included = models[modelID] ?? TokenUsageModelTotals()
        copy.inputTokens = included.inputTokens
        copy.cacheTokens = included.cacheTokens
        copy.outputTokens = included.outputTokens
        copy.models = models[modelID].map { [modelID: $0] } ?? [:]
        copy.pendingModels = pendingModels[modelID].map { [modelID: $0] } ?? [:]
        copy.pendingCount = pendingCountsByModel[modelID] ?? 0
        copy.pendingReasons = pendingReasonsByModel[modelID] ?? [:]
        copy.pendingCountsByModel = pendingCountsByModel[modelID].map { [modelID: $0] } ?? [:]
        copy.pendingReasonsByModel = pendingReasonsByModel[modelID].map { [modelID: $0] } ?? [:]
        return copy
    }
}

struct TokenUsageSnapshot: Sendable, Equatable {
    let range: TokenUsageRange
    let buckets: [TokenUsageBucket]
    let collectedAt: Date

    var totalTokens: Int64 {
        buckets.reduce(0) { $0 + $1.totalTokens }
    }

    var modelIDs: [String] {
        Set(buckets.flatMap { $0.models.keys } + buckets.flatMap { $0.pendingModels.keys }).sorted()
    }

    var pendingReviewSummary: TokenUsageReviewSummary {
        TokenUsageReviewSummary(
            count: buckets.reduce(0) { $0 + $1.pendingCount },
            tokens: buckets.reduce(0) { $0 + $1.pendingTokens },
            reasons: buckets.reduce(into: [:]) { result, bucket in
                for (reason, count) in bucket.pendingReasons {
                    result[reason, default: 0] += count
                }
            }
        )
    }

    var reviewSummary: TokenUsageReviewSummary { pendingReviewSummary }

    func filtered(model: String?) -> TokenUsageSnapshot {
        guard model != nil else { return self }
        return TokenUsageSnapshot(
            range: range,
            buckets: buckets.map { $0.filtered(model: model) },
            collectedAt: collectedAt
        )
    }
}

enum TokenUsageAggregator {
    static func aggregate(
        _ records: [TokenUsageRecord],
        range: TokenUsageRange,
        now: Date,
        calendar: Calendar = .current
    ) -> TokenUsageSnapshot {
        let window = range.window(now: now, calendar: calendar)
        var buckets: [TokenUsageBucket] = []
        var bucketStart = window.start

        while bucketStart < window.displayEnd {
            buckets.append(TokenUsageBucket(start: bucketStart))
            guard let next = calendar.date(
                byAdding: window.component,
                value: 1,
                to: bucketStart
            ) else { break }
            bucketStart = next
        }

        let indices = Dictionary(uniqueKeysWithValues: buckets.indices.map {
            (buckets[$0].start, $0)
        })

        for record in records where record.timestamp >= window.queryStart && record.timestamp <= now {
            guard let start = calendar.dateInterval(
                of: window.component,
                for: record.timestamp
            )?.start,
            let index = indices[start] else { continue }
            buckets[index].add(record)
        }

        return TokenUsageSnapshot(range: range, buckets: buckets, collectedAt: now)
    }
}

protocol TokenUsageReading: Sendable {
    func records(from start: Date, through end: Date) async throws -> [TokenUsageRecord]
}

actor TokenUsageDatabase: TokenUsageReading {
    private static let currentSchemaVersion: Int32 = 5

    private let databaseURL: URL
    private let ccSwitchDatabaseURL: URL
    private let sessionRoots: SessionLogRoots
    private let fileManager: FileManager
    private var latestScanDiagnostics: [SessionScanDiagnostic] = []
    private var lastMigrationBackupURL: URL?

    init(
        databaseURL: URL = TokenUsageDatabase.defaultDatabaseURL(),
        ccSwitchDatabaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-switch/cc-switch.db"),
        sessionRoots: SessionLogRoots = .default(),
        fileManager: FileManager = .default
    ) {
        self.databaseURL = databaseURL
        self.ccSwitchDatabaseURL = ccSwitchDatabaseURL
        self.sessionRoots = sessionRoots
        self.fileManager = fileManager
    }

    func diagnostics() -> [SessionScanDiagnostic] {
        if latestScanDiagnostics.isEmpty, let persisted = try? loadScanDiagnostics() {
            latestScanDiagnostics = persisted
        }
        return latestScanDiagnostics
    }

    func latestMigrationBackupURL() -> URL? {
        lastMigrationBackupURL
    }

    func records(from start: Date, through end: Date) async throws -> [TokenUsageRecord] {
        try ensureLocalDatabase()

        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw TokenUsageReadError.openFailed(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)

        let sql = """
            SELECT created_at, app_type, model, input_tokens, output_tokens,
                   cache_read_tokens, cache_creation_tokens, input_token_semantics,
                   accounting_status, accounting_reason
            FROM token_usage_records
            WHERE created_at >= ?1 AND created_at <= ?2
            ORDER BY created_at
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(end.timeIntervalSince1970))

        var records: [TokenUsageRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let appType = sqlite3_column_text(statement, 1).map {
                    String(cString: $0)
                } ?? "unknown"
                let model = sqlite3_column_text(statement, 2).map {
                    String(cString: $0)
                } ?? "unknown"
                records.append(TokenUsageRecord(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(
                        sqlite3_column_int64(statement, 0)
                    )),
                    appType: appType,
                    inputTokens: max(0, sqlite3_column_int64(statement, 3)),
                    outputTokens: max(0, sqlite3_column_int64(statement, 4)),
                    cacheReadTokens: max(0, sqlite3_column_int64(statement, 5)),
                    cacheCreationTokens: max(0, sqlite3_column_int64(statement, 6)),
                    inputTokenSemantics: sqlite3_column_type(statement, 7) == SQLITE_NULL
                        ? 0
                        : sqlite3_column_int64(statement, 7),
                    model: model.isEmpty ? "unknown" : model,
                    accountingStatus: sqlite3_column_text(statement, 8).map {
                        String(cString: $0)
                    } ?? TokenUsageRecord.includedAccountingStatus,
                    accountingReason: sqlite3_column_text(statement, 9).map {
                        String(cString: $0)
                    }
                ))
            case SQLITE_DONE:
                return records
            default:
                throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    @discardableResult
    func syncFromSessionLogs(now: Date = Date()) throws -> Int {
        try ensureLocalDatabase()
        let persistedDiagnostics = try loadScanDiagnostics()
        let cursors = try sessionLogCursors()
        let scan = SessionUsageScanner.scan(
            roots: sessionRoots,
            fileManager: fileManager,
            existingCursors: cursors,
            now: Int64(now.timeIntervalSince1970)
        )
        // A scanner may report parser diagnostics against the symlink-resolved
        // source path while its cursor keeps the path used to discover the
        // file.  Compare canonical paths here so a successful rescan clears
        // the diagnostic regardless of which representation was persisted.
        let rescannedPaths = Set(scan.fileStates.map { canonicalDiagnosticPath($0.path) })
        var mergedDiagnostics = persistedDiagnostics.filter { diagnostic in
            !rescannedPaths.contains(canonicalDiagnosticPath(diagnostic.path))
        }
        for diagnostic in scan.diagnostics {
            let alreadyPresent = mergedDiagnostics.contains { existing in
                existing.reason == diagnostic.reason
                    && canonicalDiagnosticPath(existing.path) == canonicalDiagnosticPath(diagnostic.path)
            }
            if !alreadyPresent {
                mergedDiagnostics.append(diagnostic)
            }
        }
        latestScanDiagnostics = mergedDiagnostics.sorted {
            if $0.path == $1.path { return $0.reason < $1.reason }
            return $0.path < $1.path
        }
        return try insertSessionEntries(scan.entries, fileStates: scan.fileStates, now: now)
    }

    private func canonicalDiagnosticPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    @discardableResult
    func syncFromCCSwitch() throws -> Int {
        try syncFromCCSwitch(since: nil, forceFullSync: true)
    }

    private func syncFromCCSwitch(since minimumCreatedAt: Int64?, forceFullSync: Bool) throws -> Int {
        let migrated = try ensureLocalDatabase()
        let minimumCreatedAt = (forceFullSync || migrated) ? nil : minimumCreatedAt
        guard fileManager.fileExists(atPath: ccSwitchDatabaseURL.path) else {
            return 0
        }

        var source: OpaquePointer?
        let sourceStatus = sqlite3_open_v2(
            ccSwitchDatabaseURL.path,
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard sourceStatus == SQLITE_OK, let source else {
            let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let source { sqlite3_close(source) }
            throw TokenUsageReadError.openFailed(message)
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 500)

        var local: OpaquePointer?
        let localStatus = sqlite3_open_v2(
            databaseURL.path,
            &local,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard localStatus == SQLITE_OK, let local else {
            let message = local.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let local { sqlite3_close(local) }
            throw TokenUsageReadError.openFailed(message)
        }
        defer { sqlite3_close(local) }
        sqlite3_busy_timeout(local, 500)

        let sourceColumns = try tableColumns(in: source, table: "proxy_request_logs")
        let sql = Self.ccSwitchSelectSQL(
            sourceColumns: sourceColumns,
            minimumCreatedAt: minimumCreatedAt
        )
        var sourceStatement: OpaquePointer?
        guard sqlite3_prepare_v2(source, sql, -1, &sourceStatement, nil) == SQLITE_OK,
              let sourceStatement else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(source)))
        }
        defer { sqlite3_finalize(sourceStatement) }

        let insertSQL = """
            INSERT OR IGNORE INTO token_usage_records (
                request_id, provider_id, app_type, model, request_model,
                input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
                input_cost_usd, output_cost_usd, cache_read_cost_usd,
                cache_creation_cost_usd, total_cost_usd, latency_ms,
                first_token_ms, duration_ms, status_code, error_message,
                session_id, provider_type, is_streaming, cost_multiplier,
                created_at, data_source, pricing_model, input_token_semantics,
                is_final, accounting_status, accounting_reason, source_path,
                source_provenance, synced_from, synced_at
            ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
                ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27,
                0, 'included', NULL, NULL, 'cc-switch', 'cc-switch', ?28
            )
            """
        var insertStatement: OpaquePointer?
        guard sqlite3_prepare_v2(local, insertSQL, -1, &insertStatement, nil) == SQLITE_OK,
              let insertStatement else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(local)))
        }
        defer { sqlite3_finalize(insertStatement) }

        try execute("BEGIN IMMEDIATE", in: local)
        var importedCount = 0
        do {
            while true {
                switch sqlite3_step(sourceStatement) {
                case SQLITE_ROW:
                    sqlite3_reset(insertStatement)
                    sqlite3_clear_bindings(insertStatement)
                    bindSourceRow(sourceStatement, to: insertStatement)
                    sqlite3_bind_int64(insertStatement, 28, Int64(Date().timeIntervalSince1970))
                    guard sqlite3_step(insertStatement) == SQLITE_DONE else {
                        throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(local)))
                    }
                    importedCount += sqlite3_changes(local) > 0 ? 1 : 0
                case SQLITE_DONE:
                    try reconcileAccounting(in: local)
                    try execute("COMMIT", in: local)
                    if migrated || forceFullSync {
                        try setSchemaVersion(Self.currentSchemaVersion, in: local)
                    }
                    return importedCount
                default:
                    throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(source)))
                }
            }
        } catch {
            try? execute("ROLLBACK", in: local)
            throw error
        }
    }

    private func insertSessionEntries(
        _ entries: [SessionUsageEntry],
        fileStates: [SessionFileCursor],
        now: Date
    ) throws -> Int {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw TokenUsageReadError.openFailed(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)

        let insertSQL = """
            INSERT OR IGNORE INTO token_usage_records (
                request_id, provider_id, app_type, model, request_model,
                input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
                input_cost_usd, output_cost_usd, cache_read_cost_usd,
                cache_creation_cost_usd, total_cost_usd, latency_ms,
                first_token_ms, duration_ms, status_code, error_message,
                session_id, provider_type, is_streaming, cost_multiplier,
                created_at, data_source, pricing_model, input_token_semantics,
                is_final, accounting_status, accounting_reason, source_path,
                source_provenance, synced_from, synced_at
            ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, '0', '0', '0', '0', '0', 0, NULL, NULL,
                200, NULL, ?10, ?11, 1, '1.0', ?12, ?13, NULL, ?14, ?15, ?16, ?17, ?18,
                'session-logs', 'session-logs', ?19
            )
            """
        let upsertSQL = """
            INSERT INTO token_usage_records (
                request_id, provider_id, app_type, model, request_model,
                input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
                input_cost_usd, output_cost_usd, cache_read_cost_usd,
                cache_creation_cost_usd, total_cost_usd, latency_ms,
                first_token_ms, duration_ms, status_code, error_message,
                session_id, provider_type, is_streaming, cost_multiplier,
                created_at, data_source, pricing_model, input_token_semantics,
                is_final, accounting_status, accounting_reason, source_path,
                source_provenance, synced_from, synced_at
            ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, '0', '0', '0', '0', '0', 0, NULL, NULL,
                200, NULL, ?10, ?11, 1, '1.0', ?12, ?13, NULL, ?14, ?15, ?16, ?17, ?18,
                'session-logs', 'session-logs', ?19
            )
            ON CONFLICT(request_id) DO UPDATE SET
                model = excluded.model,
                input_tokens = excluded.input_tokens,
                output_tokens = excluded.output_tokens,
                cache_read_tokens = excluded.cache_read_tokens,
                cache_creation_tokens = excluded.cache_creation_tokens,
                input_token_semantics = excluded.input_token_semantics,
                is_final = excluded.is_final,
                accounting_status = excluded.accounting_status,
                accounting_reason = excluded.accounting_reason,
                source_path = excluded.source_path,
                source_provenance = CASE
                    WHEN source_provenance = 'cc-switch' THEN 'cc-switch,session-logs'
                    WHEN source_provenance LIKE '%session-logs%' THEN source_provenance
                    WHEN source_provenance IS NULL OR source_provenance = '' THEN 'session-logs'
                    ELSE source_provenance || ',session-logs'
                END,
                synced_from = 'session-logs',
                synced_at = excluded.synced_at
            WHERE (data_source = excluded.data_source OR synced_from = 'cc-switch')
              AND (
                excluded.is_final > is_final
                OR (
                    excluded.is_final = is_final
                    AND (
                        excluded.is_final = 1
                        OR (
                            excluded.input_tokens >= input_tokens
                            AND excluded.output_tokens >= output_tokens
                            AND excluded.cache_read_tokens >= cache_read_tokens
                            AND excluded.cache_creation_tokens >= cache_creation_tokens
                        )
                    )
                )
              )
              AND (
                input_tokens != excluded.input_tokens
                OR output_tokens != excluded.output_tokens
                OR cache_read_tokens != excluded.cache_read_tokens
                OR cache_creation_tokens != excluded.cache_creation_tokens
                OR input_token_semantics != excluded.input_token_semantics
                OR is_final != excluded.is_final
                OR model != excluded.model
                OR accounting_status != excluded.accounting_status
                OR COALESCE(accounting_reason, '') != COALESCE(excluded.accounting_reason, '')
                OR COALESCE(source_path, '') != COALESCE(excluded.source_path, '')
                OR synced_from != 'session-logs'
              )
            """

        var insertStatement: OpaquePointer?
        var upsertStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, insertSQL, -1, &insertStatement, nil) == SQLITE_OK,
              let insertStatement,
              sqlite3_prepare_v2(database, upsertSQL, -1, &upsertStatement, nil) == SQLITE_OK,
              let upsertStatement else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer {
            sqlite3_finalize(insertStatement)
            sqlite3_finalize(upsertStatement)
        }

        try execute("BEGIN IMMEDIATE", in: database)
        var importedCount = 0
        let syncedAt = Int64(now.timeIntervalSince1970)
        do {
            let loadedRecords = try loadExistingSessionRecords(in: database)
            var existingByRequestID = loadedRecords.byRequestID
            var existingByIdentity = loadedRecords.byIdentity
            let rewriteScopes = Set(entries.compactMap { entry -> String? in
                guard entry.dataSource == "codex_session"
                        || entry.appType.caseInsensitiveCompare("codex") == .orderedSame,
                      let existing = existingByRequestID[entry.requestID] else {
                    return nil
                }
                guard existing.identity.createdAt != entry.createdAt else { return nil }
                return rewriteScope(for: entry)
            })
            for entry in entries {
                // Every session source may discover a more complete value or
                // resolve a parent/replay relation on a later scan. Using the
                // guarded upsert for all entries preserves that transition;
                // replay events still have distinct request IDs and remain raw.
                let requestID = resolvedSessionRequestID(
                    for: entry,
                    byRequestID: existingByRequestID,
                    byIdentity: existingByIdentity,
                    rewriteScopes: rewriteScopes
                )
                let statement = upsertStatement
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bindText(requestID, to: statement, parameter: 1)
                bindText(entry.providerID, to: statement, parameter: 2)
                bindText(entry.appType, to: statement, parameter: 3)
                bindText(entry.model, to: statement, parameter: 4)
                bindText(entry.model, to: statement, parameter: 5)
                sqlite3_bind_int64(statement, 6, entry.inputTokens)
                sqlite3_bind_int64(statement, 7, entry.outputTokens)
                sqlite3_bind_int64(statement, 8, entry.cacheReadTokens)
                sqlite3_bind_int64(statement, 9, entry.cacheCreationTokens)
                if let sessionID = entry.sessionID {
                    bindText(sessionID, to: statement, parameter: 10)
                } else {
                    sqlite3_bind_null(statement, 10)
                }
                bindText(entry.providerType, to: statement, parameter: 11)
                sqlite3_bind_int64(statement, 12, entry.createdAt)
                bindText(entry.dataSource, to: statement, parameter: 13)
                sqlite3_bind_int64(statement, 14, entry.inputTokenSemantics)
                sqlite3_bind_int(statement, 15, entry.isFinal ? 1 : 0)
                bindText(entry.accountingStatus, to: statement, parameter: 16)
                if let reason = entry.accountingReason {
                    bindText(reason, to: statement, parameter: 17)
                } else {
                    sqlite3_bind_null(statement, 17)
                }
                if let sourcePath = entry.sourcePath {
                    bindText(sourcePath, to: statement, parameter: 18)
                } else {
                    sqlite3_bind_null(statement, 18)
                }
                sqlite3_bind_int64(statement, 19, syncedAt)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
                }
                let changed = sqlite3_changes(database) > 0
                importedCount += changed ? 1 : 0
                if changed {
                    indexSessionRecord(
                        requestID: requestID,
                        identity: SessionRecordIdentity(entry: entry),
                        byRequestID: &existingByRequestID,
                        byIdentity: &existingByIdentity
                    )
                }
            }

            var cursorStatement: OpaquePointer?
            let cursorSQL = """
                INSERT OR REPLACE INTO session_log_sync
                    (file_path, last_modified, last_line_offset, file_identity, file_size,
                     complete_byte_offset, tail_fingerprint, last_synced_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                """
            guard sqlite3_prepare_v2(database, cursorSQL, -1, &cursorStatement, nil) == SQLITE_OK,
                  let cursorStatement else {
                throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(cursorStatement) }
            for cursor in fileStates {
                sqlite3_reset(cursorStatement)
                sqlite3_clear_bindings(cursorStatement)
                bindText(cursor.path, to: cursorStatement, parameter: 1)
                sqlite3_bind_int64(cursorStatement, 2, cursor.lastModified)
                sqlite3_bind_int64(cursorStatement, 3, cursor.lastLineOffset)
                bindText(cursor.fileIdentity, to: cursorStatement, parameter: 4)
                sqlite3_bind_int64(cursorStatement, 5, cursor.fileSize)
                sqlite3_bind_int64(cursorStatement, 6, cursor.completeByteOffset)
                bindText(cursor.tailFingerprint, to: cursorStatement, parameter: 7)
                sqlite3_bind_int64(cursorStatement, 8, syncedAt)
                guard sqlite3_step(cursorStatement) == SQLITE_DONE else {
                    throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
                }
            }

            try persistScanDiagnostics(
                fileStates: fileStates,
                diagnostics: latestScanDiagnostics,
                in: database,
                observedAt: syncedAt
            )
            try reconcileAccounting(in: database)
            try execute("COMMIT", in: database)
            try setSchemaVersion(Self.currentSchemaVersion, in: database)
            return importedCount
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
    }

    private func sessionLogCursors() throws -> [String: SessionFileCursor] {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw TokenUsageReadError.openFailed(message)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            """
            SELECT file_path, last_modified, last_line_offset, file_identity,
                   file_size, complete_byte_offset, tail_fingerprint
            FROM session_log_sync
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var cursors: [String: SessionFileCursor] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            cursors[path] = SessionFileCursor(
                path: path,
                lastModified: sqlite3_column_int64(statement, 1),
                lastLineOffset: sqlite3_column_int64(statement, 2),
                fileIdentity: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "",
                fileSize: sqlite3_column_int64(statement, 4),
                completeByteOffset: sqlite3_column_int64(statement, 5),
                tailFingerprint: sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
            )
        }
        return cursors
    }

    private func loadScanDiagnostics() throws -> [SessionScanDiagnostic] {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw TokenUsageReadError.openFailed(message)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT file_path, reason FROM session_scan_diagnostics ORDER BY file_path, reason",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var diagnostics: [SessionScanDiagnostic] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 0),
                  let reason = sqlite3_column_text(statement, 1) else { continue }
            diagnostics.append(
                SessionScanDiagnostic(path: String(cString: path), reason: String(cString: reason))
            )
        }
        return diagnostics
    }

    private func bindText(_ text: String, to statement: OpaquePointer, parameter: Int32) {
        sqlite3_bind_text(statement, parameter, text, -1, SQLITE_TRANSIENT)
    }

    private func persistScanDiagnostics(
        fileStates: [SessionFileCursor],
        diagnostics: [SessionScanDiagnostic],
        in database: OpaquePointer,
        observedAt: Int64
    ) throws {
        guard !fileStates.isEmpty || !diagnostics.isEmpty else { return }
        try execute("DELETE FROM session_scan_diagnostics", in: database)
        var clear: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "DELETE FROM session_scan_diagnostics WHERE file_path = ?1",
            -1,
            &clear,
            nil
        ) == SQLITE_OK, let clear else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(clear) }
        for state in fileStates {
            sqlite3_reset(clear)
            sqlite3_clear_bindings(clear)
            bindText(state.path, to: clear, parameter: 1)
            guard sqlite3_step(clear) == SQLITE_DONE else {
                throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
            }
        }

        guard !diagnostics.isEmpty else { return }
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO session_scan_diagnostics (file_path, reason, observed_at) VALUES (?1, ?2, ?3)",
            -1,
            &insert,
            nil
        ) == SQLITE_OK, let insert else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(insert) }
        for diagnostic in diagnostics {
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            bindText(diagnostic.path, to: insert, parameter: 1)
            bindText(diagnostic.reason, to: insert, parameter: 2)
            sqlite3_bind_int64(insert, 3, observedAt)
            guard sqlite3_step(insert) == SQLITE_DONE else {
                throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        let baseURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL
            .appendingPathComponent("AgentMonitor", isDirectory: true)
            .appendingPathComponent("token-usage.db")
    }

    @discardableResult
    private func ensureLocalDatabase() throws -> Bool {
        let directoryURL = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let existedBeforeOpen = fileManager.fileExists(atPath: databaseURL.path)

        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw TokenUsageReadError.openFailed(message)
        }
        defer { sqlite3_close(database) }

        let previousVersion = try schemaVersion(in: database)
        if existedBeforeOpen, previousVersion < Self.currentSchemaVersion {
            try backupDatabaseBeforeMigration(source: database)
        }

        try execute("""
            CREATE TABLE IF NOT EXISTS token_usage_records (
                request_id TEXT PRIMARY KEY,
                provider_id TEXT NOT NULL DEFAULT '',
                app_type TEXT NOT NULL DEFAULT 'unknown',
                model TEXT NOT NULL DEFAULT '',
                request_model TEXT,
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read_tokens INTEGER NOT NULL DEFAULT 0,
                cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
                input_cost_usd TEXT NOT NULL DEFAULT '0',
                output_cost_usd TEXT NOT NULL DEFAULT '0',
                cache_read_cost_usd TEXT NOT NULL DEFAULT '0',
                cache_creation_cost_usd TEXT NOT NULL DEFAULT '0',
                total_cost_usd TEXT NOT NULL DEFAULT '0',
                latency_ms INTEGER NOT NULL DEFAULT 0,
                first_token_ms INTEGER,
                duration_ms INTEGER,
                status_code INTEGER NOT NULL DEFAULT 0,
                error_message TEXT,
                session_id TEXT,
                provider_type TEXT,
                is_streaming INTEGER NOT NULL DEFAULT 0,
                cost_multiplier TEXT NOT NULL DEFAULT '1.0',
                created_at INTEGER NOT NULL,
                data_source TEXT NOT NULL DEFAULT 'proxy',
                pricing_model TEXT,
                input_token_semantics INTEGER NOT NULL DEFAULT 0,
                is_final INTEGER NOT NULL DEFAULT 0,
                accounting_status TEXT NOT NULL DEFAULT 'included',
                accounting_reason TEXT,
                source_path TEXT,
                source_provenance TEXT NOT NULL DEFAULT 'cc-switch',
                synced_from TEXT NOT NULL DEFAULT 'cc-switch',
                synced_at INTEGER NOT NULL
            )
            """, in: database)
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_token_usage_records_created_at
            ON token_usage_records(created_at)
            """, in: database)
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_token_usage_records_app_created_at
            ON token_usage_records(app_type, created_at DESC)
            """, in: database)
        try execute("""
            CREATE TABLE IF NOT EXISTS session_log_sync (
                file_path TEXT PRIMARY KEY,
                last_modified INTEGER NOT NULL,
                last_line_offset INTEGER NOT NULL,
                file_identity TEXT NOT NULL DEFAULT '',
                file_size INTEGER NOT NULL DEFAULT 0,
                complete_byte_offset INTEGER NOT NULL DEFAULT 0,
                tail_fingerprint TEXT NOT NULL DEFAULT '',
                last_synced_at INTEGER NOT NULL
            )
            """, in: database)
        try execute("""
            CREATE TABLE IF NOT EXISTS session_scan_diagnostics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_path TEXT NOT NULL,
                reason TEXT NOT NULL,
                observed_at INTEGER NOT NULL
            )
            """, in: database)

        var columns = try tableColumns(in: database, table: "token_usage_records")
        let tokenColumnDefinitions: [(String, String)] = [
            ("input_token_semantics", "INTEGER NOT NULL DEFAULT 0"),
            ("is_final", "INTEGER NOT NULL DEFAULT 0"),
            ("accounting_status", "TEXT NOT NULL DEFAULT 'included'"),
            ("accounting_reason", "TEXT"),
            ("source_path", "TEXT"),
            ("source_provenance", "TEXT NOT NULL DEFAULT 'cc-switch'")
        ]
        for (name, definition) in tokenColumnDefinitions where !columns.contains(name) {
            try execute(
                "ALTER TABLE token_usage_records ADD COLUMN \(name) \(definition)",
                in: database
            )
            columns.insert(name)
        }
        try execute("""
            UPDATE token_usage_records
            SET source_provenance = synced_from
            WHERE source_provenance = 'cc-switch' AND synced_from != 'cc-switch'
            """, in: database)

        let cursorColumns = try tableColumns(in: database, table: "session_log_sync")
        let cursorColumnDefinitions: [(String, String)] = [
            ("file_identity", "TEXT NOT NULL DEFAULT ''"),
            ("file_size", "INTEGER NOT NULL DEFAULT 0"),
            ("complete_byte_offset", "INTEGER NOT NULL DEFAULT 0"),
            ("tail_fingerprint", "TEXT NOT NULL DEFAULT ''")
        ]
        for (name, definition) in cursorColumnDefinitions where !cursorColumns.contains(name) {
            try execute(
                "ALTER TABLE session_log_sync ADD COLUMN \(name) \(definition)",
                in: database
            )
        }

        let needsMigration = previousVersion < Self.currentSchemaVersion
        if needsMigration {
            try execute("BEGIN IMMEDIATE", in: database)
            do {
                if previousVersion < 4 {
                    // Old byte/line cursors cannot prove that an append starts
                    // at a complete JSONL line. Reset them once; raw usage rows
                    // remain.
                    try execute("DELETE FROM session_log_sync", in: database)
                } else if previousVersion < 5 {
                    // Schema 4 treated Codex's compound parent_child rollout
                    // filenames as missing metadata. Reparse only those known
                    // affected files so the one-time repair stays bounded.
                    try execute("""
                        DELETE FROM session_log_sync
                        WHERE file_path IN (
                            SELECT DISTINCT source_path
                            FROM token_usage_records
                            WHERE accounting_status = 'pending'
                              AND accounting_reason = 'missing_session_meta'
                              AND source_path IS NOT NULL
                            UNION
                            SELECT file_path
                            FROM session_scan_diagnostics
                            WHERE reason = 'thread_id_mismatch'
                        )
                        """, in: database)
                }
                try reconcileAccounting(in: database)
                try setSchemaVersion(Self.currentSchemaVersion, in: database)
                try execute("COMMIT", in: database)
            } catch {
                try? execute("ROLLBACK", in: database)
                throw error
            }
        }

        return needsMigration
    }

    private func backupDatabaseBeforeMigration(source: OpaquePointer) throws {
        let backupURL = databaseURL
            .deletingPathExtension()
            .appendingPathExtension("backup-v\(Self.currentSchemaVersion)-\(UUID().uuidString).db")
        var destination: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            backupURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let destination { sqlite3_close(destination) }
            throw TokenUsageReadError.openFailed(message)
        }

        let backup = sqlite3_backup_init(destination, "main", source, "main")
        guard backup != nil else {
            let message = String(cString: sqlite3_errmsg(destination))
            sqlite3_close(destination)
            try? fileManager.removeItem(at: backupURL)
            throw TokenUsageReadError.queryFailed(message)
        }
        let backupStatus = sqlite3_backup_step(backup, -1)
        let finishStatus = sqlite3_backup_finish(backup)
        guard backupStatus == SQLITE_DONE || backupStatus == SQLITE_OK,
              finishStatus == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(destination))
            sqlite3_close(destination)
            try? fileManager.removeItem(at: backupURL)
            throw TokenUsageReadError.queryFailed(message)
        }
        sqlite3_close(destination)

        try verifyBackup(at: backupURL)
        lastMigrationBackupURL = backupURL
    }

    private func verifyBackup(at url: URL) throws {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard status == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw TokenUsageReadError.openFailed(message)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0),
              String(cString: text).caseInsensitiveCompare("ok") == .orderedSame else {
            throw TokenUsageReadError.queryFailed("迁移备份完整性校验失败")
        }
    }

    private struct AccountingRow {
        let requestID: String
        let syncedFrom: String
        let dataSource: String
        let sourceProvenance: String
        let sessionID: String?
        let appType: String
        let model: String
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheReadTokens: Int64
        let cacheCreationTokens: Int64
        let inputTokenSemantics: Int64
        let createdAt: Int64
        let accountingStatus: String
        let accountingReason: String?

        var normalizedInputTokens: Int64 {
            TokenUsageRecord.normalizedInput(
                appType: appType,
                inputTokens: inputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                semantics: inputTokenSemantics
            )
        }

        var cacheTokens: Int64 {
            let record = TokenUsageRecord(
                timestamp: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                appType: appType,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                inputTokenSemantics: inputTokenSemantics,
                model: model
            )
            return record.cacheTokens
        }

        var usageKey: UsageKey {
            UsageKey(
                model: canonicalModel,
                input: normalizedInputTokens,
                cache: cacheTokens,
                output: outputTokens
            )
        }

        var canonicalModel: String {
            TokenModelCatalog.canonicalID(model)
        }
    }

    /// Identity used only when a Codex file is rewritten and its event-index
    /// request IDs shift.  The request ID remains the primary key; this
    /// secondary identity lets us reassociate an exact event that moved to a
    /// different index without merging ordinary equal-counter calls.
    private struct SessionRecordIdentity: Hashable {
        let appType: String
        let dataSource: String
        let sessionID: String?
        let model: String
        let createdAt: Int64
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheReadTokens: Int64
        let cacheCreationTokens: Int64
        let inputTokenSemantics: Int64

        init(entry: SessionUsageEntry) {
            appType = entry.appType
            dataSource = entry.dataSource
            sessionID = entry.sessionID
            model = entry.model
            createdAt = entry.createdAt
            inputTokens = entry.inputTokens
            outputTokens = entry.outputTokens
            cacheReadTokens = entry.cacheReadTokens
            cacheCreationTokens = entry.cacheCreationTokens
            inputTokenSemantics = entry.inputTokenSemantics
        }

        init(
            appType: String,
            dataSource: String,
            sessionID: String?,
            model: String,
            createdAt: Int64,
            inputTokens: Int64,
            outputTokens: Int64,
            cacheReadTokens: Int64,
            cacheCreationTokens: Int64,
            inputTokenSemantics: Int64
        ) {
            self.appType = appType
            self.dataSource = dataSource
            self.sessionID = sessionID
            self.model = model
            self.createdAt = createdAt
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.inputTokenSemantics = inputTokenSemantics
        }
    }

    private struct ExistingSessionRecord {
        let requestID: String
        let identity: SessionRecordIdentity
    }

    private func loadExistingSessionRecords(
        in database: OpaquePointer
    ) throws -> (
        byRequestID: [String: ExistingSessionRecord],
        byIdentity: [SessionRecordIdentity: [String]]
    ) {
        let sql = """
            SELECT request_id, app_type, data_source, session_id, model, created_at,
                   input_tokens, output_tokens, cache_read_tokens,
                   cache_creation_tokens, input_token_semantics
            FROM token_usage_records
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var byRequestID: [String: ExistingSessionRecord] = [:]
        var byIdentity: [SessionRecordIdentity: [String]] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
            }
            guard let requestText = sqlite3_column_text(statement, 0) else { continue }
            let requestID = String(cString: requestText)
            guard !requestID.isEmpty else { continue }
            let identity = SessionRecordIdentity(
                appType: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "unknown",
                dataSource: sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "",
                sessionID: sqlite3_column_text(statement, 3).map { String(cString: $0) },
                model: sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "",
                createdAt: sqlite3_column_int64(statement, 5),
                inputTokens: sqlite3_column_int64(statement, 6),
                outputTokens: sqlite3_column_int64(statement, 7),
                cacheReadTokens: sqlite3_column_int64(statement, 8),
                cacheCreationTokens: sqlite3_column_int64(statement, 9),
                inputTokenSemantics: sqlite3_column_int64(statement, 10)
            )
            byRequestID[requestID] = ExistingSessionRecord(
                requestID: requestID,
                identity: identity
            )
            byIdentity[identity, default: []].append(requestID)
        }
        return (byRequestID, byIdentity)
    }

    private func resolvedSessionRequestID(
        for entry: SessionUsageEntry,
        byRequestID: [String: ExistingSessionRecord],
        byIdentity: [SessionRecordIdentity: [String]],
        rewriteScopes: Set<String>
    ) -> String {
        guard entry.dataSource == "codex_session"
                || entry.appType.caseInsensitiveCompare("codex") == .orderedSame else {
            return entry.requestID
        }
        let identity = SessionRecordIdentity(entry: entry)
        guard let existing = byRequestID[entry.requestID] else {
            // A newly assigned index is only reassociated when another event
            // in this scan proves that indices shifted. Without that evidence
            // an identical call is an independent request.
            if let scope = rewriteScope(for: entry),
               rewriteScopes.contains(scope),
               let candidates = byIdentity[identity], candidates.count == 1 {
                return candidates[0]
            }
            return entry.requestID
        }
        // A stable event index plus timestamp is stronger evidence than a
        // changed model/counter payload. Reuse the ID for historical
        // corrections and for late authoritative values.
        if existing.identity == identity || existing.identity.createdAt == identity.createdAt {
            return entry.requestID
        }

        // A rewritten Codex file can move an event to another index. Reuse an
        // existing ID only when the complete source/thread/time/counter
        // identity is unique. Equal counters alone never trigger this path.
        if let candidates = byIdentity[identity], candidates.count == 1 {
            return candidates[0]
        }

        // Preserve the old indexed row and give the rewritten event a stable
        // deterministic ID. The timestamp is human-readable; the identity
        // digest handles two different events sharing that second.
        let timestampID = "\(entry.requestID):t\(entry.createdAt)"
        guard byRequestID[timestampID] != nil else { return timestampID }
        let fingerprint = sessionIdentityFingerprint(identity)
        let fingerprintID = "\(timestampID):u\(fingerprint)"
        guard byRequestID[fingerprintID] != nil else { return fingerprintID }
        var suffix = 2
        while byRequestID["\(fingerprintID):\(suffix)"] != nil {
            suffix += 1
        }
        return "\(fingerprintID):\(suffix)"
    }

    private func rewriteScope(for entry: SessionUsageEntry) -> String? {
        if let sessionID = entry.sessionID, !sessionID.isEmpty {
            if let sourcePath = entry.sourcePath, !sourcePath.isEmpty {
                return "session:\(sessionID)|path:\(sourcePath)"
            }
            return "session:\(sessionID)"
        }
        if let sourcePath = entry.sourcePath, !sourcePath.isEmpty {
            return "path:\(sourcePath)"
        }
        return nil
    }

    private func sessionIdentityFingerprint(_ identity: SessionRecordIdentity) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func absorb(_ value: String) {
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0
            hash &*= 1_099_511_628_211
        }
        absorb(identity.appType)
        absorb(identity.dataSource)
        absorb(identity.sessionID ?? "")
        absorb(identity.model)
        absorb(String(identity.createdAt))
        absorb(String(identity.inputTokens))
        absorb(String(identity.outputTokens))
        absorb(String(identity.cacheReadTokens))
        absorb(String(identity.cacheCreationTokens))
        absorb(String(identity.inputTokenSemantics))
        return String(hash, radix: 16)
    }

    private func indexSessionRecord(
        requestID: String,
        identity: SessionRecordIdentity,
        byRequestID: inout [String: ExistingSessionRecord],
        byIdentity: inout [SessionRecordIdentity: [String]]
    ) {
        if let previous = byRequestID[requestID], previous.identity != identity {
            byIdentity[previous.identity]?.removeAll { $0 == requestID }
        }
        byRequestID[requestID] = ExistingSessionRecord(requestID: requestID, identity: identity)
        if !byIdentity[identity, default: []].contains(requestID) {
            byIdentity[identity, default: []].append(requestID)
        }
    }

    private struct UsageKey: Hashable {
        let model: String
        let input: Int64
        let cache: Int64
        let output: Int64
    }

    private func reconcileAccounting(in database: OpaquePointer) throws {
        let sql = """
            SELECT request_id, synced_from, session_id, app_type, model,
                   input_tokens, output_tokens, cache_read_tokens,
                   cache_creation_tokens, input_token_semantics, created_at,
                   accounting_status, accounting_reason, data_source, source_provenance
            FROM token_usage_records
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [AccountingRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let requestID = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            guard !requestID.isEmpty else { continue }
            rows.append(
                AccountingRow(
                    requestID: requestID,
                    syncedFrom: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                    dataSource: sqlite3_column_text(statement, 13).map { String(cString: $0) } ?? "",
                    sourceProvenance: sqlite3_column_text(statement, 14).map { String(cString: $0) } ?? "",
                    sessionID: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                    appType: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "unknown",
                    model: sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "unknown",
                    inputTokens: max(0, sqlite3_column_int64(statement, 5)),
                    outputTokens: max(0, sqlite3_column_int64(statement, 6)),
                    cacheReadTokens: max(0, sqlite3_column_int64(statement, 7)),
                    cacheCreationTokens: max(0, sqlite3_column_int64(statement, 8)),
                    inputTokenSemantics: sqlite3_column_int64(statement, 9),
                    createdAt: sqlite3_column_int64(statement, 10),
                    accountingStatus: sqlite3_column_text(statement, 11).map {
                        String(cString: $0)
                    } ?? TokenUsageRecord.includedAccountingStatus,
                    accountingReason: sqlite3_column_text(statement, 12).map {
                        String(cString: $0)
                    }
                )
            )
        }

        var changes: [(id: String, status: String, reason: String?)] = []
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.requestID, $0) })
        for row in rows {
            guard let pairedID = codexThreadV1PairID(for: row.requestID),
                  let paired = byID[pairedID],
                  exactMatch(row, paired),
                  row.accountingStatus != TokenUsageRecord.duplicateAccountingStatus else {
                continue
            }
            changes.append((row.requestID, TokenUsageRecord.duplicateAccountingStatus, "codex_thread_v1_exact_pair"))
        }

        let sessionRows = rows.filter {
            $0.accountingStatus == TokenUsageRecord.includedAccountingStatus
                && ["session_log", "claude_session", "codex_session", "grok_session", "gemini_session"].contains($0.dataSource)
        }
        var sessionsByUsage: [UsageKey: [AccountingRow]] = [:]
        for session in sessionRows {
            sessionsByUsage[session.usageKey, default: []].append(session)
        }
        let proxyRows = rows.filter {
            $0.syncedFrom == "cc-switch"
                && $0.dataSource == "proxy"
                && ($0.accountingStatus == TokenUsageRecord.includedAccountingStatus
                    || $0.accountingStatus == TokenUsageRecord.pendingAccountingStatus)
        }
        var suspectedByProxy: [String: [AccountingRow]] = [:]
        var proxyCountBySessionRequestID: [String: Int] = [:]
        for proxy in proxyRows {
            let candidates = (sessionsByUsage[proxy.usageKey] ?? []).filter {
                suspectedCrossSourceMatch(proxy, $0)
            }
            suspectedByProxy[proxy.requestID] = candidates
            for candidate in candidates {
                proxyCountBySessionRequestID[candidate.requestID, default: 0] += 1
            }
        }
        for row in proxyRows {
            let candidates = suspectedByProxy[row.requestID] ?? []
            if candidates.contains(where: { exactCrossSourceMatch(row, $0) }) {
                changes.append((row.requestID, TokenUsageRecord.duplicateAccountingStatus, "session_log_authoritative"))
            } else if candidates.count == 1,
                      let candidate = candidates.first,
                      proxyCountBySessionRequestID[candidate.requestID] == 1 {
                // Older CC Switch rows cannot expose a direct request-ID map.
                // Exact normalized counters, canonical model, a <=5 second
                // timestamp gap, and a globally one-to-one pairing together
                // provide deterministic cross-source duplicate evidence.
                changes.append((row.requestID, TokenUsageRecord.duplicateAccountingStatus, "unique_cross_source_exact_pair"))
            } else if !candidates.isEmpty {
                changes.append((row.requestID, TokenUsageRecord.pendingAccountingStatus, "suspected_proxy_overlap"))
            } else if row.accountingStatus == TokenUsageRecord.pendingAccountingStatus,
                      row.accountingReason == "suspected_proxy_overlap" {
                // Do not leave a prior candidate sticky after the local
                // authoritative row is removed or reclassified.
                changes.append((row.requestID, TokenUsageRecord.includedAccountingStatus, nil))
            }
        }

        guard !changes.isEmpty else { return }
        let updateSQL = """
            UPDATE token_usage_records
            SET accounting_status = ?1, accounting_reason = ?2
            WHERE request_id = ?3
            """
        var update: OpaquePointer?
        guard sqlite3_prepare_v2(database, updateSQL, -1, &update, nil) == SQLITE_OK,
              let update else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(update) }
        for change in changes {
            sqlite3_reset(update)
            sqlite3_clear_bindings(update)
            bindText(change.status, to: update, parameter: 1)
            if let reason = change.reason {
                bindText(reason, to: update, parameter: 2)
            } else {
                sqlite3_bind_null(update, 2)
            }
            bindText(change.id, to: update, parameter: 3)
            guard sqlite3_step(update) == SQLITE_DONE else {
                throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private func codexThreadV1PairID(for requestID: String) -> String? {
        let oldPrefix = "codex_session:"
        let newPrefix = "codex_session:thread-v1:"
        guard requestID.hasPrefix(oldPrefix), !requestID.hasPrefix(newPrefix) else { return nil }
        let suffix = String(requestID.dropFirst(oldPrefix.count))
        guard !suffix.isEmpty else { return nil }
        return newPrefix + suffix
    }

    private func exactMatch(_ lhs: AccountingRow, _ rhs: AccountingRow) -> Bool {
        guard let lhsSession = lhs.sessionID, !lhsSession.isEmpty,
              let rhsSession = rhs.sessionID, !rhsSession.isEmpty,
              lhsSession.caseInsensitiveCompare(rhsSession) == .orderedSame else {
            return false
        }
        return lhs.appType.caseInsensitiveCompare(rhs.appType) == .orderedSame
            && lhs.canonicalModel == rhs.canonicalModel
            && lhs.createdAt == rhs.createdAt
            && lhs.inputTokens == rhs.inputTokens
            && lhs.outputTokens == rhs.outputTokens
            && lhs.cacheReadTokens == rhs.cacheReadTokens
            && lhs.cacheCreationTokens == rhs.cacheCreationTokens
            && lhs.normalizedInputTokens == rhs.normalizedInputTokens
            && lhs.cacheTokens == rhs.cacheTokens
    }

    private func exactCrossSourceMatch(_ proxy: AccountingRow, _ session: AccountingRow) -> Bool {
        guard session.syncedFrom == "session-logs",
              proxy.dataSource == "proxy",
              let pairedID = codexThreadV1PairID(for: proxy.requestID),
              session.requestID == pairedID,
              exactUsage(proxy, session) else { return false }
        return true
    }

    private func suspectedCrossSourceMatch(_ proxy: AccountingRow, _ session: AccountingRow) -> Bool {
        guard session.syncedFrom == "session-logs",
              proxy.canonicalModel == session.canonicalModel,
              abs(proxy.createdAt - session.createdAt) <= 5 else { return false }
        return exactUsage(proxy, session)
    }

    private func exactUsage(_ lhs: AccountingRow, _ rhs: AccountingRow) -> Bool {
        lhs.normalizedInputTokens == rhs.normalizedInputTokens
            && lhs.cacheTokens == rhs.cacheTokens
            && lhs.outputTokens == rhs.outputTokens
    }

    private func schemaVersion(in database: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    private func setSchemaVersion(_ version: Int32, in database: OpaquePointer) throws {
        try execute("PRAGMA user_version = \(version)", in: database)
    }

    private func tableColumns(in database: OpaquePointer, table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        guard !columns.isEmpty else {
            throw TokenUsageReadError.queryFailed("缺少 proxy_request_logs 表")
        }
        return columns
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw TokenUsageReadError.queryFailed(message)
        }
    }

    private func bindSourceRow(_ source: OpaquePointer, to destination: OpaquePointer) {
        for column in Int32(0)..<Int32(27) {
            bindColumn(column, from: source, to: destination, parameter: column + 1)
        }
    }

    private func bindColumn(
        _ column: Int32,
        from source: OpaquePointer,
        to destination: OpaquePointer,
        parameter: Int32
    ) {
        switch sqlite3_column_type(source, column) {
        case SQLITE_NULL:
            sqlite3_bind_null(destination, parameter)
        case SQLITE_INTEGER:
            sqlite3_bind_int64(destination, parameter, sqlite3_column_int64(source, column))
        default:
            let text = sqlite3_column_text(source, column).map { String(cString: $0) } ?? ""
            sqlite3_bind_text(destination, parameter, text, -1, SQLITE_TRANSIENT)
        }
    }

    private static func ccSwitchSelectSQL(
        sourceColumns: Set<String>,
        minimumCreatedAt: Int64? = nil
    ) -> String {
        let fields: [(String, String)] = [
            ("request_id", requestIDExpression(sourceColumns: sourceColumns)),
            ("provider_id", "''"),
            ("app_type", "'unknown'"),
            ("model", "''"),
            ("request_model", "NULL"),
            ("input_tokens", "0"),
            ("output_tokens", "0"),
            ("cache_read_tokens", "0"),
            ("cache_creation_tokens", "0"),
            ("input_cost_usd", "'0'"),
            ("output_cost_usd", "'0'"),
            ("cache_read_cost_usd", "'0'"),
            ("cache_creation_cost_usd", "'0'"),
            ("total_cost_usd", "'0'"),
            ("latency_ms", "0"),
            ("first_token_ms", "NULL"),
            ("duration_ms", "NULL"),
            ("status_code", "0"),
            ("error_message", "NULL"),
            ("session_id", "NULL"),
            ("provider_type", "NULL"),
            ("is_streaming", "0"),
            ("cost_multiplier", "'1.0'"),
            ("created_at", "0"),
            ("data_source", "'proxy'"),
            ("pricing_model", "NULL"),
            ("input_token_semantics", "0")
        ]

        let selectList = fields.map { name, fallback in
            if sourceColumns.contains(name) {
                return name
            }
            return "\(fallback) AS \(name)"
        }.joined(separator: ", ")
        let whereClause: String
        if let minimumCreatedAt, sourceColumns.contains("created_at") {
            whereClause = " WHERE created_at >= \(minimumCreatedAt)"
        } else {
            whereClause = ""
        }
        return "SELECT \(selectList) FROM proxy_request_logs\(whereClause) ORDER BY created_at"
    }

    private static func requestIDExpression(sourceColumns: Set<String>) -> String {
        guard !sourceColumns.contains("request_id") else { return "request_id" }
        let appType = sourceColumns.contains("app_type") ? "app_type" : "'unknown'"
        let dataSource = sourceColumns.contains("data_source") ? "COALESCE(data_source, 'proxy')" : "'proxy'"
        let inputTokens = sourceColumns.contains("input_tokens") ? "input_tokens" : "0"
        let outputTokens = sourceColumns.contains("output_tokens") ? "output_tokens" : "0"
        let cacheReadTokens = sourceColumns.contains("cache_read_tokens") ? "cache_read_tokens" : "0"
        let cacheCreationTokens = sourceColumns.contains("cache_creation_tokens") ? "cache_creation_tokens" : "0"
        let createdAt = sourceColumns.contains("created_at") ? "created_at" : "0"
        return """
            \(appType) || ':' || \(dataSource) || ':' || \(inputTokens) || ':' ||
            \(outputTokens) || ':' || \(cacheReadTokens) || ':' ||
            \(cacheCreationTokens) || ':' || \(createdAt)
            """
    }
}

@MainActor
final class TokenUsageStore: ObservableObject {
    @Published private(set) var snapshot: TokenUsageSnapshot?
    @Published private(set) var errorDescription: String?
    @Published private(set) var scanDiagnostics: [SessionScanDiagnostic] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSyncing = false

    private let reader: any TokenUsageReading
    private let calendar: Calendar
    private var requestID = 0
    let supportsCCSwitchSync: Bool

    init(
        reader: any TokenUsageReading = TokenUsageDatabase(),
        calendar: Calendar = .current
    ) {
        self.reader = reader
        self.calendar = calendar
        self.supportsCCSwitchSync = reader is TokenUsageDatabase
    }

    func refresh(range: TokenUsageRange, now: Date = Date()) async {
        requestID += 1
        let currentRequestID = requestID
        isRefreshing = true
        errorDescription = nil
        defer {
            if currentRequestID == requestID {
                isRefreshing = false
            }
        }

        let window = range.window(now: now, calendar: calendar)
        do {
            if let database = reader as? TokenUsageDatabase {
                _ = try await database.syncFromSessionLogs(now: now)
                scanDiagnostics = await database.diagnostics()
            }
            let records = try await reader.records(from: window.queryStart, through: now)
            guard currentRequestID == requestID else { return }
            snapshot = TokenUsageAggregator.aggregate(
                records,
                range: range,
                now: now,
                calendar: calendar
            )
        } catch {
            guard currentRequestID == requestID else { return }
            errorDescription = (error as? LocalizedError)?.errorDescription ?? "无法读取 Token 用量"
        }
    }

    func syncFromCCSwitch(range: TokenUsageRange, now: Date = Date()) async {
        guard !isSyncing else { return }
        guard let database = reader as? TokenUsageDatabase else {
            errorDescription = "当前 Token 数据源不支持 CC Switch 同步"
            return
        }

        isSyncing = true
        errorDescription = nil
        defer { isSyncing = false }

        do {
            _ = try await database.syncFromCCSwitch()
            await refresh(range: range, now: now)
        } catch {
            errorDescription = (error as? LocalizedError)?.errorDescription ?? "无法同步 CC Switch 数据"
        }
    }
}

private struct TokenUsageWindow {
    let queryStart: Date
    let start: Date
    let displayEnd: Date
    let component: Calendar.Component
}

private enum TokenUsageReadError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed:
            "无法打开 Token 用量数据库"
        case .queryFailed:
            "无法读取 Token 用量数据"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
