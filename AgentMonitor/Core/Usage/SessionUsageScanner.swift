import Foundation

struct SessionUsageEntry: Sendable, Equatable {
    let requestID: String
    let appType: String
    let model: String
    let sessionID: String?
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    let createdAt: Int64
    let dataSource: String
    let providerID: String
    let providerType: String
    let inputTokenSemantics: Int64
    let upsertOnConflict: Bool
    let isFinal: Bool
    let accountingStatus: String
    let accountingReason: String?
    let sourcePath: String?

    init(
        requestID: String,
        appType: String,
        model: String,
        sessionID: String?,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheCreationTokens: Int64,
        createdAt: Int64,
        dataSource: String,
        providerID: String,
        providerType: String,
        inputTokenSemantics: Int64,
        upsertOnConflict: Bool,
        isFinal: Bool = false,
        accountingStatus: String = "included",
        accountingReason: String? = nil,
        sourcePath: String? = nil
    ) {
        self.requestID = requestID
        self.appType = appType
        self.model = model
        self.sessionID = sessionID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.createdAt = createdAt
        self.dataSource = dataSource
        self.providerID = providerID
        self.providerType = providerType
        self.inputTokenSemantics = inputTokenSemantics
        self.upsertOnConflict = upsertOnConflict
        self.isFinal = isFinal
        self.accountingStatus = accountingStatus
        self.accountingReason = accountingReason
        self.sourcePath = sourcePath
    }
}

struct SessionLogRoots: Sendable, Equatable {
    var claudeProjects: URL
    var codexHome: URL
    var grokHome: URL
    var geminiHome: URL

    static func `default`(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SessionLogRoots {
        SessionLogRoots(
            claudeProjects: home.appendingPathComponent(".claude/projects"),
            codexHome: home.appendingPathComponent(".codex"),
            grokHome: home.appendingPathComponent(".grok"),
            geminiHome: home.appendingPathComponent(".gemini")
        )
    }
}

struct SessionFileCursor: Sendable, Equatable {
    let path: String
    let lastModified: Int64
    let lastLineOffset: Int64
    let fileIdentity: String
    let fileSize: Int64
    let completeByteOffset: Int64
    let tailFingerprint: String

    init(
        path: String,
        lastModified: Int64,
        lastLineOffset: Int64,
        fileIdentity: String = "",
        fileSize: Int64 = 0,
        completeByteOffset: Int64 = 0,
        tailFingerprint: String = ""
    ) {
        self.path = path
        self.lastModified = lastModified
        self.lastLineOffset = lastLineOffset
        self.fileIdentity = fileIdentity
        self.fileSize = fileSize
        self.completeByteOffset = completeByteOffset
        self.tailFingerprint = tailFingerprint
    }
}

struct SessionScanDiagnostic: Identifiable, Sendable, Equatable {
    let path: String
    let reason: String

    var id: String { "\(path)|\(reason)" }
}

struct SessionScanResult: Sendable, Equatable {
    var entries: [SessionUsageEntry] = []
    var fileStates: [SessionFileCursor] = []
    var diagnostics: [SessionScanDiagnostic] = []
}

enum SessionLogKind: Sendable {
    case claude
    case codex
    case grok
    case gemini
}

struct SessionLogFile: Sendable, Equatable {
    let url: URL
    let kind: SessionLogKind
}

enum SessionLogDiscovery {
    private static let maxGrokDepth = 16

    static func collect(
        roots: SessionLogRoots,
        fileManager: FileManager = .default
    ) -> [SessionLogFile] {
        var files: [SessionLogFile] = []
        collectClaude(from: roots.claudeProjects, fileManager: fileManager, into: &files)
        collectCodex(from: roots.codexHome, fileManager: fileManager, into: &files)
        collectGrok(from: roots.grokHome, fileManager: fileManager, into: &files)
        collectGemini(from: roots.geminiHome, fileManager: fileManager, into: &files)
        return files
    }

    private static func collectClaude(
        from projectsDir: URL,
        fileManager: FileManager,
        into files: inout [SessionLogFile]
    ) {
        guard let projects = directoryContents(projectsDir, fileManager: fileManager) else { return }
        for project in projects where isDirectory(project, fileManager: fileManager) {
            guard let children = directoryContents(project, fileManager: fileManager) else { continue }
            for child in children {
                if child.pathExtension == "jsonl" {
                    files.append(SessionLogFile(url: child, kind: .claude))
                } else if isDirectory(child, fileManager: fileManager) {
                    let subagents = child.appendingPathComponent("subagents")
                    appendJSONLChildren(subagents, fileManager: fileManager, kind: .claude, into: &files)
                    let workflows = subagents.appendingPathComponent("workflows")
                    guard let workflowDirs = directoryContents(workflows, fileManager: fileManager) else {
                        continue
                    }
                    for workflow in workflowDirs where isDirectory(workflow, fileManager: fileManager) {
                        appendJSONLChildren(
                            workflow,
                            fileManager: fileManager,
                            kind: .claude,
                            into: &files
                        )
                    }
                }
            }
        }
    }

    private static func collectCodex(
        from codexHome: URL,
        fileManager: FileManager,
        into files: inout [SessionLogFile]
    ) {
        collectJSONLRecursive(
            codexHome.appendingPathComponent("sessions"),
            depth: 0,
            maxDepth: 3,
            fileManager: fileManager,
            kind: .codex,
            into: &files
        )
        appendJSONLChildren(
            codexHome.appendingPathComponent("archived_sessions"),
            fileManager: fileManager,
            kind: .codex,
            into: &files
        )
    }

    private static func collectGrok(
        from grokHome: URL,
        fileManager: FileManager,
        into files: inout [SessionLogFile]
    ) {
        for rootName in ["sessions", "archived_sessions"] {
            collectNamedFile(
                grokHome.appendingPathComponent(rootName),
                name: "updates.jsonl",
                depth: 0,
                fileManager: fileManager,
                into: &files
            )
        }
    }

    private static func collectGemini(
        from geminiHome: URL,
        fileManager: FileManager,
        into files: inout [SessionLogFile]
    ) {
        let tmp = geminiHome.appendingPathComponent("tmp")
        guard let projects = directoryContents(tmp, fileManager: fileManager) else { return }
        for project in projects {
            let chats = project.appendingPathComponent("chats")
            guard let chatFiles = directoryContents(chats, fileManager: fileManager) else { continue }
            for file in chatFiles {
                let name = file.lastPathComponent
                if name.hasPrefix("session-"),
                   (name.hasSuffix(".json") || name.hasSuffix(".jsonl")) {
                    files.append(SessionLogFile(url: file, kind: .gemini))
                }
            }
        }
    }

    private static func collectNamedFile(
        _ root: URL,
        name: String,
        depth: Int,
        fileManager: FileManager,
        into files: inout [SessionLogFile]
    ) {
        guard depth <= maxGrokDepth else { return }
        guard let contents = directoryContents(root, fileManager: fileManager) else { return }
        for child in contents {
            let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                collectNamedFile(
                    child,
                    name: name,
                    depth: depth + 1,
                    fileManager: fileManager,
                    into: &files
                )
            } else if child.lastPathComponent == name {
                files.append(SessionLogFile(url: child, kind: .grok))
            }
        }
    }

