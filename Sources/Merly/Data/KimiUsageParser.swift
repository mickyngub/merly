import CoreFoundation
import Foundation

struct KimiUsageParser {
    struct Record {
        let id: String
        let timestamp: Date
        let tokens: UsageTokenCounts
        let model: String
        let project: String?
    }

    private var byID: [String: Record] = [:]
    private var order: [String] = []
    private var seen: Set<String> = []
    private var pendingLegacy: Record?
    private var pendingModern: Record?
    private var boundary = 0
    private var model = "Unknown model"
    private(set) var malformed = false

    var records: [Record] { order.compactMap { byID[$0] } }

    static func event(in object: [String: Any]) -> [String: Any] {
        if object["type"] == nil || object["type"] as? String == "context.append_loop_event" {
            return object["event"] as? [String: Any] ?? object
        }
        return object
    }

    mutating func consume(_ object: [String: Any]) {
        let event = Self.event(in: object)
        let type = event["type"] as? String
        if let type, ["turn.prompt", "turn.started", "turn.ended", "step.begin", "llm.request"].contains(type) {
            pendingLegacy = nil
            pendingModern = nil
            boundary += 1
        }
        if type == "llm.request" {
            if let name = event["model"] as? String, !name.isEmpty { model = name }
            return
        }
        let modern = type == "usage.record"
        guard modern || type == "step.end" || (type == nil && event["usage"] != nil) else { return }
        let scope = event["usageScope"] as? String
        if modern, let raw = event["usageScope"],
           !(raw is String && ["turn", "session", "request", "step"].contains(scope ?? "")) {
            malformed = true
            return
        }
        guard let usage = event["usage"] as? [String: Any],
              let tokens = Self.tokens(in: usage),
              let milliseconds = (object["time"] ?? event["time"]) as? NSNumber,
              CFGetTypeID(milliseconds) != CFBooleanGetTypeID() else {
            malformed = true
            return
        }
        let seconds = milliseconds.doubleValue / 1000
        guard seconds.isFinite, (-62_135_596_800...253_402_300_799).contains(seconds) else {
            malformed = true
            return
        }
        let name = (event["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? model
        let id = "\(boundary):\(type ?? "legacy-usage"):\(scope ?? ""):\(milliseconds):"
            + "\(tokens.input),\(tokens.output),\(tokens.cacheRead),\(tokens.cacheWrite):\(name)"
        guard seen.insert(id).inserted else { return }
        let metadata = event["metadata"] as? [String: Any] ?? object["metadata"] as? [String: Any] ?? [:]
        let record = Record(
            id: id, timestamp: Date(timeIntervalSince1970: seconds), tokens: tokens, model: name,
            project: metadata["cwd"] as? String ?? metadata["workDir"] as? String
        )

        // UsageRecord has no request ID. Match only adjacent equivalent measurements
        // within a request boundary; session-scoped compaction is always additive.
        if modern {
            if scope != "session", let legacy = pendingLegacy, Self.matches(legacy, record) {
                byID.removeValue(forKey: legacy.id)
                pendingLegacy = nil
                pendingModern = nil
            } else if scope != "session" {
                pendingModern = record
            }
        } else if let modern = pendingModern, Self.matches(modern, record) {
            pendingModern = nil
            return
        } else {
            pendingLegacy = record
        }
        byID[id] = record
        order.append(id)
    }

    private static func matches(_ a: Record, _ b: Record) -> Bool {
        a.tokens == b.tokens && abs(a.timestamp.timeIntervalSince(b.timestamp)) <= 1
    }

    private static func tokens(in usage: [String: Any]) -> UsageTokenCounts? {
        let keys = ["inputOther", "output", "inputCacheRead", "inputCacheCreation"]
        guard keys.contains(where: { usage[$0] != nil }) else { return nil }
        var counts: [Int] = []
        for key in keys {
            guard let value = usage[key] else { counts.append(0); continue }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let count = number.doubleValue
            guard count.isFinite, count >= 0, count.rounded(.towardZero) == count,
                  count <= 9_007_199_254_740_991 else { return nil }
            counts.append(Int(count))
        }
        return UsageTokenCounts(input: counts[0], output: counts[1], cacheRead: counts[2], cacheWrite: counts[3])
    }
}
