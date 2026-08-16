import XCTest
@testable import Merly

final class APIHelperTests: XCTestCase {
    func testParseAPIDateVariants() {
        XCTAssertEqual(parseAPIDate(NSNumber(value: 1_700_000_000)),
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(parseAPIDate("2026-01-02T03:04:05Z"),
                       Date(timeIntervalSince1970: 1_767_323_045))
        // Fractional seconds beyond milliseconds must not break parsing.
        XCTAssertNotNil(parseAPIDate("2026-01-02T03:04:05.123456789Z"))
        XCTAssertNil(parseAPIDate(""))
        XCTAssertNil(parseAPIDate(nil))
        XCTAssertNil(parseAPIDate("not a date"))
    }

    func testFlexDouble() {
        XCTAssertEqual(flexDouble(NSNumber(value: 42)), 42)
        XCTAssertEqual(flexDouble("42.5"), 42.5)
        XCTAssertNil(flexDouble("nope"))
        XCTAssertNil(flexDouble(nil))
    }

    func testClaudePlanLabel() {
        XCTAssertEqual(ClaudeUsageAPI.planLabel(subscription: "max", tier: "default_claude_max_20x"),
                       "Max (20x)")
        XCTAssertEqual(ClaudeUsageAPI.planLabel(subscription: "pro", tier: nil), "Pro")
        XCTAssertNil(ClaudeUsageAPI.planLabel(subscription: nil, tier: "x"))
    }

    func testCodexPlanLabel() {
        XCTAssertEqual(CodexUsageAPI.planLabel("prolite"), "Pro (5x)")
        XCTAssertEqual(CodexUsageAPI.planLabel("plus"), "Plus")
        XCTAssertEqual(CodexUsageAPI.planLabel("somefuturecode"), "Somefuturecode")
        XCTAssertNil(CodexUsageAPI.planLabel(nil))
        XCTAssertNil(CodexUsageAPI.planLabel(""))
    }

    func testKeychainServiceNames() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ClaudeUsageAPI.keychainService(forConfigDir: home + "/.claude"),
                       "Claude Code-credentials")
        let custom = ClaudeUsageAPI.keychainService(forConfigDir: home + "/.claude-work")
        XCTAssertTrue(custom.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(custom.count, "Claude Code-credentials-".count + 8,
                       "custom dirs get an 8-hex-char suffix")
    }

    func testAccessDeniedClassification() {
        XCTAssertTrue(ProviderAPIError.http(403).isAccessDenied)
        XCTAssertTrue(ProviderAPIError.http(402).isAccessDenied)
        XCTAssertTrue(ProviderAPIError.http(404).isAccessDenied)
        // A 400 is our bug (schema/request drift), not a refused account.
        XCTAssertFalse(ProviderAPIError.http(400).isAccessDenied)
        XCTAssertFalse(ProviderAPIError.http(401).isAccessDenied)
        XCTAssertFalse(ProviderAPIError.http(429).isAccessDenied)
        XCTAssertFalse(ProviderAPIError.http(500).isAccessDenied)
    }
}

/// Fixture-driven parsers: each reader's line format, written to a temp file
/// and parsed exactly as a refresh pass would.
final class TranscriptParsingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("merly-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func write(_ lines: [String], to name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testClaudeParseDedupesStreamedMessages() throws {
        let usage = #"{"input_tokens": 100, "output_tokens": 50, "cache_creation_input_tokens": 10, "cache_read_input_tokens": 40}"#
        let entry = #"{"type": "assistant", "timestamp": "2026-01-02T03:00:10Z", "requestId": "r1", "message": {"id": "m1", "model": "claude-fable-5", "usage": \#(usage)}}"#
        let url = try write([entry, entry], to: "transcript.jsonl") // streamed repeat
        let buckets = ClaudeReader.parse(url)

        let hour = buckets.keys.first
        XCTAssertNotNil(hour)
        XCTAssertEqual(buckets[hour!]?["all"], 200, "the repeated message must count once")
        XCTAssertEqual(buckets[hour!]?["fable"], 200)
    }

    func testClaudeParseSkipsNonAssistantAndZeroUsage() throws {
        let lines = [
            #"{"type": "user", "timestamp": "2026-01-02T03:00:10Z", "message": {"usage": {"input_tokens": 5}, "content": "assistant usage"}}"#,
            #"{"type": "assistant", "timestamp": "2026-01-02T03:00:10Z", "message": {"id": "m2", "usage": {"input_tokens": 0, "output_tokens": 0}}}"#,
        ]
        let url = try write(lines, to: "transcript.jsonl")
        XCTAssertTrue(ClaudeReader.parse(url).isEmpty)
    }

    func testKimiParseReadsWireEvents() throws {
        let line = #"{"time": 1767323045000, "event": {"usage": {"inputOther": 10, "output": 20, "inputCacheRead": 30, "inputCacheCreation": 0}}}"#
        let url = try write([line], to: "wire.jsonl")
        let buckets = KimiReader.parse(url)
        XCTAssertEqual(buckets.values.first?["all"], 60)
    }

    func testCodexLastRateLimitsFindsNewestEvent() throws {
        let older = #"{"timestamp": "2026-01-02T03:00:00Z", "payload": {"rate_limits": {"primary": {"used_percent": 10}}}}"#
        let newer = #"{"timestamp": "2026-01-02T04:00:00Z", "payload": {"rate_limits": {"primary": {"used_percent": 55}}}}"#
        let url = try write([older, newer, #"{"other": true}"#], to: "rollout.jsonl")
        let found = CodexReader.lastRateLimits(in: url)
        XCTAssertNotNil(found)
        let primary = found?.limits["primary"] as? [String: Any]
        XCTAssertEqual((primary?["used_percent"] as? NSNumber)?.doubleValue, 55,
                       "the newest rate_limits event in the file wins")
    }
}