    private static func collectJSONLRecursive(
        _ dir: URL,
        depth: Int,
        maxDepth: Int,
        fileManager: FileManager,
        kind: SessionLogKind,
        into files: inout [SessionLogFile]
    ) {
        guard let contents = directoryContents(dir, fileManager: fileManager) else { return }
        for child in contents {
            if isDirectory(child, fileManager: fileManager), depth < maxDepth {
                collectJSONLRecursive(
                    child,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    fileManager: fileManager,
                    kind: kind,
                    into: &files
                )
            } else if child.pathExtension == "jsonl" {
                files.append(SessionLogFile(url: child, kind: kind))
            }
        }
    }

    private static func appendJSONLChildren(
        _ dir: URL,
        fileManager: FileManager,
        kind: SessionLogKind,
        into files: inout [SessionLogFile]
    ) {
        guard let contents = directoryContents(dir, fileManager: fileManager) else { return }
        for child in contents where child.pathExtension == "jsonl" {
            files.append(SessionLogFile(url: child, kind: kind))
        }
    }

    private static func directoryContents(_ dir: URL, fileManager: FileManager) -> [URL]? {
        try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

enum SessionUsageParser {
    // Kept as a compatibility marker for callers that used the old limit. Files are now
    // read incrementally; the scanner no longer rejects a log solely because it is large.
    static let maxFileBytes: UInt64 = 50 * 1024 * 1024

    static func claudeEntries(from jsonl: String, now: Int64) -> [SessionUsageEntry] {
        var accumulator = ClaudeUsageAccumulator()
        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: false) {
            accumulator.consume(String(line), lineNumber: nil, path: nil)
        }
        return accumulator.entries(now: now, path: nil)
    }

    static func grokEntries(
        from jsonl: String,
        sessionID: String
    ) -> [SessionUsageEntry] {
        var accumulator = GrokUsageAccumulator(sessionID: sessionID)
        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: false) {
            accumulator.consume(String(line), lineNumber: nil, path: nil)
        }
        return accumulator.entries(path: nil)
    }

    static func geminiEntries(from json: String, now: Int64) -> [SessionUsageEntry] {
        var accumulator = GeminiUsageAccumulator()
        if let object = JSONMap.object(from: json), let messages = object["messages"] as? [Any] {
            accumulator.consumeObject(object, lineNumber: 1, path: nil)
            for message in messages {
                accumulator.consumeObject(
                    JSONMap.object(message) ?? [:],
                    lineNumber: nil,
                    path: nil
                )
            }
        } else {
            for (index, line) in json.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                accumulator.consume(
                    String(line),
                    lineNumber: Int64(index + 1),
                    path: nil
                )
            }
        }
        return accumulator.entries(path: nil)
    }

    static func parseCodex(jsonl: String, fileName: String) -> ParsedCodexFile {
        var parsed = ParsedCodexFile(rootThreadID: threadIDFromFilename(fileName))
        var currentModel = "unknown"
        var totalHighWater: CodexCumulative?
        var lastSignatureBySource: [String?: CodexTokenSignature] = [:]
        var previousSignature: CodexTokenSignature?
        var eventIndex: UInt32 = 0
        var lineOffset: Int64 = 0

        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: false) {
            lineOffset += 1
            let raw = String(line)
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let isEventMsg = raw.contains("\"event_msg\"")
            let isTurnContext = raw.contains("\"turn_context\"")
            let isSessionMeta = raw.contains("\"session_meta\"")
            if !isEventMsg && !isTurnContext && !isSessionMeta { continue }
            if isEventMsg && !raw.contains("\"token_count\"") { continue }
            guard let object = JSONMap.object(from: raw),
                  let eventType = JSONMap.string(object["type"]) else { continue }

            switch eventType {
            case "session_meta" where !parsed.rootMetaSeen:
                let payload = JSONMap.object(object["payload"]) ?? [:]
                if let filenameID = parsed.rootThreadID,
                   let metaID = nonEmptyString(
                    payload["id"] ?? payload["thread_id"] ?? payload["threadId"]
                        ?? object["id"] ?? object["thread_id"] ?? object["threadId"]
                   ),
                   filenameID != metaID.lowercased() {
                    // A copied ancestor can precede the real root metadata.
                    continue
                }
                parsed.rootMetaSeen = true
                parsed.rootTimestamp = RFC3339.unixSeconds(JSONMap.string(object["timestamp"]))
                let parentValues = parentThreadIDs(from: object, payload: payload)
                parsed.parentThreadIDConflict = parentValues.count > 1
                parsed.parentThreadID = parentValues.count == 1 ? parentValues[0] : nil
                if parsed.parentThreadID == parsed.rootThreadID {
                    parsed.parentThreadID = nil
                    parsed.parentThreadIDConflict = true
                }
            case "turn_context":
                if let payload = JSONMap.object(object["payload"]) {
                    if let model = JSONMap.string(
                        payload["model"] ?? JSONMap.object(payload["info"])?["model"]
                    ) {
                        currentModel = model
                    }
                }
            case "event_msg":
                guard let payload = JSONMap.object(object["payload"]),
                      JSONMap.string(payload["type"]) == "token_count",
                      let info = JSONMap.object(payload["info"]),
                      let signature = parseCodexSignature(info) else { continue }
                if let model = JSONMap.string(
                    info["model"] ?? info["model_name"] ?? payload["model"]
                ) {
                    currentModel = model
                }
                let source = JSONMap.string(JSONMap.object(payload["rate_limits"])?["limit_id"])
                let total = parseCodexCumulative(info["total_token_usage"])
                let last = parseCodexCumulative(info["last_token_usage"])
                if total == nil && last == nil { continue }

                let hasTotalSnapshot = total != nil
                let duplicate = hasTotalSnapshot
                    && (lastSignatureBySource[source] == signature || previousSignature == signature)
                if hasTotalSnapshot {
                    lastSignatureBySource[source] = signature
                }
                previousSignature = signature

                var delta: CodexCumulative
                if duplicate {
                    delta = CodexCumulative(input: 0, cachedInput: 0, output: 0)
                } else if let last {
                    delta = last
                } else if let total {
                    delta = computeCodexDelta(previous: totalHighWater, current: total)
                } else {
                    continue
                }
                if let total {
                    if var highWater = totalHighWater {
                        highWater.input = max(highWater.input, total.input)
                        highWater.cachedInput = max(highWater.cachedInput, total.cachedInput)
                        highWater.output = max(highWater.output, total.output)
                        totalHighWater = highWater
                    } else {
                        totalHighWater = total
                    }
                }
                delta.cachedInput = min(delta.cachedInput, delta.input)
                let index: UInt32?
                if delta.input == 0 && delta.cachedInput == 0 && delta.output == 0 {
                    index = nil
                } else {
                    parsed.hasBillableTokens = true
                    eventIndex &+= 1
                    index = eventIndex
                }
                parsed.events.append(
                    ParsedCodexEvent(
                        lineOffset: lineOffset,
                        signature: signature,
                        input: delta.input,
                        cachedInput: delta.cachedInput,
                        output: delta.output,
                        eventIndex: index,
                        model: currentModel,
                        timestamp: JSONMap.string(object["timestamp"])
                    )
                )
            default:
                continue
            }
        }

        parsed.lineOffset = lineOffset
        return parsed
    }

    static func matchingReplayPrefix(
        child: [ParsedCodexEvent],
        parent: [CodexTokenSignature]
    ) -> Int {
        var parentOffset = 0
        var matched = 0
        for event in child where event.eventIndex != nil {
            guard let relative = parent[parentOffset...].firstIndex(of: event.signature) else {
                break
            }
            parentOffset = relative + 1
            matched += 1
        }
        return matched
    }

    static func normalizeCodexModel(_ raw: String) -> String {
        var name = raw.lowercased()
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if name.count > 11 {
            let suffix = String(name.suffix(11))
            let digits = suffix.utf8.map { $0 }
            if digits.count == 11,
               digits[0] == UInt8(ascii: "-"),
               digits[1...4].allSatisfy({ (48...57).contains($0) }),
               digits[5] == UInt8(ascii: "-"),
               digits[6...7].allSatisfy({ (48...57).contains($0) }),
               digits[8] == UInt8(ascii: "-"),
               digits[9...10].allSatisfy({ (48...57).contains($0) }) {
                name.removeLast(11)
            }
        }
        if name.count > 9, let dash = name.lastIndex(of: "-") {
            let suffix = name[name.index(after: dash)...]
            if suffix.count == 8, suffix.allSatisfy(\.isNumber) {
                name = String(name[..<dash])
            }
        }
        return name
    }

    static func threadIDFromFilename(_ fileName: String) -> String? {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        if stem.count >= 36 {
            let candidate = String(stem.suffix(36))
            if let uuid = UUID(uuidString: candidate) {
                return uuid.uuidString.lowercased()
            }
        }
        // Current Codex rollout filenames end in a 26-character ULID rather
        // than a UUID. Keep the raw ID; it is also the value in session_meta.
        guard let candidate = stem.split(separator: "-").last,
              candidate.count >= 20,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return candidate.lowercased()
    }

    fileprivate static func shouldReplaceClaude(existing: ClaudeUsage?, with parsed: ClaudeUsage) -> Bool {
        guard let existing else { return true }
        if parsed.stopReason != nil && existing.stopReason == nil { return true }
        if (parsed.stopReason != nil) == (existing.stopReason != nil) {
            return parsed.outputTokens > existing.outputTokens
        }
        return false
    }
}

