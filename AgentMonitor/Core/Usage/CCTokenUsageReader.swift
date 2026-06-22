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
            return TokenUsageWindow(start: start, displayEnd: end, component: .hour)
        case .last24Hours:
            let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            let start = calendar.date(byAdding: .hour, value: -23, to: currentHour) ?? now
            let end = calendar.date(byAdding: .hour, value: 1, to: currentHour) ?? now
            return TokenUsageWindow(start: start, displayEnd: end, component: .hour)
        case .last30Days:
            let currentDay = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -29, to: currentDay) ?? now
            let end = calendar.date(byAdding: .day, value: 1, to: currentDay) ?? now
            return TokenUsageWindow(start: start, displayEnd: end, component: .day)
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

        for record in records where record.timestamp >= window.start && record.timestamp <= now {
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

actor CCTokenUsageReader: TokenUsageReading {
    private let databaseURL: URL

    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cc-switch/cc-switch.db")) {
        self.databaseURL = databaseURL
    }

    func records(from start: Date, through end: Date) async throws -> [TokenUsageRecord] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw TokenUsageReadError.databaseMissing
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
            FROM proxy_request_logs
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
        reader: any TokenUsageReading = CCTokenUsageReader(),
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
            let records = try await reader.records(from: window.start, through: now)
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
    let start: Date
    let displayEnd: Date
    let component: Calendar.Component
}

private enum TokenUsageReadError: LocalizedError {
    case databaseMissing
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseMissing:
            "未找到 CC Switch 数据库"
        case .openFailed:
            "无法打开 CC Switch 数据库"
        case .queryFailed:
            "无法读取 CC Switch 用量数据"
        }
    }
}
