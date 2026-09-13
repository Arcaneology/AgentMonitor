import CoreGraphics
import SQLite3
import XCTest
@testable import AgentMonitor

final class TokenUsageTests: XCTestCase {
    func testFormatsTokenCountsUsingChineseUnits() {
        XCTAssertEqual(TokenCountFormatter.compact(9_999), "9999")
        XCTAssertEqual(TokenCountFormatter.compact(90_365_523), "0.90亿")
        XCTAssertEqual(TokenCountFormatter.compact(1_572_098_149), "15.72亿")
    }

    @MainActor
    func testChartAxisIndicesIncludeFirstAndLastBucket() {
        XCTAssertEqual(
            TokenUsageChartView.axisIndices(bucketCount: 17, desiredCount: 6),
            [0, 3, 6, 10, 13, 16]
        )
        XCTAssertEqual(
            TokenUsageChartView.axisIndices(bucketCount: 25, desiredCount: 7),
            [0, 4, 8, 12, 16, 20, 24]
        )
        XCTAssertEqual(
            TokenUsageChartView.axisIndices(bucketCount: 30, desiredCount: 7),
            [0, 5, 10, 15, 19, 24, 29]
        )
    }

    @MainActor
    func testChartYUpperBoundHasTenMillionFloor() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            TokenUsageChartView.chartYUpperBound(for: [
                TokenUsageBucket(start: start, inputTokens: 100)
            ]),
            10_000_000
        )
        XCTAssertEqual(
            TokenUsageChartView.chartYUpperBound(for: [
                TokenUsageBucket(start: start, inputTokens: 20_000_000)
            ]),
            21_600_000
        )
    }

    @MainActor
    func testTooltipStaysCloseAndOpensAwayFromChartEdges() {
        let availableSize = CGSize(width: 360, height: 156)

        let leftPosition = TokenUsageChartView.tooltipPosition(
            for: CGPoint(x: 80, y: 78),
            in: availableSize
        )
        XCTAssertEqual(leftPosition, CGPoint(x: 172, y: 78))

        let rightPosition = TokenUsageChartView.tooltipPosition(
            for: CGPoint(x: 300, y: 78),
            in: availableSize
        )
        XCTAssertEqual(rightPosition, CGPoint(x: 208, y: 78))
    }

    @MainActor
    func testTooltipVerticalPositionIsClampedInsideChart() {
        let availableSize = CGSize(width: 360, height: 156)

        let topPosition = TokenUsageChartView.tooltipPosition(
            for: CGPoint(x: 80, y: 10),
            in: availableSize
        )
        XCTAssertEqual(topPosition.y, 52)

        let bottomPosition = TokenUsageChartView.tooltipPosition(
            for: CGPoint(x: 80, y: 150),
            in: availableSize
        )
        XCTAssertEqual(bottomPosition.y, 104)
    }

    func testTodayUsesHourlyBucketsAndNormalizesCacheByAppType() throws {
        let calendar = makeCalendar()
        let now = try date("2026-06-22 10:30")
        let records = [
            TokenUsageRecord(
                timestamp: try date("2026-06-22 09:15"),
                appType: "codex",
                inputTokens: 100,
                outputTokens: 10,
                cacheReadTokens: 60,
                cacheCreationTokens: 0
            ),
            TokenUsageRecord(
                timestamp: try date("2026-06-22 10:05"),
                appType: "claude",
                inputTokens: 20,
                outputTokens: 5,
                cacheReadTokens: 30,
                cacheCreationTokens: 0
            )
        ]

        let snapshot = TokenUsageAggregator.aggregate(
            records,
            range: .today,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.buckets.count, 24)
        XCTAssertEqual(snapshot.buckets.first?.start, try date("2026-06-22 00:00"))
        XCTAssertEqual(snapshot.buckets.last?.start, try date("2026-06-22 23:00"))
        XCTAssertEqual(snapshot.buckets[9].inputTokens, 40)
        XCTAssertEqual(snapshot.buckets[9].cacheTokens, 60)
        XCTAssertEqual(snapshot.buckets[10].inputTokens, 20)
        XCTAssertEqual(snapshot.buckets[10].cacheTokens, 30)
        XCTAssertEqual(snapshot.buckets[11].totalTokens, 0)
        XCTAssertEqual(snapshot.totalTokens, 165)
    }

    func testNormalizesInputTokensUsingCCSwitchSemantics() {
        XCTAssertEqual(
            TokenUsageRecord.normalizedInput(
                appType: "claude",
                inputTokens: 200,
                cacheReadTokens: 5_000,
                cacheCreationTokens: 10,
                semantics: InputTokenSemantics.fresh.rawValue
            ),
            200
        )
        XCTAssertEqual(
            TokenUsageRecord.normalizedInput(
                appType: "grokbuild",
                inputTokens: 1_000,
                cacheReadTokens: 300,
                cacheCreationTokens: 200,
                semantics: InputTokenSemantics.total.rawValue
            ),
            500
        )
        XCTAssertEqual(
            TokenUsageRecord.normalizedInput(
                appType: "codex",
                inputTokens: 1_000,
                cacheReadTokens: 600,
                cacheCreationTokens: 50,
                semantics: InputTokenSemantics.legacy.rawValue
            ),
            400
        )
        XCTAssertEqual(
            TokenUsageRecord.normalizedInput(
                appType: "grokbuild",
                inputTokens: 700,
                cacheReadTokens: 250,
                cacheCreationTokens: 0,
                semantics: InputTokenSemantics.legacy.rawValue
            ),
            450
        )
        XCTAssertEqual(
            TokenUsageRecord.normalizedInput(
                appType: "codex",
                inputTokens: 100,
                cacheReadTokens: 999,
                cacheCreationTokens: 0,
                semantics: InputTokenSemantics.legacy.rawValue
            ),
            0
        )
    }

    func testLast24HoursUsesRollingCCSwitchRangeWithHourlyBuckets() throws {
        let calendar = makeCalendar()
        let now = try date("2026-06-22 10:30")
        let records = [
            TokenUsageRecord(
                timestamp: try date("2026-06-21 10:15"),
                appType: "codex",
                inputTokens: 100,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0
            ),
            TokenUsageRecord(
                timestamp: try date("2026-06-21 10:45"),
                appType: "codex",
                inputTokens: 200,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0
            )
        ]
        let snapshot = TokenUsageAggregator.aggregate(
            records,
            range: .last24Hours,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.buckets.count, 25)
        XCTAssertEqual(snapshot.buckets.first?.start, try date("2026-06-21 10:00"))
        XCTAssertEqual(snapshot.buckets.last?.start, try date("2026-06-22 10:00"))
        XCTAssertEqual(snapshot.buckets.first?.inputTokens, 200)
    }

    func testLast30DaysCreatesExactly30DailyBuckets() throws {
        let snapshot = TokenUsageAggregator.aggregate(
            [],
            range: .last30Days,
            now: try date("2026-06-22 10:30"),
            calendar: makeCalendar()
        )

        XCTAssertEqual(snapshot.buckets.count, 30)
        XCTAssertEqual(snapshot.buckets.first?.start, try date("2026-05-24 00:00"))
        XCTAssertEqual(snapshot.buckets.last?.start, try date("2026-06-22 00:00"))
    }

    func testTokenDatabaseReadsLocalRowsOnlyUntilManualCCSwitchSync() async throws {
        let localDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).db")
        let ccSwitchDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-ccswitch.db")
        defer {
            try? FileManager.default.removeItem(at: localDatabaseURL)
            try? FileManager.default.removeItem(at: ccSwitchDatabaseURL)
        }
        try createCCSwitchFixtureDatabase(at: ccSwitchDatabaseURL)

        let database = TokenUsageDatabase(
            databaseURL: localDatabaseURL,
            ccSwitchDatabaseURL: ccSwitchDatabaseURL,
            sessionRoots: emptySessionRoots()
        )
        let localRecordsBeforeSync = try await database.records(
            from: Date(timeIntervalSince1970: 1_000),
            through: Date(timeIntervalSince1970: 3_000)
        )
        XCTAssertTrue(localRecordsBeforeSync.isEmpty)

        let syncedCount = try await database.syncFromCCSwitch()
        let records = try await database.records(
            from: Date(timeIntervalSince1970: 1_000),
            through: Date(timeIntervalSince1970: 3_000)
        )

        XCTAssertEqual(syncedCount, 1)
        XCTAssertEqual(records, [
            TokenUsageRecord(
                timestamp: Date(timeIntervalSince1970: 2_000),
                appType: "codex",
                inputTokens: 100,
                outputTokens: 12,
                cacheReadTokens: 80,
                cacheCreationTokens: 0,
                model: "gpt-5.5"
            )
        ])
    }

    func testTokenDatabaseKeepsLocalRowsWhenCCSwitchDatabaseIsMissing() async throws {
        let localDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).db")
        let ccSwitchDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-ccswitch.db")
        defer {
            try? FileManager.default.removeItem(at: localDatabaseURL)
            try? FileManager.default.removeItem(at: ccSwitchDatabaseURL)
        }
        try createCCSwitchFixtureDatabase(at: ccSwitchDatabaseURL)

        let database = TokenUsageDatabase(
            databaseURL: localDatabaseURL,
            ccSwitchDatabaseURL: ccSwitchDatabaseURL,
            sessionRoots: emptySessionRoots()
        )
        _ = try await database.syncFromCCSwitch()
        try FileManager.default.removeItem(at: ccSwitchDatabaseURL)

        let records = try await database.records(
            from: Date(timeIntervalSince1970: 1_000),
            through: Date(timeIntervalSince1970: 3_000)
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.inputTokens, 100)
    }

    @MainActor
    func testTokenStoreRefreshReadsSessionLogsAndIgnoresCCSwitch() async throws {
        let localDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).db")
        let ccSwitchDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-ccswitch.db")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-home")
        defer {
            try? FileManager.default.removeItem(at: localDatabaseURL)
            try? FileManager.default.removeItem(at: ccSwitchDatabaseURL)
            try? FileManager.default.removeItem(at: home)
        }
        try createCCSwitchFixtureDatabase(at: ccSwitchDatabaseURL)
        try writeGrokFixture(
            at: home
                .appendingPathComponent(".grok/sessions/proj/sess-1/updates.jsonl"),
            createdAt: 2_500
        )

        let database = TokenUsageDatabase(
            databaseURL: localDatabaseURL,
            ccSwitchDatabaseURL: ccSwitchDatabaseURL,
            sessionRoots: SessionLogRoots.default(home: home)
        )
        let store = TokenUsageStore(reader: database, calendar: makeCalendar())

        await store.refresh(
            range: .last24Hours,
            now: Date(timeIntervalSince1970: 3_000)
        )

        XCTAssertNil(store.errorDescription)
        XCTAssertEqual(store.snapshot?.totalTokens, 1_300)
        XCTAssertEqual(store.snapshot?.buckets.contains(where: { $0.inputTokens == 700 }), true)
        XCTAssertEqual(store.snapshot?.buckets.contains(where: { $0.cacheTokens == 300 }), true)
        XCTAssertEqual(store.snapshot?.buckets.contains(where: { $0.outputTokens == 300 }), true)
    }

    func testSessionParsersMatchCCSwitchRequestIDsAndSemantics() {
        let claude = SessionUsageParser.claudeEntries(
            from: """
            {"type":"assistant","timestamp":"2026-06-22T01:00:00.000Z","sessionId":"s1","message":{"id":"msg_a","model":"claude-sonnet","usage":{"input_tokens":20,"output_tokens":5,"cache_read_input_tokens":30,"cache_creation_input_tokens":2},"stop_reason":null}}
            {"type":"assistant","timestamp":"2026-06-22T01:00:01.000Z","sessionId":"s1","message":{"id":"msg_a","model":"claude-sonnet","usage":{"input_tokens":20,"output_tokens":8,"cache_read_input_tokens":30,"cache_creation_input_tokens":2},"stop_reason":"end_turn"}}
            {"type":"assistant","timestamp":"2026-06-22T01:00:02.000Z","message":{"id":"msg_empty","model":"claude-sonnet","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """,
            now: 1
        )
        XCTAssertEqual(claude.count, 1)
        XCTAssertEqual(claude[0].requestID, "session:msg_a")
        XCTAssertEqual(claude[0].outputTokens, 8)
        XCTAssertEqual(claude[0].inputTokenSemantics, InputTokenSemantics.legacy.rawValue)
        XCTAssertTrue(claude[0].upsertOnConflict)

        let grok = SessionUsageParser.grokEntries(
            from: """
            {"method":"_x.ai/session/update","timestamp":2500,"params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"inputTokens":1000,"outputTokens":300,"cachedReadTokens":300,"modelUsage":{"grok-4.6-build":{"inputTokens":1000,"outputTokens":300,"cachedReadTokens":300}}}}}}
            {"method":"_x.ai/session/update","timestamp":2600,"params":{"update":{"sessionUpdate":"turn_started","usage":{"inputTokens":9,"outputTokens":9,"cachedReadTokens":0}}}}
            """,
            sessionID: "sess-1"
        )
        XCTAssertEqual(grok.count, 1)
        XCTAssertEqual(grok[0].requestID, "grok_session:sess-1:p1:grok-4.6-build")
        XCTAssertEqual(grok[0].appType, "grokbuild")
        XCTAssertEqual(grok[0].inputTokens, 1000)
        XCTAssertEqual(grok[0].inputTokenSemantics, InputTokenSemantics.total.rawValue)
        XCTAssertTrue(grok[0].upsertOnConflict)

        let gemini = SessionUsageParser.geminiEntries(
            from: """
            {"sessionId":"g1","messages":[{"type":"user","tokens":{"input":1}},{"type":"gemini","id":"m1","model":"gemini-2.5-pro","timestamp":"2026-06-22T01:00:00Z","tokens":{"input":40,"output":6,"cached":10,"thoughts":4}}]}
            """,
            now: 1
        )
        XCTAssertEqual(gemini.count, 1)
        XCTAssertEqual(gemini[0].requestID, "gemini_session:g1:m1")
        XCTAssertEqual(gemini[0].outputTokens, 10)
        XCTAssertEqual(gemini[0].cacheReadTokens, 10)

        let threadID = "019e44e8-450f-7cd2-abea-804ddd037907"
        let parsed = SessionUsageParser.parseCodex(
            jsonl: """
            {"timestamp":"2026-05-20T10:22:21.199Z","type":"session_meta","payload":{"id":"\(threadID)"}}
            {"timestamp":"2026-05-20T10:22:22.000Z","type":"turn_context","payload":{"model":"openai/gpt-5.4-2026-03-05"}}
            {"timestamp":"2026-05-20T10:22:31.574Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":12},"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":12}}}}
            {"timestamp":"2026-05-20T10:22:41.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40,"cached_input_tokens":10,"output_tokens":5},"total_token_usage":{"input_tokens":140,"cached_input_tokens":90,"output_tokens":17}}}}
            """,
            fileName: "rollout-2026-05-20T18-22-13-\(threadID).jsonl"
        )
        let billed = parsed.events.filter { $0.eventIndex != nil }
        XCTAssertEqual(parsed.rootThreadID, threadID)
        XCTAssertEqual(SessionUsageParser.normalizeCodexModel("openai/gpt-5.4-2026-03-05"), "gpt-5.4")
        XCTAssertEqual(billed.count, 2)
        XCTAssertEqual(billed[0].input, 100)
        XCTAssertEqual(billed[0].cachedInput, 80)
        XCTAssertEqual(billed[0].output, 12)
        XCTAssertEqual(billed[0].model, "openai/gpt-5.4-2026-03-05")
        XCTAssertEqual(billed[1].input, 40)
        XCTAssertEqual(billed[1].eventIndex, 2)
    }

    func testCodexPrefersLastTokenUsageOverCumulativeDeltaAndClampsCache() {
        let parsed = SessionUsageParser.parseCodex(
            jsonl: """
            {"timestamp":"2026-05-20T10:00:00Z","type":"session_meta","payload":{"id":"019e44e8-450f-7cd2-abea-804ddd037907"}}
            {"timestamp":"2026-05-20T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":40,"output_tokens":1}}}}
            {"timestamp":"2026-05-20T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":80,"output_tokens":2},"total_token_usage":{"input_tokens":60,"cached_input_tokens":50,"output_tokens":3}}}}
            """,
            fileName: "rollout-019e44e8-450f-7cd2-abea-804ddd037907.jsonl"
        )
        let billed = parsed.events.filter { $0.eventIndex != nil }
        XCTAssertEqual(billed.count, 2)
        XCTAssertEqual(billed[0].input, 50)
        XCTAssertEqual(billed[1].input, 10)
        XCTAssertEqual(billed[1].cachedInput, 10)
        XCTAssertEqual(billed[1].output, 2)
    }

    func testSessionLogSyncDoesNotReadCCSwitchAndSkipsUnchangedFiles() async throws {
        let localDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).db")
        let ccSwitchDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-ccswitch.db")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-home")
        defer {
            try? FileManager.default.removeItem(at: localDatabaseURL)
            try? FileManager.default.removeItem(at: ccSwitchDatabaseURL)
            try? FileManager.default.removeItem(at: home)
        }
        try createCCSwitchFixtureDatabase(at: ccSwitchDatabaseURL)
        try writeGrokFixture(
            at: home.appendingPathComponent(".grok/sessions/proj/sess-1/updates.jsonl"),
            createdAt: 2_000
        )

        let database = TokenUsageDatabase(
            databaseURL: localDatabaseURL,
            ccSwitchDatabaseURL: ccSwitchDatabaseURL,
            sessionRoots: SessionLogRoots.default(home: home)
        )

        let first = try await database.syncFromSessionLogs(now: Date(timeIntervalSince1970: 3_000))
        let second = try await database.syncFromSessionLogs(now: Date(timeIntervalSince1970: 3_000))
        let records = try await database.records(
            from: Date(timeIntervalSince1970: 1_000),
            through: Date(timeIntervalSince1970: 3_000)
        )

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.appType, "grokbuild")
        XCTAssertEqual(records.first?.inputTokens, 1000)
        XCTAssertEqual(records.first?.inputTokenSemantics, InputTokenSemantics.total.rawValue)
        XCTAssertEqual(records.first?.normalizedInputTokens, 700)
    }

    func testCCSwitchCalibrationDoesNotOverwriteSessionRows() async throws {
        let localDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).db")
        let ccSwitchDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-ccswitch.db")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-home")
        defer {
            try? FileManager.default.removeItem(at: localDatabaseURL)
            try? FileManager.default.removeItem(at: ccSwitchDatabaseURL)
            try? FileManager.default.removeItem(at: home)
        }
        try writeGrokFixture(
            at: home.appendingPathComponent(".grok/sessions/proj/sess-1/updates.jsonl"),
            createdAt: 2_000
        )
        try createCCSwitchFixtureDatabase(
            at: ccSwitchDatabaseURL,
            extraRow: (
                requestID: "grok_session:sess-1:p1:grok-4.6-build",
                appType: "grokbuild",
                inputTokens: 1,
                outputTokens: 1,
                cacheReadTokens: 0
            )
        )

        let database = TokenUsageDatabase(
            databaseURL: localDatabaseURL,
            ccSwitchDatabaseURL: ccSwitchDatabaseURL,
            sessionRoots: SessionLogRoots.default(home: home)
        )
        _ = try await database.syncFromSessionLogs(now: Date(timeIntervalSince1970: 3_000))
        _ = try await database.syncFromCCSwitch()
        let records = try await database.records(
            from: Date(timeIntervalSince1970: 1_000),
            through: Date(timeIntervalSince1970: 3_000)
        )

        XCTAssertEqual(records.count, 2)
        let grok = try XCTUnwrap(records.first { $0.appType == "grokbuild" })
        XCTAssertEqual(grok.inputTokens, 1000)
        XCTAssertEqual(grok.outputTokens, 300)
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = makeCalendar()
        formatter.timeZone = formatter.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: text))
    }

    private func emptySessionRoots() -> SessionLogRoots {
        SessionLogRoots.default(
            home: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-session-roots-\(UUID().uuidString)")
        )
    }

    private func writeGrokFixture(at url: URL, createdAt: Int64) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let jsonl = """
            {"method":"_x.ai/session/update","timestamp":\(createdAt),"params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"inputTokens":1000,"outputTokens":300,"cachedReadTokens":300,"modelUsage":{"grok-4.6-build":{"inputTokens":1000,"outputTokens":300,"cachedReadTokens":300}}}}}}
            """
        try (jsonl + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func createCCSwitchFixtureDatabase(
        at url: URL,
        extraRow: (
            requestID: String,
            appType: String,
            inputTokens: Int64,
            outputTokens: Int64,
            cacheReadTokens: Int64
        )? = nil
    ) throws {
        var databasePointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &databasePointer), SQLITE_OK)
        let database = try XCTUnwrap(databasePointer)
        defer { sqlite3_close(database) }

        var sql = """
            CREATE TABLE proxy_request_logs (
                request_id TEXT PRIMARY KEY,
                provider_id TEXT NOT NULL,
                app_type TEXT NOT NULL,
                model TEXT NOT NULL,
                request_model TEXT,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
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
                status_code INTEGER NOT NULL,
                error_message TEXT,
                session_id TEXT,
                provider_type TEXT,
                is_streaming INTEGER NOT NULL DEFAULT 0,
                cost_multiplier TEXT NOT NULL DEFAULT '1.0',
                created_at INTEGER NOT NULL,
                data_source TEXT NOT NULL DEFAULT 'proxy',
                pricing_model TEXT
            );
            INSERT INTO proxy_request_logs (
                request_id, provider_id, app_type, model, request_model,
                input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
                status_code, created_at, data_source
            ) VALUES (
                'request-1', 'provider-1', 'codex', 'gpt-5.5', NULL,
                100, 12, 80, 0, 200, 2000, 'codex_session'
            );
            """
        if let extraRow {
            sql += """
                INSERT INTO proxy_request_logs (
                    request_id, provider_id, app_type, model, request_model,
                    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
                    status_code, created_at, data_source
                ) VALUES (
                    '\(extraRow.requestID)', 'provider-1', '\(extraRow.appType)', 'model', NULL,
                    \(extraRow.inputTokens), \(extraRow.outputTokens), \(extraRow.cacheReadTokens),
                    0, 200, 2000, 'proxy'
                );
                """
        }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }
}