struct ParsedCodexFile: Equatable {
    var rootThreadID: String?
    var rootMetaSeen = false
    var rootTimestamp: Int64?
    var parentThreadID: String?
    var parentThreadIDConflict = false
    var events: [ParsedCodexEvent] = []
    var lineOffset: Int64 = 0
    var hasBillableTokens = false
}

struct ParsedCodexEvent: Equatable {
    let lineOffset: Int64
    let signature: CodexTokenSignature
    let input: Int64
    let cachedInput: Int64
    let output: Int64
    let eventIndex: UInt32?
    let model: String
    let timestamp: String?
}

struct CodexTokenSignature: Equatable {
    var total: CodexCounterSignature?
    var last: CodexCounterSignature?
}

struct CodexCounterSignature: Equatable {
    var input: Int64?
    var cachedInput: Int64?
    var output: Int64?
    var reasoningOutput: Int64?
    var total: Int64?
}

private struct CodexCumulative: Equatable {
    var input: Int64
    var cachedInput: Int64
    var output: Int64
}

private struct ClaudeUsage {
    let messageID: String
    let model: String
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    let stopReason: String?
    let timestamp: String?
    let sessionID: String?
}

private struct GrokCounters {
    var input: Int64
    var output: Int64
    var cached: Int64
    var cacheCreation: Int64

    var isZero: Bool { input == 0 && output == 0 && cached == 0 && cacheCreation == 0 }

    init(from object: [String: Any]) {
        input = JSONMap.int64(object["inputTokens"])
        output = JSONMap.int64(object["outputTokens"])
        cached = JSONMap.int64(object["cachedReadTokens"])
        cacheCreation = JSONMap.int64(object["cacheCreationTokens"] ?? object["cacheCreationInputTokens"])
    }
}

private func appendUsageDiagnostic(
    path: String?,
    reason: String,
    to diagnostics: inout [SessionScanDiagnostic]
) {
    guard let path else { return }
    let diagnostic = SessionScanDiagnostic(path: path, reason: reason)
    if !diagnostics.contains(diagnostic) {
        diagnostics.append(diagnostic)
    }
}

private struct ClaudeUsageAccumulator {
    private var values: [String: ClaudeUsage] = [:]
    private(set) var diagnostics: [SessionScanDiagnostic] = []

    mutating func consume(_ raw: String, lineNumber: Int64?, path: String?) {
        guard let object = JSONMap.object(from: raw) else {
            if raw.contains("\"assistant\"") || raw.contains("\"usage\"") {
                appendUsageDiagnostic(path: path, reason: "malformed_json", to: &diagnostics)
            }
            return
        }
        let message = JSONMap.object(object["message"]) ?? object
        guard JSONMap.string(object["type"]) == "assistant",
              let usage = JSONMap.object(message["usage"] ?? object["usage"]),
              let messageID = nonEmptyString(message["id"] ?? object["id"])
        else { return }

        let input = JSONMap.int64(usage["input_tokens"] ?? usage["inputTokens"])
        let output = JSONMap.int64(usage["output_tokens"] ?? usage["outputTokens"])
        let cacheRead = JSONMap.int64(
            usage["cache_read_input_tokens"] ?? usage["cacheReadInputTokens"] ?? usage["cache_read_tokens"]
        )
        let cacheCreation = JSONMap.int64(
            usage["cache_creation_input_tokens"] ?? usage["cacheCreationInputTokens"] ?? usage["cache_creation_tokens"]
        )
        guard input != 0 || output != 0 || cacheRead != 0 || cacheCreation != 0 else { return }

        let timestamp = JSONMap.string(object["timestamp"] ?? message["timestamp"])
        if let timestamp, RFC3339.unixSeconds(timestamp) == nil {
            appendUsageDiagnostic(path: path, reason: "invalid_timestamp", to: &diagnostics)
            return
        }
        if timestamp == nil {
            appendUsageDiagnostic(path: path, reason: "missing_timestamp", to: &diagnostics)
            return
        }

        let parsed = ClaudeUsage(
            messageID: messageID,
            model: nonEmptyString(message["model"] ?? object["model"]) ?? "unknown",
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            stopReason: nonEmptyString(object["stop_reason"] ?? message["stop_reason"]),
            timestamp: timestamp,
            sessionID: nonEmptyString(object["sessionId"] ?? object["session_id"] ?? message["sessionId"])
        )
        if SessionUsageParser.shouldReplaceClaude(existing: values[messageID], with: parsed) {
            values[messageID] = parsed
        }
    }

    func entries(now: Int64, path: String?) -> [SessionUsageEntry] {
        _ = now
        return values.values
            .sorted { $0.messageID < $1.messageID }
            .compactMap { value -> SessionUsageEntry? in
                guard let createdAt = RFC3339.unixSeconds(value.timestamp) else { return nil }
                let final = value.stopReason != nil
                return SessionUsageEntry(
                    requestID: "session:\(value.messageID)",
                    appType: "claude",
                    model: value.model,
                    sessionID: value.sessionID,
                    inputTokens: value.inputTokens,
                    outputTokens: value.outputTokens,
                    cacheReadTokens: value.cacheReadTokens,
                    cacheCreationTokens: value.cacheCreationTokens,
                    createdAt: createdAt,
                    dataSource: "session_log",
                    providerID: "_session",
                    providerType: "session_log",
                    inputTokenSemantics: InputTokenSemantics.legacy.rawValue,
                    upsertOnConflict: true,
                    isFinal: final,
                    // A streaming Claude usage record is already billable. Keep
                    // it in the main totals while retaining its incomplete
                    // terminal state for the controlled upsert on the final
                    // duplicate line.
                    accountingStatus: "included",
                    accountingReason: final ? nil : "awaiting_stop_reason",
                    sourcePath: path
                )
            }
    }
}

