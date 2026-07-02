import CoreGraphics
import SQLite3
import XCTest
@testable import AgentMonitor

final class TokenUsageTests: XCTestCase {
    func testFormatsTokenCountsUsingChineseUnits() {
        XCTAssertEqual(TokenCountFormatter.compact(9_999), "9999")
        XCTAssertEqual(TokenCountFormatter.compact(90_365_523), "9036.55万")
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
            ccSwitchDatabaseURL: ccSwitchDatabaseURL
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
                cacheCreationTokens: 0
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
            ccSwitchDatabaseURL: ccSwitchDatabaseURL
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

    private func createCCSwitchFixtureDatabase(at url: URL) throws {
        var databasePointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &databasePointer), SQLITE_OK)
        let database = try XCTUnwrap(databasePointer)
        defer { sqlite3_close(database) }

        let sql = """
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
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }
}
