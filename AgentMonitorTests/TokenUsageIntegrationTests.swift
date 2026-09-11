import Foundation
import SQLite3
import XCTest
@testable import AgentMonitor

final class TokenUsageIntegrationTests: XCTestCase {
    func testSameSessionIsNotProofThatEqualUsageRequestsAreDuplicates() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("usage.db")
        let database = TokenUsageDatabase(databaseURL: url, ccSwitchDatabaseURL: home.appendingPathComponent("missing.db"), sessionRoots: .default(home: home))
        _ = try await database.records(from: Date(timeIntervalSince1970: 0), through: Date())
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        let db = try XCTUnwrap(pointer)
        defer { sqlite3_close(db) }
        let sql = """
        INSERT INTO token_usage_records(request_id,app_type,model,input_tokens,output_tokens,created_at,session_id,data_source,synced_from,synced_at) VALUES
        ('session:m1','claude','claude-opus-5',100,10,2000,'same-session','session_log','session-logs',3000),
        ('proxy-near','claude','claude-opus-5',100,10,2001,'same-session','proxy','cc-switch',3000),
        ('proxy-far','claude','claude-opus-5',100,10,2500,'same-session','proxy','cc-switch',3000),
        ('session:m2','claude','claude-opus-5',100,10,2001,'same-session','session_log','session-logs',3000);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        _ = try await database.syncFromSessionLogs(now: Date(timeIntervalSince1970: 3000))
        let rows = try await database.records(from: Date(timeIntervalSince1970: 0), through: Date(timeIntervalSince1970: 3000))
        XCTAssertEqual(rows.count, 4, "Raw rows must be preserved")
        XCTAssertEqual(rows.filter { $0.accountingStatus == "duplicate" }.count, 0)
        XCTAssertEqual(rows.filter { $0.accountingStatus == "pending" }.count, 1)
        XCTAssertEqual(rows.filter { $0.accountingStatus == "included" }.count, 3)
    }

    @MainActor
    func testFourRealLogFormatsAppendRestartAndPartialLineWithoutCCSwitch() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home.appendingPathComponent("usage.db")
        let missingCC = home.appendingPathComponent("never-created-cc-switch.db")
        let thread = "01a090d7-2603-7020-b048-551ea523e85c"
        let codex = home.appendingPathComponent(".codex/sessions/2026/09/11/rollout-\(thread).jsonl")
        let claude = home.appendingPathComponent(".claude/projects/p/s.jsonl")
        try write("""
        {"type":"session_meta","timestamp":"2026-09-11T01:00:00Z","payload":{"id":"\(thread)"}}
        {"type":"turn_context","payload":{"model":"gpt-6-astra"}}
        {"type":"event_msg","timestamp":"2026-09-11T01:01:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":12},"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":12}}}}
        """ + "\n", to: codex)
        try write("""
        {"type":"assistant","timestamp":"2026-09-11T01:01:00Z","sessionId":"c1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":2,"output_tokens":5},"stop_reason":null}}
        """ + "\n", to: claude)
        try write("""
        {"method":"_x.ai/session/update","timestamp":1789088460,"params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"inputTokens":1000,"cachedReadTokens":300,"outputTokens":300,"modelUsage":{"grok-4.6":{"inputTokens":1000,"cachedReadTokens":300,"outputTokens":300}}}}}}
        """ + "\n", to: home.appendingPathComponent(".grok/sessions/p/g1/updates.jsonl"))
        try write("""
        {"kind":"session","sessionId":"g1","startTime":"2026-09-11T01:00:00Z"}
        {"type":"gemini","id":"m1","model":"gemini-3.8-flash-high","timestamp":"2026-09-11T01:01:00Z","tokens":{"input":40,"cached":10,"output":6,"thoughts":4,"total":50}}
        """ + "\n", to: home.appendingPathComponent(".gemini/tmp/p/chats/session-g1.jsonl"))
        let now = ISO8601DateFormatter().date(from: "2026-09-11T03:00:00Z")!
        let database = TokenUsageDatabase(databaseURL: dbURL, ccSwitchDatabaseURL: missingCC, sessionRoots: .default(home: home))
        let store = TokenUsageStore(reader: database)
        await store.refresh(range: .last24Hours, now: now)
        XCTAssertNil(store.errorDescription)
        XCTAssertEqual(store.snapshot?.totalTokens, 1_519)
        XCTAssertEqual(store.snapshot?.modelIDs.count, 4)
        XCTAssertEqual(store.snapshot?.filtered(model: "gpt-6-astra").totalTokens, 112)

        let originalModification = try codex.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try append("""
        {"type":"event_msg","timestamp":"2026-09-11T01:02:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40,"cached_input_tokens":10,"output_tokens":5},"total_token_usage":{"input_tokens":140,"cached_input_tokens":90,"output_tokens":17}}}}
        """ + "\n", to: codex)
        try FileManager.default.setAttributes([.modificationDate: originalModification], ofItemAtPath: codex.path)
        try append("""
        {"type":"assistant","timestamp":"2026-09-11T01:02:00Z","sessionId":"c1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":2,"output_tokens":8},"stop_reason":"end_turn"}}
        """ + "\n", to: claude)
        await store.refresh(range: .last24Hours, now: now)
        XCTAssertNil(store.errorDescription)
        XCTAssertEqual(store.snapshot?.totalTokens, 1_567)

        let restartedDatabase = TokenUsageDatabase(databaseURL: dbURL, ccSwitchDatabaseURL: missingCC, sessionRoots: .default(home: home))
        let restarted = TokenUsageStore(reader: restartedDatabase)
        await restarted.refresh(range: .last24Hours, now: now)
        XCTAssertEqual(restarted.snapshot?.totalTokens, 1_567)

        let finalLine = """
        {"type":"event_msg","timestamp":"2026-09-11T01:03:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":2},"total_token_usage":{"input_tokens":147,"cached_input_tokens":90,"output_tokens":19}}}}
        """
        let split = finalLine.index(finalLine.startIndex, offsetBy: finalLine.count / 2)
        try append(String(finalLine[..<split]), to: codex)
        await restarted.refresh(range: .last24Hours, now: now)
        XCTAssertEqual(restarted.snapshot?.totalTokens, 1_567)
        try append(String(finalLine[split...]) + "\n", to: codex)
        await restarted.refresh(range: .last24Hours, now: now)
        XCTAssertEqual(restarted.snapshot?.totalTokens, 1_576)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingCC.path))
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
}