private struct GrokUsageRecord {
    let key: String
    let promptID: String
    let model: String
    let counters: GrokCounters
    let timestamp: Int64?
}

private struct GrokUsageAccumulator {
    let sessionID: String
    private var values: [String: GrokUsageRecord] = [:]
    private(set) var diagnostics: [SessionScanDiagnostic] = []

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    mutating func consume(_ raw: String, lineNumber: Int64?, path: String?) {
        guard let object = JSONMap.object(from: raw) else {
            if raw.contains("usage") || raw.contains("turn_completed") {
                appendUsageDiagnostic(path: path, reason: "malformed_json", to: &diagnostics)
            }
            return
        }
        let params = JSONMap.object(object["params"])
        let update = JSONMap.object(params?["update"])
        let usage = JSONMap.object(update?["usage"] ?? params?["usage"] ?? object["usage"])
        guard let usage else { return }
        let sessionUpdate = JSONMap.string(update?["sessionUpdate"] ?? object["sessionUpdate"])
        let modelUsage = JSONMap.object(usage["modelUsage"])
        guard sessionUpdate == "turn_completed" || modelUsage != nil else { return }

        let timestamp = parseGrokTimestamp(object["timestamp"] ?? update?["timestamp"])
        guard let timestamp else {
            appendUsageDiagnostic(path: path, reason: "missing_or_invalid_timestamp", to: &diagnostics)
            return
        }
        let promptID = nonEmptyString(
            update?["prompt_id"] ?? update?["promptId"] ?? params?["prompt_id"] ?? object["prompt_id"]
        ) ?? "line-\(lineNumber ?? Int64(values.count + 1))"
        let fallbackModel = nonEmptyString(
            JSONMap.object(object["_meta"])?["modelId"] ?? update?["model"] ?? usage["model"]
        ) ?? "unknown"

        let models: [(String, [String: Any])]
        if let modelUsage {
            models = modelUsage.keys.sorted().compactMap { key in
                guard let value = JSONMap.object(modelUsage[key]) else { return nil }
                return (key, value)
            }
        } else {
            models = [(fallbackModel, usage)]
        }
        for (model, modelObject) in models {
            let counters = GrokCounters(from: modelObject)
            guard !counters.isZero else { continue }
            let key = "\(promptID):\(model)"
            let record = GrokUsageRecord(
                key: key,
                promptID: promptID,
                model: model,
                counters: counters,
                timestamp: timestamp
            )
            if let existing = values[key] {
                let oldTotal = existing.counters.input + existing.counters.output
                    + existing.counters.cached + existing.counters.cacheCreation
                let newTotal = counters.input + counters.output + counters.cached + counters.cacheCreation
                if newTotal >= oldTotal { values[key] = record }
            } else {
                values[key] = record
            }
        }
    }

    func entries(path: String?) -> [SessionUsageEntry] {
        values.values
            .sorted { $0.key < $1.key }
            .compactMap { value -> SessionUsageEntry? in
                guard let createdAt = value.timestamp else { return nil }
                return SessionUsageEntry(
                    requestID: "grok_session:\(sessionID):\(value.promptID):\(value.model)",
                    appType: "grokbuild",
                    model: value.model,
                    sessionID: sessionID,
                    inputTokens: value.counters.input,
                    outputTokens: value.counters.output,
                    cacheReadTokens: value.counters.cached,
                    cacheCreationTokens: value.counters.cacheCreation,
                    createdAt: createdAt,
                    dataSource: "grok_session",
                    providerID: "_grok_session",
                    providerType: "grok_session",
                    inputTokenSemantics: InputTokenSemantics.total.rawValue,
                    upsertOnConflict: true,
                    isFinal: true,
                    accountingStatus: "included",
                    sourcePath: path
                )
            }
    }
}

private struct GeminiUsageRecord {
    let key: String
    let id: String
    let model: String
    let input: Int64
    let output: Int64
    let cached: Int64
    let cacheCreation: Int64
    let timestamp: Int64?
}

private struct GeminiUsageAccumulator {
    private(set) var sessionID: String?
    private var values: [String: GeminiUsageRecord] = [:]
    private(set) var diagnostics: [SessionScanDiagnostic] = []

    mutating func consume(_ raw: String, lineNumber: Int64?, path: String?) {
        guard let object = JSONMap.object(from: raw) else {
            if raw.contains("\"type\"") || raw.contains("\"tokens\"") {
                appendUsageDiagnostic(path: path, reason: "malformed_json", to: &diagnostics)
            }
            return
        }
        consumeObject(object, lineNumber: lineNumber, path: path)
    }

    mutating func consumeObject(_ object: [String: Any], lineNumber: Int64?, path: String?) {
        if let id = nonEmptyString(object["sessionId"] ?? object["session_id"]), sessionID == nil {
            sessionID = id
        }
        if let messages = object["messages"] as? [Any] {
            for message in messages {
                guard let message = JSONMap.object(message) else { continue }
                consumeObject(message, lineNumber: nil, path: path)
            }
        }
        guard JSONMap.string(object["type"]) == "gemini" else { return }
        guard let tokens = JSONMap.object(object["tokens"] ?? object["usage"]) else { return }
        let input = JSONMap.int64(tokens["input"] ?? tokens["inputTokens"] ?? tokens["input_tokens"])
        let output = JSONMap.int64(tokens["output"] ?? tokens["outputTokens"] ?? tokens["output_tokens"])
        let thoughts = JSONMap.int64(tokens["thoughts"] ?? tokens["thoughtTokens"])
        let cached = JSONMap.int64(tokens["cached"] ?? tokens["cachedInputTokens"] ?? tokens["cache_read_input_tokens"])
        let cacheCreation = JSONMap.int64(tokens["cacheCreation"] ?? tokens["cacheCreationTokens"])
        guard input != 0 || output != 0 || thoughts != 0 || cached != 0 || cacheCreation != 0 else { return }
        let timestamp = parseGrokTimestamp(object["timestamp"])
        if timestamp == nil {
            appendUsageDiagnostic(path: path, reason: "missing_or_invalid_timestamp", to: &diagnostics)
        }
        let id = nonEmptyString(object["id"] ?? object["messageId"])
            ?? "line-\(lineNumber ?? Int64(values.count + 1))"
        let record = GeminiUsageRecord(
            key: id,
            id: id,
            model: nonEmptyString(object["model"] ?? object["modelId"]) ?? "unknown",
            input: input,
            output: output + thoughts,
            cached: cached,
            cacheCreation: cacheCreation,
            timestamp: timestamp
        )
        if let existing = values[id] {
            let oldTotal = existing.input + existing.output + existing.cached + existing.cacheCreation
            let newTotal = input + output + thoughts + cached + cacheCreation
            if newTotal >= oldTotal { values[id] = record }
        } else {
            values[id] = record
        }
    }

