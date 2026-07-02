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
            let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            let end = calendar.date(byAdding: .hour, value: 1, to: currentHour) ?? now
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

struct TokenUsageRecord: Sendable, Equatable {
    let timestamp: Date
    let appType: String
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64

    var normalizedInputTokens: Int64 {
        guard appType.caseInsensitiveCompare("codex") == .orderedSame else {
            return inputTokens
        }
        return max(0, inputTokens - cacheTokens)
    }

    var cacheTokens: Int64 {
        cacheReadTokens + cacheCreationTokens
    }
}

struct TokenUsageBucket: Identifiable, Sendable, Equatable {
    let start: Date
    var inputTokens: Int64 = 0
    var cacheTokens: Int64 = 0
    var outputTokens: Int64 = 0

    var id: Date { start }
    var totalTokens: Int64 { inputTokens + cacheTokens + outputTokens }

    mutating func add(_ record: TokenUsageRecord) {
        inputTokens += record.normalizedInputTokens
        cacheTokens += record.cacheTokens
        outputTokens += record.outputTokens
    }
}

struct TokenUsageSnapshot: Sendable, Equatable {
    let range: TokenUsageRange
    let buckets: [TokenUsageBucket]
    let collectedAt: Date

    var totalTokens: Int64 {
        buckets.reduce(0) { $0 + $1.totalTokens }
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
    private let databaseURL: URL
    private let ccSwitchDatabaseURL: URL
    private let fileManager: FileManager

    init(
        databaseURL: URL = TokenUsageDatabase.defaultDatabaseURL(),
        ccSwitchDatabaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-switch/cc-switch.db"),
        fileManager: FileManager = .default
    ) {
        self.databaseURL = databaseURL
        self.ccSwitchDatabaseURL = ccSwitchDatabaseURL
        self.fileManager = fileManager
    }

    func records(from start: Date, through end: Date) async throws -> [TokenUsageRecord] {
        try ensureLocalDatabase()
        if fileManager.fileExists(atPath: ccSwitchDatabaseURL.path) {
            _ = try syncFromCCSwitch()
        }

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
            SELECT created_at, app_type, input_tokens, output_tokens,
                   cache_read_tokens, cache_creation_tokens
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
                records.append(TokenUsageRecord(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(
                        sqlite3_column_int64(statement, 0)
                    )),
                    appType: appType,
                    inputTokens: max(0, sqlite3_column_int64(statement, 2)),
                    outputTokens: max(0, sqlite3_column_int64(statement, 3)),
                    cacheReadTokens: max(0, sqlite3_column_int64(statement, 4)),
                    cacheCreationTokens: max(0, sqlite3_column_int64(statement, 5))
                ))
            case SQLITE_DONE:
                return records
            default:
                throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    @discardableResult
    func syncFromCCSwitch() throws -> Int {
        try ensureLocalDatabase()
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
        let sql = Self.ccSwitchSelectSQL(sourceColumns: sourceColumns)
        var sourceStatement: OpaquePointer?
        guard sqlite3_prepare_v2(source, sql, -1, &sourceStatement, nil) == SQLITE_OK,
              let sourceStatement else {
            throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(source)))
        }
        defer { sqlite3_finalize(sourceStatement) }

        let insertSQL = """
            INSERT OR REPLACE INTO token_usage_records (
                request_id, provider_id, app_type, model, request_model,
                input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
                input_cost_usd, output_cost_usd, cache_read_cost_usd,
                cache_creation_cost_usd, total_cost_usd, latency_ms,
                first_token_ms, duration_ms, status_code, error_message,
                session_id, provider_type, is_streaming, cost_multiplier,
                created_at, data_source, pricing_model, synced_from, synced_at
            ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
                ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26,
                'cc-switch', ?27
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
                    sqlite3_bind_int64(insertStatement, 27, Int64(Date().timeIntervalSince1970))
                    guard sqlite3_step(insertStatement) == SQLITE_DONE else {
                        throw TokenUsageReadError.queryFailed(String(cString: sqlite3_errmsg(local)))
                    }
                    importedCount += sqlite3_changes(local) > 0 ? 1 : 0
                case SQLITE_DONE:
                    try execute("COMMIT", in: local)
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

    private func ensureLocalDatabase() throws {
        let directoryURL = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

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
        for column in Int32(0)..<Int32(26) {
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

    private static func ccSwitchSelectSQL(sourceColumns: Set<String>) -> String {
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
            ("pricing_model", "NULL")
        ]

        let selectList = fields.map { name, fallback in
            if sourceColumns.contains(name) {
                return name
            }
            return "\(fallback) AS \(name)"
        }.joined(separator: ", ")
        return "SELECT \(selectList) FROM proxy_request_logs ORDER BY created_at"
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
    @Published private(set) var isRefreshing = false

    private let reader: any TokenUsageReading
    private let calendar: Calendar
    private var requestID = 0

    init(
        reader: any TokenUsageReading = TokenUsageDatabase(),
        calendar: Calendar = .current
    ) {
        self.reader = reader
        self.calendar = calendar
    }

    func refresh(range: TokenUsageRange, now: Date = Date()) async {
        requestID += 1
        let currentRequestID = requestID
        if snapshot?.range != range {
            snapshot = nil
        }
        isRefreshing = true
        errorDescription = nil
        defer {
            if currentRequestID == requestID {
                isRefreshing = false
            }
        }

        let window = range.window(now: now, calendar: calendar)
        do {
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
