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

        XCTAssertEqual(snapshot.buckets.count, 11)
        XCTAssertEqual(snapshot.buckets[9].inputTokens, 40)
        XCTAssertEqual(snapshot.buckets[9].cacheTokens, 60)
        XCTAssertEqual(snapshot.buckets[10].inputTokens, 20)
        XCTAssertEqual(snapshot.buckets[10].cacheTokens, 30)
        XCTAssertEqual(snapshot.totalTokens, 165)
    }

    func testLast24HoursCreatesExactly24HourlyBuckets() throws {
        let snapshot = TokenUsageAggregator.aggregate(
            [],
            range: .last24Hours,
            now: try date("2026-06-22 10:30"),
            calendar: makeCalendar()
        )

        XCTAssertEqual(snapshot.buckets.count, 24)
        XCTAssertEqual(snapshot.buckets.first?.start, try date("2026-06-21 11:00"))
        XCTAssertEqual(snapshot.buckets.last?.start, try date("2026-06-22 10:00"))
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

    func testReaderLoadsRowsFromSQLiteDatabase() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try createFixtureDatabase(at: databaseURL)

        let records = try await CCTokenUsageReader(databaseURL: databaseURL).records(
            from: Date(timeIntervalSince1970: 1_000),
            through: Date(timeIntervalSince1970: 3_000)
        )

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

    private func createFixtureDatabase(at url: URL) throws {
        var databasePointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &databasePointer), SQLITE_OK)
        let database = try XCTUnwrap(databasePointer)
        defer { sqlite3_close(database) }

        let sql = """
            CREATE TABLE proxy_request_logs (
                created_at INTEGER NOT NULL,
                app_type TEXT NOT NULL,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                cache_read_tokens INTEGER NOT NULL,
                cache_creation_tokens INTEGER NOT NULL
            );
            INSERT INTO proxy_request_logs VALUES (2000, 'codex', 100, 12, 80, 0);
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }
}