    func entries(path: String?) -> [SessionUsageEntry] {
        values.values
            .sorted { $0.key < $1.key }
            .compactMap { value -> SessionUsageEntry? in
                guard let createdAt = value.timestamp else { return nil }
                let session = sessionID ?? "unknown"
                return SessionUsageEntry(
                    requestID: "gemini_session:\(session):\(value.id)",
                    appType: "gemini",
                    model: value.model,
                    sessionID: sessionID,
                    inputTokens: value.input,
                    outputTokens: value.output,
                    cacheReadTokens: value.cached,
                    cacheCreationTokens: value.cacheCreation,
                    createdAt: createdAt,
                    dataSource: "gemini_session",
                    providerID: "_gemini_session",
                    providerType: "gemini_session",
                    inputTokenSemantics: InputTokenSemantics.total.rawValue,
                    upsertOnConflict: true,
                    isFinal: true,
                    accountingStatus: "included",
                    sourcePath: path
                )
            }
    }
}

private struct CodexUsageAccumulator {
    private(set) var parsed: ParsedCodexFile
    private var currentModel = "unknown"
    private var totalHighWater: CodexCumulative?
    private var lastSignatureBySource: [String?: CodexTokenSignature] = [:]
    private var previousSignature: CodexTokenSignature?
    private var eventIndex: UInt32 = 0
    private(set) var diagnostics: [SessionScanDiagnostic] = []
    private let path: String?

    init(fileName: String, path: String?) {
        self.parsed = ParsedCodexFile(rootThreadID: SessionUsageParser.threadIDFromFilename(fileName))
        self.path = path
    }

    mutating func consume(_ raw: String, lineNumber: Int64) {
        parsed.lineOffset = lineNumber
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        guard let object = JSONMap.object(from: raw),
              let eventType = JSONMap.string(object["type"]) else {
            if raw.contains("session_meta") || raw.contains("token_count") {
                appendUsageDiagnostic(path: path, reason: "malformed_json", to: &diagnostics)
            }
            return
        }
        switch eventType {
        case "session_meta" where !parsed.rootMetaSeen:
            let payload = JSONMap.object(object["payload"]) ?? [:]
            if let filenameID = parsed.rootThreadID,
               let metaID = nonEmptyString(
                payload["id"] ?? payload["thread_id"] ?? payload["threadId"]
                    ?? object["id"] ?? object["thread_id"] ?? object["threadId"]
               ),
               filenameID != metaID.lowercased() {
                // A copied ancestor can precede the real root metadata. Keep
                // scanning so the matching root can establish the relation.
                appendUsageDiagnostic(path: path, reason: "thread_id_mismatch", to: &diagnostics)
                return
            }
            parsed.rootMetaSeen = true
            parsed.rootTimestamp = RFC3339.unixSeconds(JSONMap.string(object["timestamp"]))
            let parentValues = parentThreadIDs(from: object, payload: payload)
            parsed.parentThreadIDConflict = parentValues.count > 1
            parsed.parentThreadID = parentValues.count == 1 ? parentValues[0] : nil
            if parsed.parentThreadID == parsed.rootThreadID {
                parsed.parentThreadID = nil
                parsed.parentThreadIDConflict = true
            }
        case "turn_context":
            if let payload = JSONMap.object(object["payload"]),
               let model = JSONMap.string(payload["model"] ?? JSONMap.object(payload["info"])?["model"]) {
                currentModel = model
            }
        case "event_msg":
            guard let payload = JSONMap.object(object["payload"]),
                  JSONMap.string(payload["type"]) == "token_count",
                  let info = JSONMap.object(payload["info"]),
                  let signature = parseCodexSignature(info) else { return }
            if let model = JSONMap.string(info["model"] ?? info["model_name"] ?? payload["model"]) {
                currentModel = model
            }
            guard let timestamp = JSONMap.string(object["timestamp"]),
                  RFC3339.unixSeconds(timestamp) != nil else {
                appendUsageDiagnostic(path: path, reason: "missing_or_invalid_timestamp", to: &diagnostics)
                return
            }
            let source = JSONMap.string(JSONMap.object(payload["rate_limits"])?["limit_id"])
            let total = parseCodexCumulative(info["total_token_usage"])
            let last = parseCodexCumulative(info["last_token_usage"])
            guard total != nil || last != nil else { return }
            let hasTotalSnapshot = total != nil
            let duplicate = hasTotalSnapshot
                && (lastSignatureBySource[source] == signature || previousSignature == signature)
            if hasTotalSnapshot { lastSignatureBySource[source] = signature }
            previousSignature = signature

            var delta: CodexCumulative
            if duplicate {
                delta = CodexCumulative(input: 0, cachedInput: 0, output: 0)
            } else if let last {
                delta = last
            } else if let total {
                delta = computeCodexDelta(previous: totalHighWater, current: total)
            } else {
                return
            }
            if let total {
                if var highWater = totalHighWater {
                    highWater.input = max(highWater.input, total.input)
                    highWater.cachedInput = max(highWater.cachedInput, total.cachedInput)
                    highWater.output = max(highWater.output, total.output)
                    totalHighWater = highWater
                } else {
                    totalHighWater = total
                }
            }
            delta.cachedInput = min(delta.cachedInput, delta.input)
            let index: UInt32?
            if delta.input == 0 && delta.cachedInput == 0 && delta.output == 0 {
                index = nil
            } else {
                parsed.hasBillableTokens = true
                eventIndex &+= 1
                index = eventIndex
            }
            parsed.events.append(
                ParsedCodexEvent(
                    lineOffset: lineNumber,
                    signature: signature,
                    input: delta.input,
                    cachedInput: delta.cachedInput,
                    output: delta.output,
                    eventIndex: index,
                    model: currentModel,
                    timestamp: timestamp
                )
            )
        default:
            return
        }
    }
}

enum SessionUsageScanner {
    private struct FileMetadata {
        let modified: Int64
        let identity: String
        let size: Int64
        let tailFingerprint: String
    }

    private struct StreamResult {
        let totalBytes: Int64
        let completeByteOffset: Int64
        let lineCount: Int64
        let tailFingerprint: String
        let hasPartialTail: Bool
        let invalidUTF8LineCount: Int64
    }

    static func scan(
        roots: SessionLogRoots,
        fileManager: FileManager = .default,
        existingCursors: [String: SessionFileCursor] = [:],
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> SessionScanResult {
        var result = SessionScanResult()
        // Files discovered below /var may be reported as /private/var (or
        // vice versa) depending on the caller and filesystem API. Normalize
        // persisted cursor keys before matching so an alias cannot force a
        // needless full rescan or hide a pending-child recheck.
        var canonicalCursors: [String: SessionFileCursor] = [:]
        for (path, cursor) in existingCursors {
            let canonicalPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if canonicalPath == path {
                canonicalCursors[canonicalPath] = cursor
            } else if canonicalCursors[canonicalPath] == nil {
                canonicalCursors[canonicalPath] = cursor
            }
        }
        for root in [roots.claudeProjects, roots.codexHome, roots.grokHome, roots.geminiHome]
            where fileManager.fileExists(atPath: root.path) {
            if (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            )) == nil {
                result.diagnostics.append(
                    SessionScanDiagnostic(path: root.path, reason: "directory_read_failed")
                )
            }
        }
        let files = SessionLogDiscovery.collect(roots: roots, fileManager: fileManager)
            .map { SessionLogFile(url: $0.url.resolvingSymlinksInPath(), kind: $0.kind) }
            .sorted { $0.url.path < $1.url.path }
        var changedCodex: [SessionLogFile] = []
        var allCodex: [SessionLogFile] = []

        for file in files {
            guard let metadata = metadata(for: file.url, fileManager: fileManager) else {
                result.diagnostics.append(
                    SessionScanDiagnostic(path: file.url.path, reason: "stat_failed")
                )
                continue
            }
            switch file.kind {
            case .codex:
                allCodex.append(file)
                if shouldScan(cursor: canonicalCursors[file.url.path], metadata: metadata) {
                    changedCodex.append(file)
                }
            default:
                appendParsedFile(
                    file,
                    metadata: metadata,
                    fileManager: fileManager,
                    existingCursors: canonicalCursors,
                    now: now,
                    into: &result
                )
            }
        }

        result.entries.append(contentsOf: scanCodex(
            changed: changedCodex,
            all: allCodex,
            fileManager: fileManager,
            existingCursors: canonicalCursors,
            now: now,
            fileStates: &result.fileStates,
            diagnostics: &result.diagnostics
        ))
        result.diagnostics = result.diagnostics.reduce(into: [SessionScanDiagnostic]()) { unique, diagnostic in
            if !unique.contains(diagnostic) { unique.append(diagnostic) }
        }.sorted {
            if $0.path == $1.path { return $0.reason < $1.reason }
            return $0.path < $1.path
        }
        return result
    }

