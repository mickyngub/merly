import Foundation
import XCTest
@testable import Merly

private let analyticsStoreTestNow = Date(timeIntervalSince1970: 1_790_000_000)

private func analyticsStoreTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MerlyUsageAnalyticsStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func analyticsStoreTestConfig(
    kind: ProviderKind = .claude,
    directory: URL,
    id: String = "analytics-provider"
) -> ProviderConfig {
    ProviderConfig(id: id, name: kind.displayName, account: "Test", kind: kind, dir: directory.path)
}

private func analyticsStoreTestWrite(
    _ lines: [String],
    to url: URL,
    modifiedAt: Date = analyticsStoreTestNow
) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
}

private func analyticsStoreTestLine(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func analyticsStoreTestISO(_ offset: TimeInterval = 0) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: analyticsStoreTestNow.addingTimeInterval(offset))
}

private func analyticsStoreClaudeLine(
    input: Any = 1,
    output: Any = 0,
    cacheRead: Any = 0,
    cacheWrite: Any = 0,
    offset: TimeInterval = 0,
    messageID: String = UUID().uuidString,
    requestID: String = UUID().uuidString,
    sessionID: String = "claude-session",
    model: String = "claude-opus-5-5",
    extra: [String: Any] = [:]
) throws -> String {
    var object: [String: Any] = [
        "type": "assistant",
        "timestamp": analyticsStoreTestISO(offset),
        "sessionId": sessionID,
        "requestId": requestID,
        "message": [
            "id": messageID,
            "model": model,
            "usage": [
                "input_tokens": input,
                "output_tokens": output,
                "cache_read_input_tokens": cacheRead,
                "cache_creation_input_tokens": cacheWrite
            ]
        ]
    ]
    for (key, value) in extra { object[key] = value }
    return try analyticsStoreTestLine(object)
}

private func analyticsStoreCodexMetadata(
    id: String,
    parent: String? = nil,
    isSubagent: Bool = false,
    role: String? = nil,
    cwd: String? = nil
) -> String {
    var payload: [String: Any] = ["id": id]
    if let parent { payload["parent_thread_id"] = parent }
    if let role { payload["agent_role"] = role }
    if let cwd { payload["cwd"] = cwd }
    if isSubagent { payload["source"] = ["subagent": [String: Any]()] }
    let object: [String: Any] = ["type": "session_meta", "payload": payload]
    return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
}

