import XCTest
@testable import Merly

final class KimiUsageParserTests: XCTestCase {
    private let time = 1_779_256_800_300.0

    private func modern(_ count: Int, scope: String? = "turn", offset: Double = 0) -> [String: Any] {
        var record: [String: Any] = [
            "type": "usage.record", "time": time + offset,
            "usage": ["inputOther": count], "model": "kimi-k2"
        ]
        record["usageScope"] = scope
        return record
    }

    private func legacy(_ count: Int, offset: Double = 0) -> [String: Any] {
        ["type": "context.append_loop_event", "time": time + offset,
         "event": ["type": "step.end", "usage": ["inputOther": count]]]
    }

    private func parse(_ objects: [[String: Any]]) -> KimiUsageParser {
        var parser = KimiUsageParser()
        for object in objects { parser.consume(object) }
        return parser
    }

    func testCompactionAndTurnUsageAreAdditiveIncludingMissingScope() {
        let compaction = modern(52_000, scope: "session")
        XCTAssertEqual(parse([compaction]).records.map(\.tokens.total), [52_000])
        let parsed = parse([compaction, modern(120, offset: 2), modern(7, scope: nil, offset: 4)])
        XCTAssertEqual(parsed.records.map(\.tokens.total), [52_000, 120, 7])
        XCTAssertFalse(parsed.malformed)
    }

    func testMixedFormatHistorySurvivesAndOnlyRepeatedMeasurementIsRemoved() {
        let parsed = parse([legacy(900, offset: -3_600_000), legacy(120), modern(120, offset: 2)])
        XCTAssertEqual(parsed.records.map(\.tokens.total), [900, 120])
        XCTAssertEqual(parsed.records.last?.model, "kimi-k2")
    }

    func testDuplicateMeasurementsWorkInEitherOrderAndDoNotConsumeCompaction() {
        XCTAssertEqual(parse([modern(120), legacy(120, offset: 2)]).records.count, 1)
        XCTAssertEqual(parse([legacy(120), modern(120, scope: "session", offset: 2)]).records.count, 2)
        XCTAssertEqual(parse([modern(120), modern(120)]).records.count, 1)
    }

    func testRequestBoundariesAndTimeSeparateIdenticalUsage() {
        for boundary in ["turn.prompt", "turn.started", "step.begin", "llm.request"] {
            let parsed = parse([legacy(120), ["type": boundary], modern(120, offset: 2)])
            XCTAssertEqual(parsed.records.count, 2)
        }
        XCTAssertEqual(parse([legacy(120), modern(120, offset: 3_600_000)]).records.count, 2)
        XCTAssertEqual(parse([modern(120), ["type": "step.begin"], modern(120)]).records.count, 2)
    }

    func testInvalidUsageDoesNotEraseLegacyAndZeroRemainsValid() {
        var invalid = modern(120)
        invalid["usage"] = ["inputOther": 120, "output": -1]
        let parsed = parse([legacy(20), invalid, modern(0, offset: 2)])
        XCTAssertEqual(parsed.records.map(\.tokens.total), [20, 0])
        XCTAssertTrue(parsed.malformed)
        for value: Any in [true, 1.5, Double.infinity, "10"] {
            var malformed = modern(0)
            malformed["usage"] = ["inputOther": value]
            XCTAssertTrue(parse([malformed]).records.isEmpty)
        }
    }

    func testFallbackAndDetailsAgreeOnMixedHistoryAndCompaction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sessions/work/session/agents/main/wire.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let objects = [["type": "llm.request", "model": "kimi-k2"],
                       legacy(900, offset: -3_600_000), modern(52_000, scope: "session"),
                       legacy(120, offset: 10), modern(120, offset: 12)]
        let lines = try objects.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        let now = Date(timeIntervalSince1970: time / 1000 + 60)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let config = ProviderConfig(id: "test", name: "Kimi", account: "Test", kind: .kimi, dir: directory.path)
        let report = UsageAnalyticsStore().read(config: config, now: now)
        XCTAssertEqual(KimiReader.parse(file).values.reduce(0) { $0 + ($1["all"] ?? 0) }, 53_020)
        XCTAssertEqual(report.records.reduce(0) { $0 + $1.tokens.total }, 53_020)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertTrue(report.records.allSatisfy { $0.sessionID == "session" })
    }
}