    private static func appendParsedFile(
        _ file: SessionLogFile,
        metadata: FileMetadata,
        fileManager: FileManager,
        existingCursors: [String: SessionFileCursor],
        now: Int64,
        into result: inout SessionScanResult
    ) {
        guard shouldScan(cursor: existingCursors[file.url.path], metadata: metadata) else { return }
        let sourcePath = file.url.resolvingSymlinksInPath().path

        var claude: ClaudeUsageAccumulator?
        var grok: GrokUsageAccumulator?
        var gemini: GeminiUsageAccumulator?
        switch file.kind {
        case .claude:
            claude = ClaudeUsageAccumulator()
        case .grok:
            grok = GrokUsageAccumulator(
                sessionID: file.url.deletingLastPathComponent().lastPathComponent
            )
        case .gemini:
            gemini = GeminiUsageAccumulator()
        case .codex:
            return
        }

        guard let stream = streamLines(file.url, fileManager: fileManager, consume: { line, number in
            switch file.kind {
            case .claude:
                claude?.consume(line, lineNumber: number, path: sourcePath)
            case .grok:
                grok?.consume(line, lineNumber: number, path: sourcePath)
            case .gemini:
                gemini?.consume(line, lineNumber: number, path: sourcePath)
            case .codex:
                break
            }
        }) else {
            result.diagnostics.append(
                SessionScanDiagnostic(path: file.url.path, reason: "read_failed")
            )
            return
        }

        if stream.hasPartialTail {
            result.diagnostics.append(
                SessionScanDiagnostic(path: file.url.path, reason: "incomplete_final_line")
            )
        }
        if stream.invalidUTF8LineCount > 0 {
            result.diagnostics.append(
                SessionScanDiagnostic(path: file.url.path, reason: "invalid_utf8")
            )
        }
        if let claude {
            result.entries.append(contentsOf: claude.entries(now: now, path: sourcePath))
            result.diagnostics.append(contentsOf: claude.diagnostics)
        }
        if let grok {
            result.entries.append(contentsOf: grok.entries(path: sourcePath))
            result.diagnostics.append(contentsOf: grok.diagnostics)
        }
        if let gemini {
            result.entries.append(contentsOf: gemini.entries(path: sourcePath))
            result.diagnostics.append(contentsOf: gemini.diagnostics)
        }
        result.fileStates.append(
            SessionFileCursor(
                path: file.url.path,
                lastModified: metadata.modified,
                lastLineOffset: stream.lineCount,
                fileIdentity: metadata.identity,
                fileSize: metadata.size,
                completeByteOffset: stream.completeByteOffset,
                tailFingerprint: metadata.tailFingerprint
            )
        )
    }

    private static func scanCodex(
        changed: [SessionLogFile],
        all: [SessionLogFile],
        fileManager: FileManager,
        existingCursors: [String: SessionFileCursor],
        now: Int64,
        fileStates: inout [SessionFileCursor],
        diagnostics: inout [SessionScanDiagnostic]
    ) -> [SessionUsageEntry] {
        guard !changed.isEmpty else { return [] }

        var parsedByPath: [String: ParsedCodexFile] = [:]
        var changedThreadIDs = Set<String>()
        for file in changed.sorted(by: { $0.url.path < $1.url.path }) {
            if let parsed = parseCodexFile(
                file,
                fileManager: fileManager,
                fileStates: &fileStates,
                diagnostics: &diagnostics
            ) {
                parsedByPath[file.url.path] = parsed
                if let threadID = parsed.rootThreadID { changedThreadIDs.insert(threadID) }
            }
        }

        // A parent can be created or appended after its child was already
        // cursor-complete. Read only each unchanged file's session metadata to
        // locate children whose relationship must be re-evaluated; parse those
        // complete files fully, rather than rescanning every large rollout.
        if !changedThreadIDs.isEmpty {
            for file in all.sorted(by: { $0.url.path < $1.url.path })
                where parsedByPath[file.url.path] == nil && existingCursors[file.url.path] != nil {
                guard let metadata = readCodexMetadata(file, fileManager: fileManager),
                      let parentID = metadata.parentThreadID,
                      changedThreadIDs.contains(parentID) else { continue }
                if let parsed = parseCodexFile(
                    file,
                    fileManager: fileManager,
                    fileStates: &fileStates,
                    diagnostics: &diagnostics
                ) {
                    parsedByPath[file.url.path] = parsed
                }
            }
        }

        var filesByThread: [String: [SessionLogFile]] = [:]
        for file in all {
            if let threadID = SessionUsageParser.threadIDFromFilename(file.url.lastPathComponent) {
                filesByThread[threadID, default: []].append(file)
            }
        }
        for key in filesByThread.keys {
            filesByThread[key]?.sort { $0.url.path < $1.url.path }
        }

        var parentCache: [String: ParsedCodexFile] = parsedByPath
        var entries: [SessionUsageEntry] = []
        for file in parsedByPath.keys.sorted() {
            guard let parsed = parsedByPath[file] else { continue }
            guard parsed.hasBillableTokens, let threadID = parsed.rootThreadID else {
                if parsed.hasBillableTokens {
                    diagnostics.append(
                        SessionScanDiagnostic(path: file, reason: "missing_thread_id")
                    )
                }
                continue
            }

            var replayPrefix = 0
            var status = "included"
            var reason: String?
            if !parsed.rootMetaSeen {
                status = "pending"
                reason = "missing_session_meta"
            } else if parsed.parentThreadIDConflict {
                status = "pending"
                reason = "parent_conflict"
            } else if let parentID = parsed.parentThreadID {
                let cutoff = parsed.rootTimestamp ?? Int64.max
                if let parent = loadParent(
                    parentID,
                    cutoff: cutoff,
                    filesByThread: filesByThread,
                    cache: &parentCache,
                    fileManager: fileManager
                ) {
                    let parentEvents = parent.events.compactMap { event -> ParsedCodexEvent? in
                        guard let timestamp = RFC3339.unixSeconds(event.timestamp), timestamp <= cutoff else {
                            return nil
                        }
                        return event
                    }
                    replayPrefix = matchingReplayPrefixWithEvidence(
                        child: parsed.events,
                        parent: parentEvents
                    )
                } else {
                    status = "pending"
                    reason = "parent_unresolved"
                }
            }

            for event in parsed.events {
                guard let eventIndex = event.eventIndex,
                      let createdAt = RFC3339.unixSeconds(event.timestamp) else {
                    continue
                }
                let isDuplicate = replayPrefix > 0 && Int(eventIndex) <= replayPrefix
                entries.append(
                    SessionUsageEntry(
                        requestID: codexRequestID(
                            threadID: threadID,
                            eventIndex: eventIndex
                        ),
                        appType: "codex",
                        model: event.model,
                        sessionID: threadID,
                        inputTokens: event.input,
                        outputTokens: event.output,
                        cacheReadTokens: event.cachedInput,
                        cacheCreationTokens: 0,
                        createdAt: createdAt,
                        dataSource: "codex_session",
                        providerID: "_codex_session",
                        providerType: "codex_session",
                        inputTokenSemantics: InputTokenSemantics.legacy.rawValue,
                        // Full-file reparsing must reconcile historical status
                        // and source metadata after a parent becomes available.
                        upsertOnConflict: true,
                        isFinal: true,
                        accountingStatus: isDuplicate ? "duplicate" : status,
                        accountingReason: isDuplicate ? "replay_of_parent" : reason,
                        sourcePath: URL(fileURLWithPath: file).resolvingSymlinksInPath().path
                    )
                )
            }
        }
        return entries
    }

