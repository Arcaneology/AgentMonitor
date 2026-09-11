import Foundation
import SQLite3

/// Compile with the three Core/Usage sources. Always audit a COPY of the database.
@main
struct TokenUsageAudit {
    struct Cell: Codable {
        let day: String
        let model: String
        let accountingStatus: String
        var count: Int = 0
        var tokens: Int64 = 0
    }

    struct Report: Codable {
        let capturedAt: Date
        let database: String
        let elapsedSeconds: Double
        let changedRows: Int
        let before: [Cell]
        let afterMigration: [Cell]
        let afterScan: [Cell]
        let diagnostics: [Diagnostic]
    }

    struct Diagnostic: Codable {
        let path: String
        let reason: String
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            throw NSError(domain: "TokenUsageAudit", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Usage: audit-token-usage /absolute/path/to/COPY.db /absolute/path/to/report.json"
            ])
        }
        let databaseURL = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
        guard databaseURL != TokenUsageDatabase.defaultDatabaseURL().standardizedFileURL.resolvingSymlinksInPath(),
              FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw NSError(domain: "TokenUsageAudit", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Refusing the live database or a missing copy. Create a SQLite backup first."
            ])
        }
        let now = Date()
        let before = try legacyRecords(databaseURL, now: now)
        let database = TokenUsageDatabase(
            databaseURL: databaseURL,
            ccSwitchDatabaseURL: databaseURL.deletingLastPathComponent().appendingPathComponent("no-cc-switch.db")
        )
        let migrated = try await database.records(from: Date(timeIntervalSince1970: 0), through: now)
        let changedRows = try await database.syncFromSessionLogs(now: now)
        let scanned = try await database.records(from: Date(timeIntervalSince1970: 0), through: now)
        let report = Report(
            capturedAt: now, database: databaseURL.path,
            elapsedSeconds: Date().timeIntervalSince(now), changedRows: changedRows,
            before: cells(before), afterMigration: cells(migrated), afterScan: cells(scanned),
            diagnostics: await database.diagnostics().map { Diagnostic(path: $0.path, reason: $0.reason) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        print("Audit complete: \(scanned.count) records; report: \(args[2])")
    }

    private static func cells(_ records: [TokenUsageRecord]) -> [Cell] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd"
        var values: [String: Cell] = [:]
        for row in records {
            let day = formatter.string(from: row.timestamp)
            let model = TokenModelCatalog.canonicalID(row.model)
            let key = "\(day)|\(model)|\(row.accountingStatus)"
            var cell = values[key] ?? Cell(day: day, model: model, accountingStatus: row.accountingStatus)
            cell.count += 1
            cell.tokens += row.normalizedInputTokens + row.cacheTokens + row.outputTokens
            values[key] = cell
        }
        return values.keys.sorted().compactMap { values[$0] }
    }

    private static func legacyRecords(_ url: URL, now: Date) throws -> [TokenUsageRecord] {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = pointer else { throw NSError(domain: "SQLite", code: 1) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = """
        SELECT created_at,app_type,input_tokens,output_tokens,cache_read_tokens,
        cache_creation_tokens,input_token_semantics,model FROM token_usage_records WHERE created_at <= ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw NSError(domain: "SQLite", code: 2) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(now.timeIntervalSince1970))
        var records: [TokenUsageRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return records }
            guard result == SQLITE_ROW else { throw NSError(domain: "SQLite", code: Int(result)) }
            records.append(TokenUsageRecord(
                timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0))),
                appType: String(cString: sqlite3_column_text(statement, 1)),
                inputTokens: sqlite3_column_int64(statement, 2),
                outputTokens: sqlite3_column_int64(statement, 3),
                cacheReadTokens: sqlite3_column_int64(statement, 4),
                cacheCreationTokens: sqlite3_column_int64(statement, 5),
                inputTokenSemantics: sqlite3_column_int64(statement, 6),
                model: String(cString: sqlite3_column_text(statement, 7))
            ))
        }
    }
}