private func analyticsStoreCodexModern(
    responseID: String?,
    threadID: String?,
    turnID: String?,
    sessionID: String? = nil,
    input: Int = 10,
    output: Int = 2,
    cached: Int = 0,
    cacheWrite: Int = 0,
    reasoning: Int = 0,
    total: Int? = nil,
    offset: TimeInterval = 0,
    forkedFrom: String? = nil
) -> String {
    var usage: [String: Any] = [
        "input_tokens": input,
        "output_tokens": output,
        "cached_input_tokens": cached,
        "cache_write_input_tokens": cacheWrite,
        "reasoning_output_tokens": reasoning
    ]
    if let total { usage["total_tokens"] = total }
    var payload: [String: Any] = ["usage": usage]
    if let threadID { payload["thread_id"] = threadID }
    if let responseID { payload["response_id"] = responseID }
    if let turnID { payload["turn_id"] = turnID }
    if let sessionID { payload["session_id"] = sessionID }
    if let forkedFrom { payload["forked_from_id"] = forkedFrom }
    let object: [String: Any] = [
        "timestamp": analyticsStoreTestISO(offset),
        "type": "token_usage_record",
        "payload": payload
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
}

private func analyticsStoreCodexLegacy(
    totalInput: Int,
    totalOutput: Int,
    totalCacheRead: Int = 0,
    lastInput: Int? = nil,
    lastOutput: Int? = nil,
    lastCacheRead: Int = 0,
    offset: TimeInterval = 0
) -> String {
    var info: [String: Any] = [
        "total_token_usage": [
            "input_tokens": totalInput,
            "output_tokens": totalOutput,
            "cached_input_tokens": totalCacheRead
        ]
    ]
    if let lastInput, let lastOutput {
        info["last_token_usage"] = [
            "input_tokens": lastInput,
            "output_tokens": lastOutput,
            "cached_input_tokens": lastCacheRead
        ]
    }
    let object: [String: Any] = [
        "timestamp": analyticsStoreTestISO(offset),
        "type": "event_msg",
        "payload": ["type": "token_count", "info": info]
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
}

final class UsageAnalyticsStoreTests: XCTestCase {
    func testClaudeStreamingRevisionsAndSubagentsDoNotDoubleCount() throws {
        let directory = try analyticsStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("projects/work/session.jsonl")
        let child = directory.appendingPathComponent("projects/work/subagents/agent-worker.jsonl")
        try analyticsStoreTestWrite([
            try analyticsStoreClaudeLine(input: 5, output: 2, offset: 1, messageID: "streamed", requestID: "request"),
            try analyticsStoreClaudeLine(
                input: 7, output: 4, cacheWrite: 3,
                offset: 2, messageID: "streamed", requestID: "request",
                extra: ["cwd": "/new/project"]
            )
        ], to: root)
        try analyticsStoreTestWrite([
            try analyticsStoreClaudeLine(
                input: 3, output: 1, messageID: "child-message", requestID: "child-request",
                sessionID: "root-session", extra: ["agentType": "Explore", "cwd": "/work"]
            )
        ], to: child)

        let report = UsageAnalyticsStore().read(
            config: analyticsStoreTestConfig(directory: directory), now: analyticsStoreTestNow.addingTimeInterval(2)
        )
        let streamed = try XCTUnwrap(report.records.first { $0.id == "claude:streamed:request" })
        let subagent = try XCTUnwrap(report.records.first { $0.agentID == "agent-worker" })

        XCTAssertEqual(report.records.count, 2)
        XCTAssertEqual(streamed.timestamp, analyticsStoreTestNow.addingTimeInterval(1))
        XCTAssertEqual(streamed.tokens.input, 7)
        XCTAssertEqual(streamed.tokens.output, 4)
        XCTAssertEqual(streamed.tokens.cacheWrite, 3)
        XCTAssertEqual(streamed.project, "/new/project")
        XCTAssertEqual(subagent.sessionID, "root-session")
        XCTAssertEqual(subagent.agentName, "Explore")
        XCTAssertEqual(subagent.project, "/work")
    }

    func testClaudeSyntheticRowsAndInvalidCountersAreExcluded() throws {
        let directory = try analyticsStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("projects/session.jsonl")
        try analyticsStoreTestWrite([
            try analyticsStoreClaudeLine(input: -1, messageID: "synthetic", requestID: "error", model: "<synthetic>"),
            try analyticsStoreClaudeLine(input: 1.5, messageID: "bad", requestID: "counter")
        ], to: file)

        let report = UsageAnalyticsStore().read(
            config: analyticsStoreTestConfig(directory: directory), now: analyticsStoreTestNow
        )

        XCTAssertTrue(report.records.isEmpty)
        XCTAssertTrue(report.warnings.contains("Some local usage records could not be decoded. Totals may be incomplete."))
        XCTAssertFalse(report.warnings.contains { $0.contains(file.path) })
    }

    func testCodexResponseRecordsOverrideMatchingRollupsAndUseTurnModels() throws {
        let directory = try analyticsStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sessions/rollout.jsonl")
        let context = try analyticsStoreTestLine([
            "type": "turn_context",
            "payload": ["turn_id": "turn-1", "model": "gpt-5-codex"]
        ])
        try analyticsStoreTestWrite([
            analyticsStoreCodexMetadata(id: "metadata-thread"),
            context,
            analyticsStoreCodexLegacy(
                totalInput: 100, totalOutput: 20, totalCacheRead: 40,
                lastInput: 100, lastOutput: 20, lastCacheRead: 40
            ),
            analyticsStoreCodexModern(
                responseID: "response-1", threadID: "thread-1", turnID: "turn-1",
                input: 100, output: 20, cached: 40, cacheWrite: 10, reasoning: 5, total: 120
            ),
            analyticsStoreCodexModern(
                responseID: "response-2", threadID: nil, turnID: "turn-1", input: 1, output: 1
            )
        ], to: file)

        let report = UsageAnalyticsStore().read(
            config: analyticsStoreTestConfig(kind: .codex, directory: directory), now: analyticsStoreTestNow
        )
        let record = try XCTUnwrap(report.records.first { $0.id == "codex:response-1" })
        let metadataFallback = try XCTUnwrap(report.records.first { $0.id == "codex:response-2" })

        XCTAssertEqual(report.records.count, 2)
        XCTAssertEqual(record.id, "codex:response-1")
        XCTAssertEqual(record.sessionID, "thread-1")
        XCTAssertEqual(record.model, "gpt-5-codex")
        XCTAssertEqual(record.tokens.input, 50)
        XCTAssertEqual(record.tokens.cacheRead, 40)
        XCTAssertEqual(record.tokens.cacheWrite, 10)
        XCTAssertEqual(record.tokens.output, 20)
        XCTAssertEqual(record.tokens.reasoningOutput, 5)
        XCTAssertEqual(metadataFallback.sessionID, "metadata-thread")
        XCTAssertFalse(report.warnings.contains { $0.contains("Older Codex") })
    }

    func testCodexCopiedResponsesUseOriginalThreadAndDeduplicateAcrossFiles() throws {
        let directory = try analyticsStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("sessions/original.jsonl")
        let copy = directory.appendingPathComponent("archived_sessions/copy.jsonl")
        let context = try analyticsStoreTestLine([
            "type": "turn_context",
            "payload": ["turn_id": "child-turn", "model": "gpt-child"]
        ])
        try analyticsStoreTestWrite([
            analyticsStoreCodexMetadata(id: "parent-thread", cwd: "/parent"),
            analyticsStoreCodexMetadata(
                id: "child-thread", parent: "parent-thread", isSubagent: true,
                role: "reviewer", cwd: "/child"
            ),
            context,
            analyticsStoreCodexModern(
                responseID: "copied-response", threadID: "child-thread", turnID: "child-turn",
                input: 12, output: 3
            ),
            analyticsStoreCodexModern(
                responseID: "independent-response", threadID: "independent-thread", turnID: "child-turn",
                input: 4, output: 1, offset: -1, forkedFrom: "parent-thread"
            )
        ], to: original)
        try analyticsStoreTestWrite([
            analyticsStoreCodexMetadata(id: "file-current-thread", cwd: "/wrong-current-agent"),
            context,
            analyticsStoreCodexModern(
                responseID: "copied-response", threadID: "child-thread", turnID: "child-turn",
                input: 12, output: 3
            )
        ], to: copy)

        let report = UsageAnalyticsStore().read(
            config: analyticsStoreTestConfig(kind: .codex, directory: directory), now: analyticsStoreTestNow.addingTimeInterval(4)
        )
        let child = try XCTUnwrap(report.records.first { $0.id == "codex:copied-response" })
        let independent = try XCTUnwrap(report.records.first { $0.id == "codex:independent-response" })

        XCTAssertEqual(report.records.count, 2)
        XCTAssertEqual(child.sessionID, "child-thread")
        XCTAssertEqual(child.parentSessionID, "parent-thread")
        XCTAssertEqual(child.agentID, "child-thread")
        XCTAssertEqual(child.agentName, "reviewer")
        XCTAssertEqual(child.project, "/child")
        XCTAssertNil(independent.parentSessionID)
        XCTAssertNil(independent.agentID)
    }

    func testLegacyCodexRepeatedCountersAndResetUseDeltas() throws {
        let directory = try analyticsStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sessions/legacy.jsonl")
        let context = try analyticsStoreTestLine([
            "type": "turn_context",
            "payload": ["turn_id": "legacy-turn", "model": "gpt-legacy"]
        ])
        try analyticsStoreTestWrite([
            analyticsStoreCodexMetadata(id: "legacy-thread"),
            context,
            analyticsStoreCodexLegacy(
                totalInput: 100, totalOutput: 10, totalCacheRead: 20,
                lastInput: 15, lastOutput: 2, lastCacheRead: 3, offset: 1
            ),
            analyticsStoreCodexLegacy(
                totalInput: 100, totalOutput: 10, totalCacheRead: 20,
                lastInput: 25, lastOutput: 2, lastCacheRead: 4, offset: 2
            ),
            analyticsStoreCodexLegacy(totalInput: 120, totalOutput: 15, totalCacheRead: 25, offset: 3),
            analyticsStoreCodexLegacy(
                totalInput: 5, totalOutput: 1, totalCacheRead: 1,
                lastInput: 4, lastOutput: 2, lastCacheRead: 1, offset: 4
            )
        ], to: file)

        let report = UsageAnalyticsStore().read(
            config: analyticsStoreTestConfig(kind: .codex, directory: directory), now: analyticsStoreTestNow.addingTimeInterval(4)
        )

        XCTAssertEqual(report.records.count, 3)
        XCTAssertTrue(report.records.allSatisfy { $0.sessionID == "legacy-thread" })
        XCTAssertEqual(report.records.map(\.tokens.total), [17, 25, 6])
        XCTAssertEqual(report.records[1].tokens.input, 15)
        XCTAssertEqual(report.records[1].tokens.cacheRead, 5)
        XCTAssertTrue(report.warnings.contains("Older Codex logs use cumulative usage; model and session attribution may be incomplete."))
    }

    func testKimiUsageRecordsIgnoreCountingMeasurementsAndKeepRecordedDuration() throws {
        let directory = try analyticsStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sessions/wd-one/ses-one/wire.jsonl")
        let time = analyticsStoreTestNow.timeIntervalSince1970 * 1000
        let usage: [String: Any] = [
            "inputOther": 10,
            "output": 20,
            "inputCacheRead": 30,
            "inputCacheCreation": 4
        ]
        let usageRecord: [String: Any] = [
            "type": "usage.record", "time": time, "usageScope": "turn",
            "model": "kimi-k2", "usage": usage
        ]
        let secondTimeRecord: [String: Any] = [
            "type": "usage.record", "time": time + 1_000, "usageScope": "request",
            "usage": usage
        ]
        let unsupportedScope: [String: Any] = [
            "type": "usage.record", "time": time + 2_000, "usageScope": "session",
            "model": "kimi-k2", "usage": ["inputOther": 500, "output": 500]
        ]
        try analyticsStoreTestWrite([
            try analyticsStoreTestLine(["type": "llm.request", "model": "fallback-model"]),
            try analyticsStoreTestLine(usageRecord),
            try analyticsStoreTestLine(usageRecord),
            try analyticsStoreTestLine(secondTimeRecord),
            try analyticsStoreTestLine(["type": "token_counting.measured", "time": time + 4_000, "tokens": 1_000_000]),
            try analyticsStoreTestLine(unsupportedScope),
            try analyticsStoreTestLine([
                "type": "turn.ended", "time": time + 3_000,
                "turnId": 0, "durationMs": 2_500
            ])
        ], to: file)

        let report = UsageAnalyticsStore().read(
            config: analyticsStoreTestConfig(kind: .kimi, directory: directory), now: analyticsStoreTestNow.addingTimeInterval(4)
        )
        let usageRecords = report.records.filter { $0.tokens.total > 0 }
        let duration = try XCTUnwrap(report.records.first { $0.activeSeconds != nil })

        XCTAssertEqual(usageRecords.count, 2)
        XCTAssertEqual(usageRecords.reduce(0) { $0 + $1.tokens.total }, 128)
        XCTAssertEqual(Set(usageRecords.map(\.model)), ["kimi-k2", "fallback-model"])
        XCTAssertEqual(duration.activeSeconds, 2.5)
        XCTAssertEqual(duration.sessionID, "ses-one")
        XCTAssertTrue(report.warnings.contains("Some local usage records could not be decoded. Totals may be incomplete."))
    }

    func testKimiNestedSessionsStaySeparateAndWorkersJoinTheirSession() throws {
        let directory = try analyticsStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("sessions/wd-one/ses-one/agents/main/wire.jsonl")
        let worker = directory.appendingPathComponent("sessions/wd-one/ses-one/agents/worker-one/wire.jsonl")
        let second = directory.appendingPathComponent("sessions/wd-one/ses-two/agents/main/wire.jsonl")
        let time = analyticsStoreTestNow.timeIntervalSince1970 * 1000
        func usageLine(input: Int, offset: Double) throws -> String {
            try analyticsStoreTestLine([
                "type": "usage.record", "time": time + offset * 1000,
                "model": "kimi-k2", "usage": ["inputOther": input, "output": 5]
            ])
        }
        try analyticsStoreTestWrite([try usageLine(input: 10, offset: 0)], to: first)
        try analyticsStoreTestWrite([
            try usageLine(input: 30, offset: 1),
            try analyticsStoreTestLine([
                "type": "turn.ended", "time": time + 1500,
                "turnId": 0, "durationMs": 2500
            ])
        ], to: worker)
        try analyticsStoreTestWrite([try usageLine(input: 20, offset: 2)], to: second)
        let now = analyticsStoreTestNow.addingTimeInterval(3)

        let report = UsageAnalyticsStore().read(
            config: analyticsStoreTestConfig(kind: .kimi, directory: directory), now: now
        )
        let sessions = UsageAnalytics.sessions(in: report, now: now)
        let firstSession = UsageAnalytics.summarize(report, range: .latest, sessionID: "ses-one", now: now)
        let latestSession = UsageAnalytics.summarize(report, range: .latest, now: now)
        let workerRecords = report.records.filter { $0.agentID == "worker-one" }

        XCTAssertEqual(sessions.map(\.id), ["ses-two", "ses-one"])
        XCTAssertEqual(firstSession.tokens.total, 50)
        XCTAssertEqual(firstSession.requestCount, 2)
        XCTAssertEqual(firstSession.contributors.count, 2)
        XCTAssertEqual(latestSession.tokens.total, 25)
        XCTAssertEqual(workerRecords.count, 2)
        XCTAssertTrue(workerRecords.allSatisfy { $0.sessionID == "ses-one" })
        XCTAssertEqual(workerRecords.first { $0.activeSeconds != nil }?.activeSeconds, 2.5)
        XCTAssertEqual(report.records.filter { $0.agentID == nil }.count, 2)
    }

    func testCacheReusesUnchangedFilesAndReplacesChangedOrTruncatedFiles() throws {
        let directory = try analyticsStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("projects/session.jsonl")
        let first = try analyticsStoreClaudeLine(input: 2, messageID: "first", requestID: "one")
        let second = try analyticsStoreClaudeLine(input: 3, messageID: "second", requestID: "two")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data((first + "\n" + String(second.prefix(28))).utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: analyticsStoreTestNow], ofItemAtPath: file.path)
        let store = UsageAnalyticsStore()
        let config = analyticsStoreTestConfig(directory: directory)
        let initial = store.read(config: config, now: analyticsStoreTestNow)
        let unchanged = store.read(config: config, now: analyticsStoreTestNow.addingTimeInterval(1))
        XCTAssertEqual(initial.records, unchanged.records)
        XCTAssertEqual(initial.records.count, 1)
        XCTAssertFalse(initial.warnings.contains { $0.contains("usage records could not be decoded") })

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(second.dropFirst(28)) + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: analyticsStoreTestNow.addingTimeInterval(2)], ofItemAtPath: file.path
        )
        let appended = store.read(config: config, now: analyticsStoreTestNow.addingTimeInterval(2))
        XCTAssertEqual(appended.records.count, 2)

        let replacement = try analyticsStoreClaudeLine(input: 9, messageID: "replacement", requestID: "three")
        try Data((replacement + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: analyticsStoreTestNow.addingTimeInterval(3)], ofItemAtPath: file.path
        )
        let replaced = store.read(config: config, now: analyticsStoreTestNow.addingTimeInterval(3))
        XCTAssertEqual(replaced.records.count, 1)
        XCTAssertEqual(replaced.records.first?.tokens.input, 9)

        try FileManager.default.removeItem(at: file)
        let deleted = store.read(config: config, now: analyticsStoreTestNow.addingTimeInterval(4))
        XCTAssertTrue(deleted.records.isEmpty)
        XCTAssertTrue(deleted.warnings.contains("No local session logs found for this provider."))
    }

    func testCutoffMissingDirectoriesAndMalformedLinesAreExplicit() throws {
        let missingDirectory = try analyticsStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: missingDirectory) }
        let missing = UsageAnalyticsStore().read(
            config: analyticsStoreTestConfig(directory: missingDirectory), now: analyticsStoreTestNow
        )
        XCTAssertTrue(missing.warnings.contains("No local session logs found for this provider."))

        let oldDirectory = try analyticsStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: oldDirectory) }
        let oldFile = oldDirectory.appendingPathComponent("projects/old.jsonl")
        try analyticsStoreTestWrite(
            [try analyticsStoreClaudeLine(input: 10)],
            to: oldFile,
            modifiedAt: analyticsStoreTestNow.addingTimeInterval(-31 * 24 * 60 * 60)
        )
        let cutoff = UsageAnalyticsStore().read(
            config: analyticsStoreTestConfig(directory: oldDirectory), now: analyticsStoreTestNow
        )
        XCTAssertTrue(cutoff.records.isEmpty)
        XCTAssertTrue(cutoff.warnings.contains("No local session logs found for this provider."))

        let malformedDirectory = try analyticsStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: malformedDirectory) }
        let malformedFile = malformedDirectory.appendingPathComponent("projects/broken.jsonl")
        try analyticsStoreTestWrite([#"{"type":"assistant","message":{"usage": "#], to: malformedFile)
        let malformed = UsageAnalyticsStore().read(
            config: analyticsStoreTestConfig(directory: malformedDirectory), now: analyticsStoreTestNow
        )
        XCTAssertTrue(malformed.records.isEmpty)
        XCTAssertTrue(malformed.warnings.contains("Some local usage records could not be decoded. Totals may be incomplete."))
        XCTAssertTrue(malformed.warnings.contains("No token usage was found in the local logs."))
    }

    func testPerProviderIdentitySeparatesDirectoriesAndKinds() throws {
        let firstDirectory = try analyticsStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: firstDirectory) }
        let secondDirectory = try analyticsStoreTestDirectory()
        defer { try? FileManager.default.removeItem(at: secondDirectory) }
        try analyticsStoreTestWrite(
            [try analyticsStoreClaudeLine(input: 1, messageID: "a", requestID: "one")],
            to: firstDirectory.appendingPathComponent("projects/a.jsonl")
        )
        try analyticsStoreTestWrite(
            [try analyticsStoreClaudeLine(input: 2, messageID: "b", requestID: "two")],
            to: secondDirectory.appendingPathComponent("projects/b.jsonl")
        )
        try analyticsStoreTestWrite(
            [analyticsStoreCodexModern(responseID: "c", threadID: "thread-c", turnID: nil, input: 3)],
            to: firstDirectory.appendingPathComponent("sessions/c.jsonl")
        )

        let store = UsageAnalyticsStore()
        let first = store.read(
            config: analyticsStoreTestConfig(directory: firstDirectory), now: analyticsStoreTestNow
        )
        let second = store.read(
            config: analyticsStoreTestConfig(directory: secondDirectory), now: analyticsStoreTestNow
        )
        let codex = store.read(
            config: analyticsStoreTestConfig(kind: .codex, directory: firstDirectory), now: analyticsStoreTestNow
        )

        XCTAssertNotEqual(first.identity, second.identity)
        XCTAssertNotEqual(first.identity, codex.identity)
        XCTAssertEqual(first.records.first?.tokens.total, 1)
        XCTAssertEqual(second.records.first?.tokens.total, 2)
        XCTAssertEqual(codex.records.first?.tokens.total, 5)
    }
}