    private static func parseCodexFile(
        _ file: SessionLogFile,
        fileManager: FileManager,
        fileStates: inout [SessionFileCursor],
        diagnostics: inout [SessionScanDiagnostic]
    ) -> ParsedCodexFile? {
        guard let metadata = metadata(for: file.url, fileManager: fileManager) else {
            diagnostics.append(SessionScanDiagnostic(path: file.url.path, reason: "stat_failed"))
            return nil
        }
        var accumulator = CodexUsageAccumulator(
            fileName: file.url.lastPathComponent,
            path: file.url.resolvingSymlinksInPath().path
        )
        guard let stream = streamLines(file.url, fileManager: fileManager, consume: { line, number in
            accumulator.consume(line, lineNumber: number)
        }) else {
            diagnostics.append(SessionScanDiagnostic(path: file.url.path, reason: "read_failed"))
            return nil
        }
        if stream.hasPartialTail {
            diagnostics.append(SessionScanDiagnostic(path: file.url.path, reason: "incomplete_final_line"))
        }
        if stream.invalidUTF8LineCount > 0 {
            diagnostics.append(SessionScanDiagnostic(path: file.url.path, reason: "invalid_utf8"))
        }
        diagnostics.append(contentsOf: accumulator.diagnostics)
        fileStates.append(
            SessionFileCursor(
                path: file.url.path,
                lastModified: metadata.modified,
                lastLineOffset: stream.lineCount,
                fileIdentity: metadata.identity,
                fileSize: metadata.size,
                completeByteOffset: stream.completeByteOffset,
                tailFingerprint: metadata.tailFingerprint
            )
        )
        return accumulator.parsed
    }

    private struct CodexMetadata {
        let parentThreadID: String?
    }

    private static func readCodexMetadata(
        _ file: SessionLogFile,
        fileManager: FileManager
    ) -> CodexMetadata? {
        guard fileManager.fileExists(atPath: file.url.path),
              let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        var buffer = Data()
        do {
            while buffer.count < 1_048_576,
                  let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    let next = buffer.index(after: newline)
                    buffer.removeSubrange(buffer.startIndex..<next)
                    if let metadata = codexMetadata(
                        from: line,
                        fileName: file.url.lastPathComponent
                    ) {
                        try handle.close()
                        return metadata
                    }
                }
            }
            if let metadata = codexMetadata(
                from: buffer,
                fileName: file.url.lastPathComponent
            ) {
                try handle.close()
                return metadata
            }
            try handle.close()
        } catch {
            try? handle.close()
        }
        return nil
    }

    private static func codexMetadata(from data: Data, fileName: String) -> CodexMetadata? {
        guard !data.isEmpty,
              let object = JSONMap.object(from: String(decoding: data, as: UTF8.self)),
              JSONMap.string(object["type"]) == "session_meta" else { return nil }
        let payload = JSONMap.object(object["payload"]) ?? [:]
        if let filenameID = SessionUsageParser.threadIDFromFilename(fileName),
           let metaID = nonEmptyString(
            payload["id"] ?? payload["thread_id"] ?? payload["threadId"]
                ?? object["id"] ?? object["thread_id"] ?? object["threadId"]
           ),
           filenameID != metaID.lowercased() {
            return nil
        }
        let values = parentThreadIDs(from: object, payload: payload)
        return CodexMetadata(parentThreadID: values.count == 1 ? values[0] : nil)
    }

    private static func loadParent(
        _ parentID: String,
        cutoff: Int64,
        filesByThread: [String: [SessionLogFile]],
        cache: inout [String: ParsedCodexFile],
        fileManager: FileManager
    ) -> ParsedCodexFile? {
        guard let candidates = filesByThread[parentID], !candidates.isEmpty else { return nil }
        var fallback: ParsedCodexFile?
        for parentFile in candidates.sorted(by: { $0.url.path < $1.url.path }) {
            if let cached = cache[parentFile.url.path] {
                if let timestamp = cached.rootTimestamp, timestamp <= cutoff { return cached }
                fallback = fallback ?? cached
                continue
            }
            var accumulator = CodexUsageAccumulator(
                fileName: parentFile.url.lastPathComponent,
                path: parentFile.url.path
            )
            guard streamLines(parentFile.url, fileManager: fileManager, consume: { line, number in
                accumulator.consume(line, lineNumber: number)
            }) != nil else { continue }
            let parsed = accumulator.parsed
            cache[parentFile.url.path] = parsed
            if let timestamp = parsed.rootTimestamp, timestamp <= cutoff { return parsed }
            fallback = fallback ?? parsed
        }
        return fallback
    }

    private static func shouldScan(
        cursor: SessionFileCursor?,
        metadata: FileMetadata
    ) -> Bool {
        guard let cursor else { return true }
        // Cursors from schema v1 had no identity/size. Reparse them once so all
        // historical lines can be repaired and receive stable IDs.
        if cursor.fileSize == 0 {
            if metadata.size == 0,
               !cursor.fileIdentity.isEmpty,
               cursor.fileIdentity == metadata.identity,
               metadata.modified <= cursor.lastModified {
                return false
            }
            return true
        }
        if cursor.completeByteOffset <= 0 { return true }
        if !cursor.fileIdentity.isEmpty && !metadata.identity.isEmpty,
           cursor.fileIdentity != metadata.identity { return true }
        if cursor.fileSize != metadata.size { return true }
        if cursor.completeByteOffset < metadata.size { return true }
        if cursor.tailFingerprint != metadata.tailFingerprint { return true }
        return metadata.modified > cursor.lastModified
    }

    private static func streamLines(
        _ url: URL,
        fileManager: FileManager,
        consume: (String, Int64) -> Void
    ) -> StreamResult? {
        guard fileManager.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        var buffer = Data()
        var totalBytes: Int64 = 0
        var completeByteOffset: Int64 = 0
        var lineCount: Int64 = 0
        var invalidUTF8LineCount: Int64 = 0
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                totalBytes += Int64(chunk.count)
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    var line = Data(buffer[..<newline])
                    if line.last == 13 { line.removeLast() }
                    completeByteOffset += Int64(newline - buffer.startIndex + 1)
                    lineCount += 1
                    if let text = String(data: line, encoding: .utf8) {
                        consume(text, lineCount)
                    } else {
                        invalidUTF8LineCount += 1
                    }
                    let next = buffer.index(after: newline)
                    buffer.removeSubrange(buffer.startIndex..<next)
                }
            }
            // JSONL writers often leave the final object without a newline.
            // A syntactically complete object is safe to consume; only an
            // invalid/truncated tail remains pending for the next scan.
            if !buffer.isEmpty,
               let text = String(data: buffer, encoding: .utf8),
               JSONMap.object(from: text) != nil {
                lineCount += 1
                completeByteOffset = totalBytes
                consume(text, lineCount)
                buffer.removeAll(keepingCapacity: false)
            }
            try handle.close()
        } catch {
            try? handle.close()
            return nil
        }
        let tailFingerprint = fingerprint(buffer)
        return StreamResult(
            totalBytes: totalBytes,
            completeByteOffset: completeByteOffset,
            lineCount: lineCount,
            tailFingerprint: tailFingerprint,
            hasPartialTail: !buffer.isEmpty,
            invalidUTF8LineCount: invalidUTF8LineCount
        )
    }

    private static func metadata(for url: URL, fileManager: FileManager) -> FileMetadata? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let sizeNumber = attributes[.size] as? NSNumber else { return nil }
        let size = sizeNumber.int64Value
        let modified: Int64
        if let date = attributes[.modificationDate] as? Date {
            let nanos = date.timeIntervalSince1970 * 1_000_000_000
            modified = nanos <= 0 ? 0 : (nanos >= Double(Int64.max) ? Int64.max : Int64(nanos))
        } else {
            modified = 0
        }
        let identity = (attributes[.systemFileNumber] as? NSNumber).map {
            "inode:\($0.int64Value)"
        } ?? ""
        var fingerprintSample = Data()
        if size > 0, let handle = try? FileHandle(forReadingFrom: url) {
            do {
                fingerprintSample = try handle.read(upToCount: 4096) ?? Data()
                try handle.seek(toOffset: UInt64(max(0, size - 4096)))
                fingerprintSample.append(try handle.readToEnd() ?? Data())
                try handle.close()
            } catch {
                try? handle.close()
            }
        }
        return FileMetadata(
            modified: modified,
            identity: identity,
            size: size,
            tailFingerprint: fingerprint(fingerprintSample)
        )
    }

    private static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private func codexRequestID(
    threadID: String,
    eventIndex: UInt32
) -> String {
    return "codex_session:thread-v1:\(threadID):\(eventIndex)"
}

