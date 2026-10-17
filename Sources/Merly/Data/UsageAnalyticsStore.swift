import Foundation
import CoreFoundation

final class UsageAnalyticsStore: @unchecked Sendable {
    // All mutable cache state and date formatters are confined to UsageEngine.analytics.
    private struct Signature: Equatable {
        var modificationDate: Date
        var size: UInt64
    }

    private struct ParsedFile {
        var records: [UsageActivityRecord] = []
        var warnings: [String] = []
        var usedLegacyCodexRecords = false
    }

    private struct CachedFile {
        var signature: Signature
        var parsed: ParsedFile
    }

    private struct LogFile {
        var url: URL
        var path: String
        var signature: Signature
    }

    private struct ScanResult {
        var files: [LogFile] = []
        var warnings: [String] = []
    }

    private struct StreamResult {
        var hadOversizedLine = false
    }

    private struct ClaudeMetadata {
        var sessionID: String
        var agentID: String?
        var agentName: String?
        var project: String?
        var model: String?
    }

    private struct CodexCounters: Equatable {
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
        var reasoningOutput: Int
        var reportedTotal: Int?

        var vector: [Int] {
            [input, output, cacheRead, cacheWrite, reasoningOutput]
        }

        func delta(from previous: Self) -> Self? {
            guard input >= previous.input,
                  output >= previous.output,
                  cacheRead >= previous.cacheRead,
                  cacheWrite >= previous.cacheWrite,
                  reasoningOutput >= previous.reasoningOutput
            else { return nil }

            let totalDelta: Int?
            if let current = reportedTotal, let old = previous.reportedTotal {
                guard current >= old else { return nil }
                totalDelta = current - old
            } else {
                totalDelta = nil
            }

            return Self(
                input: input - previous.input,
                output: output - previous.output,
                cacheRead: cacheRead - previous.cacheRead,
                cacheWrite: cacheWrite - previous.cacheWrite,
                reasoningOutput: reasoningOutput - previous.reasoningOutput,
                reportedTotal: totalDelta
            )
        }
    }

    private struct CodexMetadata {
        var id: String
        var parentSessionID: String?
        var role: String?
        var nickname: String?
        var project: String?
        var isChild: Bool
    }

    private struct CodexContext {
        var turnID: String?
        var model: String?
    }

    private struct CodexModernUsage {
        var timestamp: Date?
        var responseID: String?
        var threadID: String?
        var sessionID: String?
        var turnID: String?
        var counters: CodexCounters?
        var lineIndex: Int
    }

    private struct CodexLegacyUsage {
        var timestamp: Date?
        var turnID: String?
        var total: CodexCounters?
        var last: CodexCounters?
    }

    private enum CodexEvent {
        case metadata(CodexMetadata)
        case context(CodexContext)
        case modern(CodexModernUsage)
        case legacy(CodexLegacyUsage)
    }

    private let fileManager = FileManager.default
    private lazy var fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private lazy var standardISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private var cache: [HistoryIdentity: [String: CachedFile]] = [:]

    init() {}

    func read(config: ProviderConfig, now: Date) -> ProviderUsageReport {
        let identity = HistoryIdentity(config: config)
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let scan = scanFiles(config: config, cutoff: cutoff)
        var warnings: [String] = []
        var warningSet: Set<String> = []
        for warning in scan.warnings { append(warning, to: &warnings, seen: &warningSet) }

        let presentPaths = Set(scan.files.map(\.path))
        var identityCache = (cache[identity] ?? [:]).filter { presentPaths.contains($0.key) }
        var collected: [UsageActivityRecord] = []
        var usedLegacyCodexRecords = false

        for file in scan.files {
            if let cached = identityCache[file.path], cached.signature == file.signature {
                collected.append(contentsOf: cached.parsed.records)
                for warning in cached.parsed.warnings {
                    append(warning, to: &warnings, seen: &warningSet)
                }
                usedLegacyCodexRecords = usedLegacyCodexRecords || cached.parsed.usedLegacyCodexRecords
                continue
            }

            do {
                let parsed = try parse(file: file, kind: config.kind, now: now)
                identityCache[file.path] = CachedFile(signature: file.signature, parsed: parsed)
                collected.append(contentsOf: parsed.records)
                for warning in parsed.warnings {
                    append(warning, to: &warnings, seen: &warningSet)
                }
                usedLegacyCodexRecords = usedLegacyCodexRecords || parsed.usedLegacyCodexRecords
            } catch {
                append(Self.unreadableLogsWarning, to: &warnings, seen: &warningSet)
            }
        }

        cache[identity] = identityCache
        var records = deduplicated(collected)
        records.removeAll { $0.timestamp < cutoff || $0.timestamp > now }
        records.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }

        if scan.files.isEmpty {
            append(Self.noLogsWarning, to: &warnings, seen: &warningSet)
        } else if !records.contains(where: { $0.tokens.total > 0 }) {
            append(Self.noTokenUsageWarning, to: &warnings, seen: &warningSet)
        }
        if usedLegacyCodexRecords {
            append(Self.legacyCodexWarning, to: &warnings, seen: &warningSet)
        }
        if records.contains(where: { $0.tokens.total > 0 && $0.model == "Unknown model" }) {
            append(Self.unknownModelWarning, to: &warnings, seen: &warningSet)
        }

        return ProviderUsageReport(
            identity: identity,
            loadedAt: now,
            records: records,
            warnings: warnings
        )
    }

    private static let noLogsWarning = "No local session logs found for this provider."
    private static let noTokenUsageWarning = "No token usage was found in the local logs."
    private static let unreadableLogsWarning = "Some local logs could not be read. Totals may be incomplete."
    private static let malformedUsageWarning = "Some local usage records could not be decoded. Totals may be incomplete."
    private static let unknownModelWarning = "Some local usage does not identify a model."
    private static let legacyCodexWarning = "Older Codex logs use cumulative usage; model and session attribution may be incomplete."
    private static let unidentifiedCodexFallbackWarning = "Some older Codex usage has no response identity and may be incomplete."
    private static let maxLineBytes = 8 * 1024 * 1024
    private static let chunkBytes = 64 * 1024
    private static let maxSafeCounter = Int.max / 16

    private func scanFiles(config: ProviderConfig, cutoff: Date) -> ScanResult {
        let configRoot = URL(fileURLWithPath: config.expandedDir, isDirectory: true)
            .standardizedFileURL
        let roots: [URL]
        switch config.kind {
        case .claude:
            roots = [configRoot.appendingPathComponent("projects", isDirectory: true)]
        case .codex:
            roots = [
                configRoot.appendingPathComponent("sessions", isDirectory: true),
                configRoot.appendingPathComponent("archived_sessions", isDirectory: true)
            ]
        case .kimi:
            roots = [configRoot.appendingPathComponent("sessions", isDirectory: true)]
        }

        var result = ScanResult()
        var filesByPath: [String: LogFile] = [:]
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileSizeKey
        ]

        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            do {
                let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { continue }
                guard values.isDirectory == true else {
                    append(Self.unreadableLogsWarning, to: &result.warnings)
                    continue
                }
            } catch {
                append(Self.unreadableLogsWarning, to: &result.warnings)
                continue
            }

            var enumerationFailed = false
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return true
                }
            ) else {
                append(Self.unreadableLogsWarning, to: &result.warnings)
                continue
            }

            for case let url as URL in enumerator {
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    if values.isSymbolicLink == true || values.isDirectory == true { continue }
                    guard values.isRegularFile == true, matchesLogFile(url, kind: config.kind) else { continue }
                    guard let modificationDate = values.contentModificationDate,
                          let fileSize = values.fileSize,
                          fileSize >= 0
                    else {
                        append(Self.unreadableLogsWarning, to: &result.warnings)
                        continue
                    }
                    guard modificationDate >= cutoff else { continue }
                    let path = url.standardizedFileURL.path
                    filesByPath[path] = LogFile(
                        url: url,
                        path: path,
                        signature: Signature(modificationDate: modificationDate, size: UInt64(fileSize))
                    )
                } catch {
                    append(Self.unreadableLogsWarning, to: &result.warnings)
                }
            }
            if enumerationFailed { append(Self.unreadableLogsWarning, to: &result.warnings) }
        }

        result.files = filesByPath.values.sorted { $0.path < $1.path }
        return result
    }

    private func matchesLogFile(_ url: URL, kind: ProviderKind) -> Bool {
        switch kind {
        case .claude, .codex:
            return url.pathExtension == "jsonl"
        case .kimi:
            return url.lastPathComponent == "wire.jsonl"
        }
    }

    private func parse(file: LogFile, kind: ProviderKind, now: Date) throws -> ParsedFile {
        switch kind {
        case .claude:
            return try parseClaude(file: file)
        case .codex:
            return try parseCodex(file: file)
        case .kimi:
            return try parseKimi(file: file)
        }
    }

    private func streamLines(
        in url: URL,
        onLine: (Data, Int, Bool) -> Void
    ) throws -> StreamResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var result = StreamResult()
        var line = Data()
        var lineIndex = 1
        var skippingOversizedLine = false

        while let chunk = try handle.read(upToCount: Self.chunkBytes), !chunk.isEmpty {
            let bytes = [UInt8](chunk)
            var cursor = 0
            while cursor < bytes.count {
                if skippingOversizedLine {
                    if let newline = bytes[cursor...].firstIndex(of: 10) {
                        skippingOversizedLine = false
                        lineIndex += 1
                        cursor = newline + 1
                    } else {
                        break
                    }
                    continue
                }

                if let newline = bytes[cursor...].firstIndex(of: 10) {
                    let segmentCount = newline - cursor
                    if line.count + segmentCount > Self.maxLineBytes {
                        result.hadOversizedLine = true
                        line.removeAll(keepingCapacity: true)
                    } else {
                        line.append(contentsOf: bytes[cursor..<newline])
                        onLine(line, lineIndex, true)
                        line.removeAll(keepingCapacity: true)
                    }
                    lineIndex += 1
                    cursor = newline + 1
                    continue
                }

                let remainderCount = bytes.count - cursor
                if line.count + remainderCount > Self.maxLineBytes {
                    result.hadOversizedLine = true
                    line.removeAll(keepingCapacity: true)
                    skippingOversizedLine = true
                } else {
                    line.append(contentsOf: bytes[cursor..<bytes.count])
                }
                break
            }
        }

        if !skippingOversizedLine, !line.isEmpty {
            onLine(line, lineIndex, false)
        }
        return result
    }

    private func parseObject(_ line: Data, terminated: Bool, malformed: inout Bool) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let dictionary = object as? [String: Any]
        else {
            if terminated && Self.mayContainUsageEvent(line) { malformed = true }
            return nil
        }
        return dictionary
    }

    private static func mayContainUsageEvent(_ data: Data) -> Bool {
        let value = String(decoding: data, as: UTF8.self).lowercased()
        return value.contains("assistant")
            || value.contains("token_usage_record")
            || value.contains("token_count")
            || value.contains("usage.record")
            || value.contains("step.end")
            || value.contains("turn_duration")
    }

    private func parseClaude(file: LogFile) throws -> ParsedFile {
        var warning = false
        var recordsByID: [String: UsageActivityRecord] = [:]
        var recordOrder: [String] = []

        let streamResult = try streamLines(in: file.url) { line, lineIndex, terminated in
            guard let object = parseObject(line, terminated: terminated, malformed: &warning) else { return }
            let type = object["type"] as? String
            if type == "assistant" {
                guard let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { return }
                if (message["model"] as? String) == "<synthetic>" { return }

                guard let timestampText = object["timestamp"] as? String,
                      let timestamp = parseISO(timestampText)
                else { warning = true; return }

                guard let tokens = claudeTokens(usage) else { warning = true; return }
                guard hasTokens(tokens) else { return }

                let messageID = nonempty(message["id"] as? String)
                let requestID = nonempty(object["requestId"] as? String)
                let id: String
                if messageID != nil || requestID != nil {
                    id = "claude:\(messageID ?? ""):\(requestID ?? "")"
                } else {
                    id = "claude:\(file.path):\(lineIndex)"
                }
                let metadata = claudeMetadata(object: object, message: message, file: file.url)
                let candidate = UsageActivityRecord(
                    id: id,
                    timestamp: timestamp,
                    sessionID: metadata.sessionID,
                    agentID: metadata.agentID,
                    agentName: metadata.agentName,
                    project: metadata.project,
                    model: metadata.model ?? "Unknown model",
                    tokens: tokens
                )

                if var existing = recordsByID[id] {
                    existing.tokens = componentwiseMaximum(existing.tokens, candidate.tokens)
                    mergeClaudeMetadata(from: candidate, into: &existing)
                    recordsByID[id] = existing
                } else {
                    recordOrder.append(id)
                    recordsByID[id] = candidate
                }
                return
            }

            guard type == "system", object["subtype"] as? String == "turn_duration" else { return }
            guard let timestampText = object["timestamp"] as? String,
                  let timestamp = parseISO(timestampText),
                  let durationMs = nonnegativeDouble(object["durationMs"])
            else { warning = true; return }

            let metadata = claudeMetadata(object: object, message: [:], file: file.url)
            let id = nonempty(object["uuid"] as? String)
                .map { "claude:duration:\($0)" }
                ?? "claude:duration:\(metadata.sessionID):\(timestamp.timeIntervalSince1970)"
            let metric = UsageActivityRecord(
                id: id,
                timestamp: timestamp,
                sessionID: metadata.sessionID,
                agentID: metadata.agentID,
                agentName: metadata.agentName,
                project: metadata.project,
                activeSeconds: durationMs / 1000
            )
            if let existing = recordsByID[id] {
                if metric.timestamp >= existing.timestamp { recordsByID[id] = metric }
            } else {
                recordOrder.append(id)
                recordsByID[id] = metric
            }
        }

        var parsed = ParsedFile(records: recordOrder.compactMap { recordsByID[$0] })
        if warning || streamResult.hadOversizedLine {
            parsed.warnings.append(Self.malformedUsageWarning)
        }
        return parsed
    }

    private func claudeTokens(_ usage: [String: Any]) -> UsageTokenCounts? {
        guard let input = requiredCount(usage, "input_tokens"),
              let output = requiredCount(usage, "output_tokens"),
              let cacheRead = optionalCount(usage, "cache_read_input_tokens"),
              let cacheWrite = optionalCount(usage, "cache_creation_input_tokens")
        else { return nil }

        var cacheWrite1h = 0
        if let rawCreation = usage["cache_creation"] {
            guard let creation = rawCreation as? [String: Any],
                  let value = optionalCount(creation, "ephemeral_1h_input_tokens")
            else { return nil }
            cacheWrite1h = value
        }

        var reasoningOutput = 0
        if let rawDetails = usage["output_tokens_details"] {
            guard let details = rawDetails as? [String: Any],
                  let value = optionalCount(details, "reasoning_tokens")
            else { return nil }
            reasoningOutput = value
        }
        guard cacheWrite1h <= cacheWrite, reasoningOutput <= output else { return nil }

        return UsageTokenCounts(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            cacheWrite1h: cacheWrite1h,
            reasoningOutput: reasoningOutput
        )
    }

    private func claudeMetadata(
        object: [String: Any],
        message: [String: Any],
        file: URL
    ) -> ClaudeMetadata {
        let basename = file.deletingPathExtension().lastPathComponent
        let sessionID = nonempty(object["sessionId"] as? String) ?? basename
        let components = file.standardizedFileURL.pathComponents
        let inSubagentsDirectory = components.dropLast().contains("subagents")
        let sidechain = object["isSidechain"] as? Bool
        let filenameAgent = inSubagentsDirectory && basename.hasPrefix("agent-") && sidechain != false
            ? basename
            : nil
        return ClaudeMetadata(
            sessionID: sessionID,
            agentID: nonempty(object["agentId"] as? String) ?? filenameAgent,
            agentName: nonempty(object["agentType"] as? String),
            project: nonempty(object["cwd"] as? String),
            model: nonempty(message["model"] as? String)
        )
    }

    private func mergeClaudeMetadata(from newer: UsageActivityRecord, into older: inout UsageActivityRecord) {
        if newer.sessionID != "" { older.sessionID = newer.sessionID }
        if let value = newer.agentID { older.agentID = value }
        if let value = newer.agentName { older.agentName = value }
        if let value = newer.project { older.project = value }
        if newer.model != "Unknown model" { older.model = newer.model }
    }

    private func parseCodex(file: LogFile) throws -> ParsedFile {
        var malformed = false
        var events: [CodexEvent] = []
        let streamResult = try streamLines(in: file.url) { line, lineIndex, terminated in
            guard let object = parseObject(line, terminated: terminated, malformed: &malformed) else { return }
            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any] ?? [:]

            if type == "session_meta" {
                if let metadata = codexMetadata(payload) { events.append(.metadata(metadata)) }
                return
            }
            if type == "turn_context" {
                events.append(.context(CodexContext(
                    turnID: nonempty(payload["turn_id"] as? String),
                    model: nonempty(payload["model"] as? String)
                )))
                return
            }
            if type == "token_usage_record" {
                let timestamp = (object["timestamp"] as? String).flatMap(parseISO)
                let usageObject = payload["usage"] as? [String: Any]
                let counters = usageObject.flatMap(codexCounters)
                if timestamp == nil || usageObject == nil || counters == nil { malformed = true }
                events.append(.modern(CodexModernUsage(
                    timestamp: timestamp,
                    responseID: nonempty(payload["response_id"] as? String),
                    threadID: nonempty(payload["thread_id"] as? String),
                    sessionID: nonempty(payload["session_id"] as? String),
                    turnID: nonempty(payload["turn_id"] as? String),
                    counters: counters,
                    lineIndex: lineIndex
                )))
                return
            }

            guard type == "event_msg",
                  let eventType = payload["type"] as? String,
                  eventType == "token_count"
            else { return }
            guard let timestampText = object["timestamp"] as? String,
                  let timestamp = parseISO(timestampText),
                  let info = payload["info"] as? [String: Any]
            else {
                malformed = true
                return
            }

            let totalObject = info["total_token_usage"] as? [String: Any]
            let lastObject = info["last_token_usage"] as? [String: Any]
            let total = totalObject.flatMap(codexCounters)
            let last = lastObject.flatMap(codexCounters)
            if (totalObject != nil && total == nil) || (lastObject != nil && last == nil) {
                malformed = true
            }
            events.append(.legacy(CodexLegacyUsage(
                timestamp: timestamp,
                turnID: nil,
                total: total,
                last: last
            )))
        }

        if streamResult.hadOversizedLine { malformed = true }
        var metadataByID: [String: CodexMetadata] = [:]
        var fileSessionID: String?
        var exactModels: [String: String] = [:]
        var currentModel: String?
        for event in events {
            switch event {
            case .metadata(let metadata):
                if fileSessionID == nil { fileSessionID = metadata.id }
                metadataByID[metadata.id] = metadata
            case .context(let context):
                if let turnID = context.turnID, let model = context.model {
                    exactModels[turnID] = model
                }
                if let model = context.model { currentModel = model }
            case .modern, .legacy:
                break
            }
        }

        let hasModernRecords = events.contains {
            if case .modern = $0 { return true }
            return false
        }
        let modernTurnIDs = Set(events.compactMap { event -> String? in
            guard case .modern(let usage) = event else { return nil }
            return usage.turnID
        })
        var records: [UsageActivityRecord] = []
        var fallbackWarning = false
        var usedLegacy = false
        var currentTurnID: String?
        currentModel = nil
        var previousTotals: CodexCounters?
        let fallbackSessionID = file.url.deletingPathExtension().lastPathComponent

        for event in events {
            switch event {
            case .metadata:
                continue
            case .context(let context):
                currentTurnID = context.turnID
                if let model = context.model { currentModel = model }
            case .modern(let usage):
                guard let timestamp = usage.timestamp, let counters = usage.counters else { continue }
                guard let tokens = normalizedCodexTokens(counters) else {
                    malformed = true
                    continue
                }
                let actualSessionID = codexActualSessionID(
                    threadID: usage.threadID,
                    fileSessionID: fileSessionID,
                    sessionID: usage.sessionID,
                    metadataByID: metadataByID,
                    fallback: fallbackSessionID
                )
                let metadata = metadataByID[actualSessionID]
                let model: String
                if let turnID = usage.turnID {
                    model = exactModels[turnID] ?? "Unknown model"
                } else {
                    model = currentModel ?? "Unknown model"
                }
                let recordID = usage.responseID.map { "codex:\($0)" }
                    ?? "codex:\(actualSessionID):\(usage.turnID ?? "unknown-turn"):"
                        + "\(timestamp.timeIntervalSince1970):\(usage.lineIndex)"
                records.append(UsageActivityRecord(
                    id: recordID,
                    timestamp: timestamp,
                    sessionID: actualSessionID,
                    parentSessionID: metadata?.parentSessionID,
                    agentID: metadata?.isChild == true ? actualSessionID : nil,
                    agentName: metadata?.isChild == true ? (metadata?.role ?? metadata?.nickname) : nil,
                    project: metadata?.project,
                    model: model,
                    tokens: tokens
                ))
            case .legacy(let legacy):
                let turnID = legacy.turnID ?? currentTurnID
                if let turnID, modernTurnIDs.contains(turnID) {
                    previousTotals = legacy.total ?? previousTotals
                    continue
                }
                if turnID == nil && hasModernRecords {
                    fallbackWarning = true
                    previousTotals = legacy.total ?? previousTotals
                    continue
                }

                var rawCounters: CodexCounters?
                if let total = legacy.total {
                    if let previous = previousTotals {
                        if let delta = total.delta(from: previous) {
                            if delta.vector.allSatisfy({ $0 == 0 }) {
                                previousTotals = total
                                continue
                            }
                            rawCounters = delta
                        } else {
                            rawCounters = legacy.last ?? total
                        }
                    } else {
                        rawCounters = legacy.last ?? total
                    }
                    previousTotals = total
                } else if let last = legacy.last {
                    rawCounters = last
                }
                guard let rawCounters, let timestamp = legacy.timestamp else { continue }
                guard let tokens = normalizedCodexTokens(rawCounters) else {
                    malformed = true
                    continue
                }
                guard hasTokens(tokens) else { continue }

                let actualSessionID = codexActualSessionID(
                    threadID: nil,
                    fileSessionID: fileSessionID,
                    sessionID: nil,
                    metadataByID: metadataByID,
                    fallback: fallbackSessionID
                )
                let metadata = metadataByID[actualSessionID]
                let model = currentModel ?? "Unknown model"
                let vector = rawCounters.vector.map(String.init).joined(separator: ",")
                let recordID = "codex:legacy:\(actualSessionID):\(timestamp.timeIntervalSince1970):\(vector)"
                records.append(UsageActivityRecord(
                    id: recordID,
                    timestamp: timestamp,
                    sessionID: actualSessionID,
                    parentSessionID: metadata?.parentSessionID,
                    agentID: metadata?.isChild == true ? actualSessionID : nil,
                    agentName: metadata?.isChild == true ? (metadata?.role ?? metadata?.nickname) : nil,
                    project: metadata?.project,
                    model: model,
                    tokens: tokens
                ))
                usedLegacy = true
            }
        }

        var parsed = ParsedFile(records: records, usedLegacyCodexRecords: usedLegacy)
        if malformed { parsed.warnings.append(Self.malformedUsageWarning) }
        if fallbackWarning { parsed.warnings.append(Self.unidentifiedCodexFallbackWarning) }
        return parsed
    }

    private func codexMetadata(_ payload: [String: Any]) -> CodexMetadata? {
        let source = payload["source"] as? [String: Any] ?? [:]
        let subagent = source["subagent"] as? [String: Any]
        let threadSpawn = subagent?["thread_spawn"] as? [String: Any] ?? [:]
        guard let id = nonempty(payload["id"] as? String)
                ?? nonempty(payload["session_id"] as? String)
        else { return nil }
        return CodexMetadata(
            id: id,
            parentSessionID: nonempty(payload["parent_thread_id"] as? String)
                ?? nonempty(threadSpawn["parent_thread_id"] as? String),
            role: nonempty(payload["agent_role"] as? String)
                ?? nonempty(threadSpawn["agent_role"] as? String),
            nickname: nonempty(threadSpawn["agent_nickname"] as? String),
            project: nonempty(payload["cwd"] as? String),
            isChild: source.keys.contains("subagent")
        )
    }

    private func codexCounters(_ object: [String: Any]) -> CodexCounters? {
        guard let input = requiredCount(object, "input_tokens"),
              let output = requiredCount(object, "output_tokens"),
              let cacheRead = optionalCount(object, "cached_input_tokens"),
              let cacheWrite = optionalCount(object, "cache_write_input_tokens"),
              let reasoning = optionalCount(object, "reasoning_output_tokens")
        else { return nil }

        let reportedTotal: Int?
        if let totalObject = object["total_tokens"] {
            guard let total = Self.parsedCount(totalObject) else { return nil }
            reportedTotal = total
        } else {
            reportedTotal = nil
        }
        return CodexCounters(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoningOutput: reasoning,
            reportedTotal: reportedTotal
        )
    }

    private func normalizedCodexTokens(_ counters: CodexCounters) -> UsageTokenCounts? {
        guard let expectedTotal = safeSum(counters.input, counters.output),
              counters.reportedTotal.map({ $0 == expectedTotal }) ?? true,
              let cacheTotal = safeSum(counters.cacheRead, counters.cacheWrite),
              cacheTotal <= counters.input,
              counters.reasoningOutput <= counters.output
        else { return nil }
        return UsageTokenCounts(
            input: counters.input - cacheTotal,
            output: counters.output,
            cacheRead: counters.cacheRead,
            cacheWrite: counters.cacheWrite,
            reasoningOutput: counters.reasoningOutput
        )
    }

    private func codexActualSessionID(
        threadID: String?,
        fileSessionID: String?,
        sessionID: String?,
        metadataByID: [String: CodexMetadata],
        fallback: String
    ) -> String {
        if let threadID { return threadID }
        if let fileSessionID { return fileSessionID }
        if let sessionID, metadataByID[sessionID] != nil { return metadataByID[sessionID]!.id }
        if let sessionID { return sessionID }
        return fallback
    }

    private func parseKimi(file: LogFile) throws -> ParsedFile {
        var malformed = false
        var recordsByID: [String: UsageActivityRecord] = [:]
        var recordOrder: [String] = []
        var parser = KimiUsageParser()
        let directory = file.url.deletingLastPathComponent()
        let parent = directory.deletingLastPathComponent()
        let isAgentLog = parent.lastPathComponent == "agents"
        let sessionID = isAgentLog
            ? parent.deletingLastPathComponent().lastPathComponent
            : directory.lastPathComponent
        let agentID = isAgentLog && directory.lastPathComponent != "main"
            ? directory.lastPathComponent
            : nil

        let streamResult = try streamLines(in: file.url) { line, _, terminated in
            guard let object = parseObject(line, terminated: terminated, malformed: &malformed) else { return }
            parser.consume(object)
            let event = KimiUsageParser.event(in: object)
            let type = event["type"] as? String
            if type == "turn.ended" {
                guard let time = kimiTime(object["time"] ?? event["time"]),
                      let duration = nonnegativeDouble(object["durationMs"] ?? event["durationMs"])
                else { malformed = true; return }
                let timestamp = Date(timeIntervalSince1970: time / 1000)
                let turnID = numericIdentifier(object["turnId"] ?? event["turnId"])
                let id = "kimi:turn:\(file.path):\(turnID ?? String(timestamp.timeIntervalSince1970))"
                let metadata = (object["metadata"] as? [String: Any])
                    ?? (event["metadata"] as? [String: Any])
                    ?? [:]
                let project = nonempty(metadata["cwd"] as? String)
                    ?? nonempty(metadata["workDir"] as? String)
                let record = UsageActivityRecord(
                    id: id,
                    timestamp: timestamp,
                    sessionID: sessionID,
                    agentID: agentID,
                    project: project,
                    activeSeconds: duration / 1000
                )
                insertMetric(record, id: id, recordsByID: &recordsByID, order: &recordOrder)
                return
            }
        }
        for usage in parser.records where usage.tokens.total > 0 {
            let id = "kimi:usage:\(file.path):\(sessionID):\(usage.id)"
            let record = UsageActivityRecord(
                id: id, timestamp: usage.timestamp, sessionID: sessionID, agentID: agentID,
                project: usage.project, model: usage.model, tokens: usage.tokens
            )
            insertMetric(record, id: id, recordsByID: &recordsByID, order: &recordOrder)
        }
        var parsed = ParsedFile(records: recordOrder.compactMap { recordsByID[$0] })
        if malformed || parser.malformed || streamResult.hadOversizedLine {
            parsed.warnings.append(Self.malformedUsageWarning)
        }
        return parsed
    }

    private func insertMetric(
        _ record: UsageActivityRecord,
        id: String,
        recordsByID: inout [String: UsageActivityRecord],
        order: inout [String]
    ) {
        if let existing = recordsByID[id] {
            if record.timestamp >= existing.timestamp { recordsByID[id] = record }
        } else {
            order.append(id)
            recordsByID[id] = record
        }
    }

    private func parseISO(_ value: String) -> Date? {
        fractionalISO8601.date(from: value) ?? standardISO8601.date(from: value)
    }

    private func requiredCount(_ object: [String: Any], _ key: String) -> Int? {
        guard let value = object[key] else { return nil }
        return Self.parsedCount(value)
    }

    private func optionalCount(_ object: [String: Any], _ key: String) -> Int? {
        guard let value = object[key] else { return 0 }
        return Self.parsedCount(value)
    }

    private static func parsedCount(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double >= 0,
              double.rounded(.towardZero) == double,
              double <= Double(maxSafeCounter)
        else { return nil }
        return Int(double)
    }

    private func nonnegativeDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0 else { return nil }
        return double
    }

    private func kimiTime(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let milliseconds = number.doubleValue
        guard milliseconds.isFinite else { return nil }
        return milliseconds
    }

    private func numericIdentifier(_ value: Any?) -> String? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else { return nil }
        return number.stringValue
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func hasTokens(_ tokens: UsageTokenCounts) -> Bool {
        tokens.input > 0 || tokens.output > 0 || tokens.cacheRead > 0
            || tokens.cacheWrite > 0 || tokens.cacheWrite1h > 0 || tokens.reasoningOutput > 0
    }

    private func componentwiseMaximum(
        _ lhs: UsageTokenCounts,
        _ rhs: UsageTokenCounts
    ) -> UsageTokenCounts {
        UsageTokenCounts(
            input: max(lhs.input, rhs.input),
            output: max(lhs.output, rhs.output),
            cacheRead: max(lhs.cacheRead, rhs.cacheRead),
            cacheWrite: max(lhs.cacheWrite, rhs.cacheWrite),
            cacheWrite1h: max(lhs.cacheWrite1h, rhs.cacheWrite1h),
            reasoningOutput: max(lhs.reasoningOutput, rhs.reasoningOutput)
        )
    }

    private func safeSum(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    private func deduplicated(_ records: [UsageActivityRecord]) -> [UsageActivityRecord] {
        var byID: [String: UsageActivityRecord] = [:]
        for record in records {
            guard let existing = byID[record.id] else {
                byID[record.id] = record
                continue
            }

            let existingHasTokens = hasTokens(existing.tokens)
            let candidateHasTokens = hasTokens(record.tokens)
            if existingHasTokens && candidateHasTokens {
                if record.tokens.total > existing.tokens.total
                    || (record.tokens.total == existing.tokens.total && record.timestamp > existing.timestamp) {
                    var winner = record
                    mergeMissingMetadata(from: existing, into: &winner)
                    byID[record.id] = winner
                } else {
                    var winner = existing
                    mergeMissingMetadata(from: record, into: &winner)
                    byID[record.id] = winner
                }
            } else if record.timestamp > existing.timestamp
                || (record.timestamp == existing.timestamp && candidateHasTokens && !existingHasTokens) {
                byID[record.id] = record
            }
        }
        return Array(byID.values)
    }

    private func append(_ warning: String, to warnings: inout [String], seen: inout Set<String>) {
        guard seen.insert(warning).inserted else { return }
        warnings.append(warning)
    }

    private func append(_ warning: String, to warnings: inout [String]) {
        guard !warnings.contains(warning) else { return }
        warnings.append(warning)
    }

    private func mergeMissingMetadata(from source: UsageActivityRecord, into target: inout UsageActivityRecord) {
        guard source.sessionID == target.sessionID else { return }
        if target.parentSessionID == nil { target.parentSessionID = source.parentSessionID }
        if target.agentID == nil { target.agentID = source.agentID }
        if target.agentName == nil { target.agentName = source.agentName }
        if target.project == nil { target.project = source.project }
        if target.model == "Unknown model" { target.model = source.model }
    }

}
