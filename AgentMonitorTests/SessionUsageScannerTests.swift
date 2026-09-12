import Foundation
import XCTest
@testable import AgentMonitor

final class SessionUsageScannerTests: XCTestCase {
    func testGeminiJSONLParsesMetadataAndTokenUsageWithoutFakeTimestamp() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".gemini/tmp/project/chats/session-g1.jsonl")
        try write(
            """
            {"kind":"session","sessionId":"g1","startTime":"2026-09-11T01:00:00Z"}
            {"type":"gemini","id":"m1","model":"gemini-3.8-flash-high","timestamp":"2026-09-11T01:01:00Z","tokens":{"input":40,"cached":10,"output":6,"thoughts":4,"total":50}}
            """ + "\n",
            to: file
        )

        let result = SessionUsageScanner.scan(
            roots: .default(home: home),
            now: 1
        )

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.requestID, "gemini_session:g1:m1")
        XCTAssertEqual(result.entries.first?.outputTokens, 10)
        XCTAssertEqual(result.entries.first?.createdAt, 1789088460)
        XCTAssertEqual(result.entries.first?.sourcePath, file.resolvingSymlinksInPath().path)
        XCTAssertFalse(result.diagnostics.contains { $0.reason.contains("timestamp") })
    }

    func testClaudeFinalStateReplacesPendingVersionAndAllowsUpsert() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".claude/projects/project/session.jsonl")
        try write(
            """
            {"type":"assistant","timestamp":"2026-09-11T01:00:00Z","sessionId":"c1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":20,"output_tokens":5,"cache_read_input_tokens":30,"cache_creation_input_tokens":2}},"stop_reason":null}
            {"type":"assistant","timestamp":"2026-09-11T01:00:01Z","sessionId":"c1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":20,"output_tokens":8,"cache_read_input_tokens":30,"cache_creation_input_tokens":2}},"stop_reason":"end_turn"}
            """ + "\n",
            to: file
        )

        let result = SessionUsageScanner.scan(roots: .default(home: home))
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.outputTokens, 8)
        XCTAssertEqual(result.entries.first?.isFinal, true)
        XCTAssertEqual(result.entries.first?.accountingStatus, "included")
        XCTAssertEqual(result.entries.first?.upsertOnConflict, true)
    }

    func testPartialLineAndSameMTimeAppendResumeFromCompleteByteOffset() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".grok/sessions/project/session/updates.jsonl")
        let first = """
        {"timestamp":1789088460,"params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"inputTokens":100,"outputTokens":20,"cachedReadTokens":10,"modelUsage":{"grok-4.6":{"inputTokens":100,"outputTokens":20,"cachedReadTokens":10}}}}}}
        """ + "\n"
        let second = "{" + "\"timestamp\":1789088461,\"params\":{\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p2\",\"usage\":{\"inputTokens\":30,\"outputTokens\":4,\"cachedReadTokens\":0,\"modelUsage\":{\"grok-4.6\":{\"inputTokens\":30,\"outputTokens\":4,\"cachedReadTokens\":0}}}}}}"
        try write(first, to: file)
        let firstResult = SessionUsageScanner.scan(roots: .default(home: home))
        let cursor = try XCTUnwrap(firstResult.fileStates.first)
        XCTAssertEqual(firstResult.entries.count, 1)

        let mtime = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let splitIndex = second.index(second.startIndex, offsetBy: second.count / 2)
        try append(String(second[..<splitIndex]), to: file)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        let partial = SessionUsageScanner.scan(
            roots: .default(home: home),
            existingCursors: [file.path: cursor]
        )
        XCTAssertEqual(partial.entries.count, 1)
        XCTAssertTrue(partial.diagnostics.contains { $0.path == file.path && $0.reason == "incomplete_final_line" })
        XCTAssertLessThan(partial.fileStates.first?.completeByteOffset ?? 0, partial.fileStates.first?.fileSize ?? 0)

        try append(String(second[splitIndex...]) + "\n", to: file)
        let complete = SessionUsageScanner.scan(
            roots: .default(home: home),
            existingCursors: [file.path: try XCTUnwrap(partial.fileStates.first)]
        )
        XCTAssertEqual(Set(complete.entries.map(\.requestID)), Set([
            "grok_session:session:p1:grok-4.6",
            "grok_session:session:p2:grok-4.6"
        ]))
        XCTAssertEqual(complete.fileStates.first?.completeByteOffset, complete.fileStates.first?.fileSize)
        let unchanged = SessionUsageScanner.scan(
            roots: .default(home: home),
            existingCursors: [file.path: try XCTUnwrap(complete.fileStates.first)]
        )
        XCTAssertTrue(unchanged.entries.isEmpty)
        XCTAssertTrue(unchanged.fileStates.isEmpty)
    }

    func testParentReplayNeedsSignatureEvidenceAndRetainsDuplicateRows() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let parentID = "019e44e8-450f-7cd2-abea-804ddd037907"
        let childID = "019e44e8-450f-7cd2-abea-804ddd037908"
        let parent = home.appendingPathComponent(".codex/sessions/2026/09/11/rollout-\(parentID).jsonl")
        let child = home.appendingPathComponent(".codex/sessions/2026/09/11/rollout-\(childID).jsonl")
        let token = { (timestamp: String, input: Int) in
            "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":0,\"output_tokens\":2},\"total_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":0,\"output_tokens\":2}}}}"
        }
        try write(
            "{" + "\"type\":\"session_meta\",\"timestamp\":\"2026-09-11T01:00:00Z\",\"payload\":{\"id\":\"\(parentID)\"}}" + "\n" + token("2026-09-11T01:00:01Z", 10) + "\n",
            to: parent
        )
        try write(
            "{" + "\"type\":\"session_meta\",\"timestamp\":\"2026-09-11T01:05:00Z\",\"payload\":{\"id\":\"\(childID)\",\"parent_thread_id\":\"\(parentID)\"}}" + "\n" + token("2026-09-11T01:00:01Z", 10) + "\n" + token("2026-09-11T01:00:02Z", 20) + "\n",
            to: child
        )

        let result = SessionUsageScanner.scan(roots: .default(home: home))
        let childEntry = try XCTUnwrap(result.entries.first { $0.sessionID == childID })
        XCTAssertEqual(childEntry.accountingStatus, "duplicate")
        XCTAssertEqual(childEntry.accountingReason, "replay_of_parent")
        XCTAssertEqual(result.entries.filter { $0.sessionID == childID }.count, 2)
        XCTAssertEqual(result.entries.filter { $0.sessionID == childID && $0.accountingStatus == "included" }.count, 1)
    }

    func testMissingParentIsReevaluatedWhenParentAppears() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let parentID = "019e44e8-450f-7cd2-abea-804ddd037907"
        let childID = "019e44e8-450f-7cd2-abea-804ddd037908"
        let parent = home.appendingPathComponent(".codex/sessions/2026/09/11/rollout-\(parentID).jsonl")
        let child = home.appendingPathComponent(".codex/sessions/2026/09/11/rollout-\(childID).jsonl")
        let token = "{\"type\":\"event_msg\",\"timestamp\":\"2026-09-11T01:00:01Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":10,\"cached_input_tokens\":0,\"output_tokens\":2},\"total_token_usage\":{\"input_tokens\":10,\"cached_input_tokens\":0,\"output_tokens\":2}}}}\n"
        try write(
            "{\"type\":\"session_meta\",\"timestamp\":\"2026-09-11T01:05:00Z\",\"payload\":{\"id\":\"\(childID)\",\"parent_thread_id\":\"\(parentID)\"}}\n" + token,
            to: child
        )
        let first = SessionUsageScanner.scan(roots: .default(home: home))
        let childCursor = try XCTUnwrap(first.fileStates.first { $0.path == child.path })
        XCTAssertEqual(first.entries.first { $0.sessionID == childID }?.accountingStatus, "pending")

        try write(
            "{\"type\":\"session_meta\",\"timestamp\":\"2026-09-11T01:00:00Z\",\"payload\":{\"id\":\"\(parentID)\"}}\n" + token,
            to: parent
        )
        let second = SessionUsageScanner.scan(
            roots: .default(home: home),
            existingCursors: [child.path: childCursor]
        )
        XCTAssertEqual(second.entries.first { $0.sessionID == childID }?.accountingStatus, "duplicate")
    }

    func testCopiedAncestorMetadataStaysPendingUntilMatchingRootAppears() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let threadID = "019e44e8-450f-7cd2-abea-804ddd037907"
        let copiedAncestorID = "019e44e8-450f-7cd2-abea-804ddd037908"
        let file = home.appendingPathComponent(
            ".codex/sessions/2026/09/11/rollout-\(threadID).jsonl"
        )
        let token = "{\"type\":\"event_msg\",\"timestamp\":\"2026-09-11T01:00:01Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":10,\"cached_input_tokens\":0,\"output_tokens\":2},\"total_token_usage\":{\"input_tokens\":10,\"cached_input_tokens\":0,\"output_tokens\":2}}}}\n"
        try write(
            "{\"type\":\"session_meta\",\"timestamp\":\"2026-09-11T00:59:00Z\",\"payload\":{\"id\":\"\(copiedAncestorID)\"}}\n" + token,
            to: file
        )

        let first = SessionUsageScanner.scan(roots: .default(home: home))
        let pending = try XCTUnwrap(first.entries.first { $0.sessionID == threadID })
        XCTAssertEqual(pending.accountingStatus, "pending")
        XCTAssertEqual(pending.accountingReason, "missing_session_meta")
        XCTAssertTrue(first.diagnostics.contains { $0.reason == "thread_id_mismatch" })

        try append(
            "{\"type\":\"session_meta\",\"timestamp\":\"2026-09-11T01:01:00Z\",\"payload\":{\"id\":\"\(threadID)\"}}\n",
            to: file
        )
        let cursor = try XCTUnwrap(first.fileStates.first)
        let second = SessionUsageScanner.scan(
            roots: .default(home: home),
            existingCursors: [cursor.path: cursor]
        )
        let included = try XCTUnwrap(second.entries.first { $0.sessionID == threadID })
        XCTAssertEqual(included.accountingStatus, "included")
        XCTAssertNil(included.accountingReason)
        XCTAssertFalse(second.diagnostics.contains { $0.reason == "thread_id_mismatch" })
    }

    func testCompoundChildFilenameUsesCopiedParentMetadataAsRelationshipEvidence() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let parentID = "019e44e8-450f-7cd2-abea-804ddd037907"
        let childID = "019e44e8-450f-7cd2-abea-804ddd037908"
        let parent = home.appendingPathComponent(
            ".codex/sessions/2026/09/11/rollout-2026-09-11T01-00-00-\(parentID).jsonl"
        )
        let child = home.appendingPathComponent(
            ".codex/sessions/2026/09/11/rollout-2026-09-11T01-05-00-\(parentID)_\(childID).jsonl"
        )
        let replay = "{\"type\":\"event_msg\",\"timestamp\":\"2026-09-11T01:00:01Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":10,\"cached_input_tokens\":0,\"output_tokens\":2},\"total_token_usage\":{\"input_tokens\":10,\"cached_input_tokens\":0,\"output_tokens\":2}}}}\n"
        let unique = "{\"type\":\"event_msg\",\"timestamp\":\"2026-09-11T01:05:01Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":20,\"cached_input_tokens\":0,\"output_tokens\":3},\"total_token_usage\":{\"input_tokens\":20,\"cached_input_tokens\":0,\"output_tokens\":3}}}}\n"
        try write(
            "{\"type\":\"session_meta\",\"timestamp\":\"2026-09-11T01:00:00Z\",\"payload\":{\"id\":\"\(parentID)\"}}\n" + replay,
            to: parent
        )
        // Current Codex compound child files retain the parent's ID in their
        // sole session_meta line; the child ID exists only as the suffix.
        try write(
            "{\"type\":\"session_meta\",\"timestamp\":\"2026-09-11T01:05:00Z\",\"payload\":{\"id\":\"\(parentID)\"}}\n" + replay + unique,
            to: child
        )

        let result = SessionUsageScanner.scan(roots: .default(home: home))
        let childRows = result.entries.filter { $0.sessionID == childID }
        XCTAssertEqual(childRows.count, 2)
        XCTAssertEqual(childRows.filter { $0.accountingStatus == "duplicate" }.count, 1)
        XCTAssertEqual(childRows.filter { $0.accountingStatus == "included" }.count, 1)
        XCTAssertFalse(childRows.contains { $0.accountingReason == "missing_session_meta" })
        XCTAssertFalse(result.diagnostics.contains { $0.path == child.path && $0.reason == "thread_id_mismatch" })
    }

    func testLargeFileIsStreamedInsteadOfSilentlySkipped() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".grok/sessions/project/session/updates.jsonl")
        let size = 50 * 1024 * 1024 + 1
        var data = Data()
        let line = Data(("{\"kind\":\"padding\",\"value\":\"" + String(repeating: "x", count: 4_000) + "\"}\n").utf8)
        while data.count <= size { data.append(line) }
        let billable = "{\"timestamp\":1789088460,\"params\":{\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"large\",\"usage\":{\"inputTokens\":11,\"outputTokens\":3,\"cachedReadTokens\":0,\"modelUsage\":{\"grok-4.6\":{\"inputTokens\":11,\"outputTokens\":3,\"cachedReadTokens\":0}}}}}}\n"
        data.append(Data(billable.utf8))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        let result = SessionUsageScanner.scan(roots: .default(home: home))
        XCTAssertEqual(result.fileStates.first?.fileSize, Int64(data.count))
        XCTAssertFalse(result.diagnostics.contains { $0.reason == "read_failed" })
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.inputTokens, 11)
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.resolvingSymlinksInPath()
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
