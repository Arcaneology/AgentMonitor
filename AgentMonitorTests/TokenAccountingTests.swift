import Foundation
import SQLite3
import XCTest
@testable import AgentMonitor

final class TokenAccountingTests: XCTestCase {
    func testAggregationUsesCanonicalModelsAndKeepsPendingOutOfMainTotal() {
        let now = Date()
        let records = [
            TokenUsageRecord(
                timestamp: now.addingTimeInterval(-60),
                appType: "codex",
                inputTokens: 80,
                outputTokens: 20,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                model: "openai/gpt-5.4"
            ),
            TokenUsageRecord(
                timestamp: now.addingTimeInterval(-60),
                appType: "codex",
                inputTokens: 30,
                outputTokens: 10,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                model: "gpt-5.4"
            ),
            TokenUsageRecord(
                timestamp: now.addingTimeInterval(-30),
                appType: "grokbuild",
                inputTokens: 50,
                outputTokens: 5,
                cacheReadTokens: 10,
                cacheCreationTokens: 0,
                inputTokenSemantics: InputTokenSemantics.total.rawValue,
                model: "grok-4.6-build",
                accountingStatus: TokenUsageRecord.pendingAccountingStatus,
                accountingReason: "suspected_proxy_overlap"
            )
        ]

        let snapshot = TokenUsageAggregator.aggregate(
            records,
            range: .last24Hours,
            now: now
        )
        let gptID = TokenModelCatalog.canonicalID("gpt-5.4")

        XCTAssertEqual(snapshot.totalTokens, 140)
        XCTAssertEqual(snapshot.modelIDs, [gptID, "grok-4.6-build"].sorted())
        XCTAssertEqual(snapshot.buckets.reduce(0) { $0 + ($1.models[gptID]?.totalTokens ?? 0) }, 140)
        XCTAssertEqual(snapshot.pendingReviewSummary.count, 1)
        XCTAssertEqual(snapshot.pendingReviewSummary.tokens, 55)
        XCTAssertEqual(snapshot.pendingReviewSummary.reasons["suspected_proxy_overlap"], 1)
        XCTAssertEqual(snapshot.filtered(model: "openai/gpt-5.4").totalTokens, 140)
        XCTAssertEqual(snapshot.filtered(model: "grok-4.6-build").totalTokens, 0)
    }

    func testInclusiveCacheCountersAreClampedWithoutChangingRawValues() {
        let record = TokenUsageRecord(
            timestamp: Date(),
            appType: "codex",
            inputTokens: 100,
            outputTokens: 5,
            cacheReadTokens: 999,
            cacheCreationTokens: 3,
            model: "gpt-5.4"
        )

        XCTAssertEqual(record.inputTokens, 100)
        XCTAssertEqual(record.cacheReadTokens, 999)
        XCTAssertEqual(record.normalizedInputTokens, 0)
        XCTAssertEqual(record.cacheTokens, 103)
    }

    func testMigrationBacksUpDatabaseAndMarksExactLegacyCodexPairDuplicate() async throws {
        let databaseURL = temporaryURL("legacy")
        defer { removeDatabaseArtifacts(at: databaseURL) }
        try createLegacyDatabase(at: databaseURL)
        try insertLegacyRow(
            at: databaseURL,
            requestID: "codex_session:thread-a:1",
            model: "gpt-5.4"
        )
        try insertLegacyRow(
            at: databaseURL,
            requestID: "codex_session:thread-v1:thread-a:1",
            model: "gpt-5.4"
        )

        let database = TokenUsageDatabase(
            databaseURL: databaseURL,
            ccSwitchDatabaseURL: temporaryURL("missing-cc"),
            sessionRoots: emptySessionRoots()
        )
        let records = try await database.records(
            from: Date(timeIntervalSince1970: 0),
            through: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.filter { $0.accountingStatus == TokenUsageRecord.duplicateAccountingStatus }.count, 1)
        XCTAssertEqual(records.filter { $0.accountingStatus == TokenUsageRecord.includedAccountingStatus }.count, 1)
        XCTAssertEqual(records.filter { $0.accountingStatus == TokenUsageRecord.duplicateAccountingStatus }.first?.accountingReason,
                       "codex_thread_v1_exact_pair")

        let backupURL = await database.latestMigrationBackupURL()
        XCTAssertNotNil(backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(backupURL).path))