private func matchingReplayPrefixWithEvidence(
    child: [ParsedCodexEvent],
    parent: [ParsedCodexEvent]
) -> Int {
    let billableChild = child.filter { $0.eventIndex != nil }
    let billableParent = parent.filter { $0.eventIndex != nil }
    var matched = 0
    for (childEvent, parentEvent) in zip(billableChild, billableParent) {
        let event = childEvent
        guard let childTimestamp = RFC3339.unixSeconds(event.timestamp) else { break }
        guard parentEvent.signature == event.signature,
              let parentTimestamp = RFC3339.unixSeconds(parentEvent.timestamp) else { break }
        // A signature alone is not proof: independent calls can have equal
        // counters. Only exact event timestamps constitute replay evidence.
        guard parentTimestamp == childTimestamp else { break }
        matched += 1
    }
    return matched
}

private enum JSONMap {
    static func object(from json: Substring) -> [String: Any]? {
        object(from: String(json))
    }

    static func object(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func int64(_ value: Any?) -> Int64 {
        jsonInt64IfPresent(value) ?? 0
    }
}

private func jsonInt64IfPresent(_ value: Any?) -> Int64? {
    switch value {
    case nil, is NSNull:
        return nil
    case let number as NSNumber:
        return number.int64Value
    case let number as Int:
        return Int64(number)
    case let number as Int64:
        return number
    case let text as String:
        return Int64(text)
    default:
        return nil
    }
}

private enum RFC3339 {
    static func unixSeconds(_ string: String?) -> Int64? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) {
            return Int64(date.timeIntervalSince1970)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string).map { Int64($0.timeIntervalSince1970) }
    }
}

private func parseGrokTimestamp(_ value: Any?) -> Int64? {
    if let number = jsonInt64IfPresent(value) {
        return number > 100_000_000_000 ? number / 1000 : number
    }
    return RFC3339.unixSeconds(JSONMap.string(value))
}

private func parseCodexSignature(_ info: [String: Any]) -> CodexTokenSignature? {
    let total = parseCodexCounterSignature(JSONMap.object(info["total_token_usage"]))
    let last = parseCodexCounterSignature(JSONMap.object(info["last_token_usage"]))
    if total == nil && last == nil { return nil }
    return CodexTokenSignature(total: total, last: last)
}

private func parseCodexCounterSignature(_ object: [String: Any]?) -> CodexCounterSignature? {
    guard let object else { return nil }
    return CodexCounterSignature(
        input: jsonInt64IfPresent(object["input_tokens"]),
        cachedInput: jsonInt64IfPresent(object["cached_input_tokens"])
            ?? jsonInt64IfPresent(object["cache_read_input_tokens"]),
        output: jsonInt64IfPresent(object["output_tokens"]),
        reasoningOutput: jsonInt64IfPresent(object["reasoning_output_tokens"]),
        total: jsonInt64IfPresent(object["total_tokens"])
    )
}

private func parseCodexCumulative(_ value: Any?) -> CodexCumulative? {
    guard let object = JSONMap.object(value) else { return nil }
    let keys = [
        "input_tokens",
        "cached_input_tokens",
        "cache_read_input_tokens",
        "output_tokens",
        "reasoning_output_tokens",
        "total_tokens"
    ]
    guard keys.contains(where: { object[$0] != nil }) else { return nil }
    return CodexCumulative(
        input: JSONMap.int64(object["input_tokens"]),
        cachedInput: JSONMap.int64(object["cached_input_tokens"] ?? object["cache_read_input_tokens"]),
        output: JSONMap.int64(object["output_tokens"])
    )
}

private func computeCodexDelta(
    previous: CodexCumulative?,
    current: CodexCumulative
) -> CodexCumulative {
    guard let previous else { return current }
    return CodexCumulative(
        input: max(0, current.input - previous.input),
        cachedInput: max(0, current.cachedInput - previous.cachedInput),
        output: max(0, current.output - previous.output)
    )
}

private func parentThreadIDs(from payload: [String: Any]) -> [String] {
    let nested = JSONMap.object(
        JSONMap.object(JSONMap.object(payload["source"])?["subagent"])?["thread_spawn"]
    )
    let values = [
        nonEmptyString(payload["forked_from_id"]),
        nonEmptyString(payload["parent_thread_id"]),
        nonEmptyString(payload["parentThreadId"]),
        nonEmptyString(nested?["parent_thread_id"])
    ].compactMap { value -> String? in
        guard let value else { return nil }
        return UUID(uuidString: value)?.uuidString.lowercased() ?? value.lowercased()
    }
    return Array(Set(values)).sorted()
}

private func parentThreadIDs(
    from object: [String: Any],
    payload: [String: Any]
) -> [String] {
    Array(Set(parentThreadIDs(from: payload) + parentThreadIDs(from: object))).sorted()
}

private func parentThreadID(from payload: [String: Any]) -> String? {
    let values = parentThreadIDs(from: payload)
    return values.count == 1 ? values[0] : nil
}

private func nonEmptyString(_ value: Any?) -> String? {
    guard let text = JSONMap.string(value), !text.isEmpty else { return nil }
    return text
}