        // Re-opening the migrated database is idempotent and does not create
        // another backup or change the accounting decision.
        _ = try await database.records(
            from: Date(timeIntervalSince1970: 0),
            through: Date(timeIntervalSince1970: 10_000)
        )
        let repeatedBackupURL = await database.latestMigrationBackupURL()
        XCTAssertEqual(repeatedBackupURL, backupURL)
    }

    func testClaudeLateFinalValueReplacesIncompleteValue() async throws {
        let databaseURL = temporaryURL("claude")
        let homeURL = temporaryURL("home")
        defer {
            removeDatabaseArtifacts(at: databaseURL)
            try? FileManager.default.removeItem(at: homeURL)
        }
        let logURL = homeURL
            .appendingPathComponent(".claude/projects/project/session.jsonl")
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"type\":\"assistant\",\"timestamp\":\"2026-06-22T01:00:00Z\",\"sessionId\":\"s1\",\"message\":{\"id\":\"m1\",\"model\":\"claude-sonnet\",\"usage\":{\"input_tokens\":20,\"output_tokens\":1},\"stop_reason\":null}}\n"
            .write(to: logURL, atomically: true, encoding: .utf8)

        let database = TokenUsageDatabase(
            databaseURL: databaseURL,
            ccSwitchDatabaseURL: temporaryURL("missing-cc"),
            sessionRoots: SessionLogRoots.default(home: homeURL)
        )
        _ = try await database.syncFromSessionLogs(now: Date(timeIntervalSince1970: 2_000_000_000))
        let first = try await database.records(
            from: Date(timeIntervalSince1970: 0),
            through: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(first.first?.outputTokens, 1)
        XCTAssertEqual(first.first?.accountingStatus, TokenUsageRecord.includedAccountingStatus)

        try "{\"type\":\"assistant\",\"timestamp\":\"2026-06-22T01:00:00Z\",\"sessionId\":\"s1\",\"message\":{\"id\":\"m1\",\"model\":\"claude-sonnet\",\"usage\":{\"input_tokens\":20,\"output_tokens\":8},\"stop_reason\":\"end_turn\"}}\n"
            .write(to: logURL, atomically: true, encoding: .utf8)
        _ = try await database.syncFromSessionLogs(now: Date(timeIntervalSince1970: 2_000_000_001))
        let second = try await database.records(
            from: Date(timeIntervalSince1970: 0),
            through: Date(timeIntervalSince1970: 2_000_000_001)
        )
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.outputTokens, 8)
        XCTAssertEqual(second.first?.accountingStatus, TokenUsageRecord.includedAccountingStatus)
    }

    func testDiagnosticsSurviveUnchangedScanAndClearAfterSuccessfulRescan() async throws {
        let databaseURL = temporaryURL("diagnostics")
        let homeURL = temporaryURL("diagnostics-home")
        defer {
            removeDatabaseArtifacts(at: databaseURL)
            try? FileManager.default.removeItem(at: homeURL)
        }
        let logURL = homeURL
            .appendingPathComponent(".claude/projects/project/session.jsonl")
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"type\":\"assistant\",\"usage\":BROKEN\n"
            .write(to: logURL, atomically: true, encoding: .utf8)

        let firstDatabase = TokenUsageDatabase(
            databaseURL: databaseURL,
            ccSwitchDatabaseURL: temporaryURL("missing-cc"),
            sessionRoots: SessionLogRoots.default(home: homeURL)
        )
        _ = try await firstDatabase.syncFromSessionLogs(now: Date(timeIntervalSince1970: 2_000_000_000))
        let firstDiagnostics = await firstDatabase.diagnostics()
        XCTAssertFalse(firstDiagnostics.isEmpty)

        let restartedDatabase = TokenUsageDatabase(
            databaseURL: databaseURL,
            ccSwitchDatabaseURL: temporaryURL("missing-cc"),
            sessionRoots: SessionLogRoots.default(home: homeURL)
        )
        _ = try await restartedDatabase.syncFromSessionLogs(now: Date(timeIntervalSince1970: 2_000_000_001))
        let persistedDiagnostics = await restartedDatabase.diagnostics()
        XCTAssertEqual(persistedDiagnostics, firstDiagnostics)

        try "{\"type\":\"assistant\",\"timestamp\":\"2026-06-22T01:00:00Z\",\"sessionId\":\"s1\",\"message\":{\"id\":\"m1\",\"model\":\"claude-sonnet\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1},\"stop_reason\":\"end_turn\"}}\n"
            .write(to: logURL, atomically: true, encoding: .utf8)
        _ = try await restartedDatabase.syncFromSessionLogs(now: Date(timeIntervalSince1970: 2_000_000_002))
        let clearedDiagnostics = await restartedDatabase.diagnostics()
        XCTAssertTrue(clearedDiagnostics.isEmpty)
    }

    func testCodexRewriteReassociatesShiftedEventsWithoutOvercount() async throws {
        let databaseURL = temporaryURL("codex-rewrite")
        let homeURL = temporaryURL("codex-rewrite-home")
        defer {
            removeDatabaseArtifacts(at: databaseURL)
            try? FileManager.default.removeItem(at: homeURL)
        }

        let threadID = "01a090d7-2603-7020-b048-551ea523e85c"
        let logURL = homeURL
            .appendingPathComponent(".codex/sessions/2026/09/11/rollout-\(threadID).jsonl")
        let database = TokenUsageDatabase(
            databaseURL: databaseURL,
            ccSwitchDatabaseURL: temporaryURL("missing-cc"),
            sessionRoots: SessionLogRoots.default(home: homeURL)
        )
        let end = Date(timeIntervalSince1970: 2_000_000_000)

        try writeCodexDocument(
            events: [("2026-09-11T01:01:00Z", 10, 1), ("2026-09-11T01:02:00Z", 20, 2)],
            threadID: threadID,
            to: logURL
        )
        _ = try await database.syncFromSessionLogs(now: end)

        // Replacing the file shifts B from index 2 to index 1 and introduces C.
        // Appending D then exercises a stable index after the rewrite.
        try writeCodexDocument(
            events: [("2026-09-11T01:02:00Z", 20, 2), ("2026-09-11T01:03:00Z", 30, 3)],
            threadID: threadID,
            to: logURL
        )
        _ = try await database.syncFromSessionLogs(now: end.addingTimeInterval(1))
        try appendCodexEvent(
            timestamp: "2026-09-11T01:04:00Z",
            input: 40,
            output: 4,
            threadID: threadID,
            to: logURL
        )

        let restarted = TokenUsageDatabase(
            databaseURL: databaseURL,
            ccSwitchDatabaseURL: temporaryURL("missing-cc-restart"),
            sessionRoots: SessionLogRoots.default(home: homeURL)
        )
        _ = try await restarted.syncFromSessionLogs(now: end.addingTimeInterval(2))
        var rows = try await restarted.records(from: .distantPast, through: end)
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.accountingStatus == TokenUsageRecord.includedAccountingStatus })
        XCTAssertEqual(rows.reduce(Int64(0)) { $0 + $1.normalizedInputTokens + $1.cacheTokens + $1.outputTokens }, 110)

        // Truncate and rewrite in place, preserving the inode. C and D move to
        // new indices; the four raw events must remain represented exactly once.
        try replaceInPlace(
            codexDocument(
                events: [("2026-09-11T01:03:00Z", 30, 3), ("2026-09-11T01:04:00Z", 40, 4)],
                threadID: threadID
            ),
            at: logURL
        )
        _ = try await restarted.syncFromSessionLogs(now: end.addingTimeInterval(2))
        rows = try await restarted.records(from: .distantPast, through: end)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.reduce(Int64(0)) { $0 + $1.normalizedInputTokens + $1.cacheTokens + $1.outputTokens }, 110)
    }

    private func temporaryURL(_ stem: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentMonitor-\(stem)-\(UUID().uuidString).db")
    }

    private func emptySessionRoots() -> SessionLogRoots {
        SessionLogRoots.default(home: temporaryURL("missing-home"))
    }

    private func codexDocument(
        events: [(String, Int64, Int64)],
        threadID: String
    ) -> String {
        let header = [
            "{\"type\":\"session_meta\",\"timestamp\":\"2026-09-11T01:00:00Z\",\"payload\":{\"id\":\"\(threadID)\"}}",
            "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-6-astra\"}}"
        ].joined(separator: "\n")
        return header + "\n" + events.map { timestamp, input, output in
            codexEvent(timestamp: timestamp, input: input, output: output)
        }.joined(separator: "\n") + "\n"
    }

    private func codexEvent(timestamp: String, input: Int64, output: Int64) -> String {
        "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":0,\"output_tokens\":\(output)},\"total_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":0,\"output_tokens\":\(output)}}}}"
    }

    private func writeCodexDocument(
        events: [(String, Int64, Int64)],
        threadID: String,
        to url: URL
    ) throws {
        try write(codexDocument(events: events, threadID: threadID), to: url)
    }

    private func appendCodexEvent(
        timestamp: String,
        input: Int64,
        output: Int64,
        threadID: String,
        to url: URL
    ) throws {
        try append(codexEvent(timestamp: timestamp, input: input, output: output) + "\n", to: url)
    }

    private func replaceInPlace(_ value: String, at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(value.utf8))
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ value: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(value.utf8))
    }

    private func createLegacyDatabase(at url: URL) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE token_usage_records (
            request_id TEXT PRIMARY KEY,
            provider_id TEXT NOT NULL DEFAULT '', app_type TEXT NOT NULL DEFAULT 'unknown',
            model TEXT NOT NULL DEFAULT '', request_model TEXT,
            input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0, cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
            input_cost_usd TEXT NOT NULL DEFAULT '0', output_cost_usd TEXT NOT NULL DEFAULT '0',
            cache_read_cost_usd TEXT NOT NULL DEFAULT '0', cache_creation_cost_usd TEXT NOT NULL DEFAULT '0',
            total_cost_usd TEXT NOT NULL DEFAULT '0', latency_ms INTEGER NOT NULL DEFAULT 0,
            first_token_ms INTEGER, duration_ms INTEGER, status_code INTEGER NOT NULL DEFAULT 200,
            error_message TEXT, session_id TEXT, provider_type TEXT, is_streaming INTEGER NOT NULL DEFAULT 1,
            cost_multiplier TEXT NOT NULL DEFAULT '1.0', created_at INTEGER NOT NULL,
            data_source TEXT NOT NULL DEFAULT 'codex_session', pricing_model TEXT,
            input_token_semantics INTEGER NOT NULL DEFAULT 0,
            synced_from TEXT NOT NULL DEFAULT 'session-logs', synced_at INTEGER NOT NULL
        );
        CREATE TABLE session_log_sync (
            file_path TEXT PRIMARY KEY, last_modified INTEGER NOT NULL,
            last_line_offset INTEGER NOT NULL, last_synced_at INTEGER NOT NULL
        );
        PRAGMA user_version = 3;
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    private func insertLegacyRow(at url: URL, requestID: String, model: String) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        let sql = """
        INSERT INTO token_usage_records (
            request_id, app_type, model, input_tokens, output_tokens,
            cache_read_tokens, cache_creation_tokens, session_id, created_at, data_source,
            input_token_semantics, synced_from, synced_at
        ) VALUES ('\(requestID)', 'codex', '\(model)', 100, 10, 20, 0, 'thread-a', 2000,
                  'codex_session', 0, 'session-logs', 2000)
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    private func removeDatabaseArtifacts(at url: URL) {
        for path in [
            url.path,
            url.path + "-wal",
            url.path + "-shm"
        ] {
            try? FileManager.default.removeItem(atPath: path)
        }
        let directory = url.deletingLastPathComponent()
        let prefix = url.deletingPathExtension().lastPathComponent + ".backup-v4-"
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
