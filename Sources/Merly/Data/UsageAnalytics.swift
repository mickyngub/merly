import Foundation

private func saturatedNonnegativeSum(_ lhs: Int, _ rhs: Int) -> Int {
    let left = max(0, lhs)
    let right = max(0, rhs)
    let (sum, overflow) = left.addingReportingOverflow(right)
    return overflow ? Int.max : sum
}

struct UsageTokenCounts: Equatable, Sendable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var cacheWrite1h: Int = 0
    var reasoningOutput: Int = 0

    var inputTotal: Int {
        saturatedNonnegativeSum(
            saturatedNonnegativeSum(input, cacheRead),
            cacheWrite
        )
    }

    var total: Int {
        saturatedNonnegativeSum(inputTotal, output)
    }

    var cacheHitPct: Double? {
        guard inputTotal > 0 else { return nil }
        return Double(max(0, cacheRead)) / Double(inputTotal) * 100
    }

    mutating func add(_ other: Self) {
        input = saturatedNonnegativeSum(input, other.input)
        output = saturatedNonnegativeSum(output, other.output)
        cacheRead = saturatedNonnegativeSum(cacheRead, other.cacheRead)
        cacheWrite = saturatedNonnegativeSum(cacheWrite, other.cacheWrite)
        cacheWrite1h = saturatedNonnegativeSum(cacheWrite1h, other.cacheWrite1h)
        reasoningOutput = saturatedNonnegativeSum(reasoningOutput, other.reasoningOutput)
    }
}

struct UsageActivityRecord: Equatable, Sendable {
    var id: String
    var timestamp: Date
    var sessionID: String
    var parentSessionID: String? = nil
    var agentID: String? = nil
    var agentName: String? = nil
    var project: String? = nil
    var model: String = "Unknown model"
    var tokens: UsageTokenCounts = UsageTokenCounts()
    var activeSeconds: Double? = nil
    var linesAdded: Int? = nil
    var linesRemoved: Int? = nil
}

struct ProviderUsageReport: Equatable {
    var identity: HistoryIdentity
    var loadedAt: Date
    var records: [UsageActivityRecord]
    var warnings: [String] = []
}

enum UsageAnalyticsRange: String, CaseIterable, Identifiable, Sendable {
    case latest = "Latest session"
    case hours24 = "24h"
    case days7 = "7d"
    case days30 = "30d"

    var id: String { rawValue }
}

struct UsageSessionSummary: Identifiable, Equatable, Sendable {
    var id: String
    var project: String?
    var lastActivity: Date
    var firstActivity: Date

    var displayName: String {
        let projectName = project.map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Session"
        return "\(projectName) · \(String(id.prefix(8)))"
    }
}

struct UsageBreakdown: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var tokens: UsageTokenCounts
    var requestCount: Int
    var sharePct: Double
}

struct UsageAnalyticsSummary: Equatable, Sendable {
    var tokens: UsageTokenCounts
    var requestCount: Int
    var sessionCount: Int
    var firstActivity: Date?
    var lastActivity: Date?
    var recordedActiveSeconds: Double?
    var linesAdded: Int?
    var linesRemoved: Int?
    var estimatedValueUSD: Double?
    var unpricedRequestCount: Int
    var models: [UsageBreakdown]
    var contributors: [UsageBreakdown]
    var sessionID: String?
}

enum UsageAnalytics {
    private struct BreakdownAccumulator {
        var tokens = UsageTokenCounts()
        var requestCount = 0
        var explicitLabel: String?
        var fallbackLabel: String

        init(fallbackLabel: String, explicitLabel: String?) {
            self.fallbackLabel = fallbackLabel
            self.explicitLabel = explicitLabel
        }

        var label: String { explicitLabel ?? fallbackLabel }
    }

    static func sessions(in report: ProviderUsageReport, now: Date) -> [UsageSessionSummary] {
        let records = retainedRecords(in: report, now: now)
        let parents = parentMap(for: records)
        return sessionSummaries(records: records, parents: parents)
    }

    static func summarize(
        _ report: ProviderUsageReport,
        range: UsageAnalyticsRange,
        sessionID: String? = nil,
        now: Date
    ) -> UsageAnalyticsSummary {
        let retained = retainedRecords(in: report, now: now)
        let parents = parentMap(for: retained)
        let chosenRecords: [UsageActivityRecord]
        let chosenSessionID: String?

        switch range {
        case .latest:
            let available = sessionSummaries(records: retained, parents: parents)
            guard !available.isEmpty else { return emptySummary() }
            let selected = sessionID.flatMap { selectedID in
                available.first(where: { $0.id == selectedID })
            } ?? available[0]
            chosenSessionID = selected.id
            chosenRecords = retained.filter {
                rootSessionID(for: $0.sessionID, parents: parents) == selected.id
            }
        case .hours24, .days7, .days30:
            let duration: TimeInterval
            switch range {
            case .hours24: duration = 24 * 60 * 60
            case .days7: duration = 7 * 24 * 60 * 60
            case .days30: duration = 30 * 24 * 60 * 60
            case .latest: duration = 0
            }
            let start = now.addingTimeInterval(-duration)
            chosenSessionID = nil
            chosenRecords = retained.filter { $0.timestamp >= start && $0.timestamp <= now }
        }

        return makeSummary(
            records: chronologicallySorted(chosenRecords),
            parents: parents,
            identity: report.identity,
            sessionID: chosenSessionID
        )
    }

    private static func retainedRecords(
        in report: ProviderUsageReport,
        now: Date
    ) -> [UsageActivityRecord] {
        var records: [UsageActivityRecord] = []
        var recordIndexByID: [String: Int] = [:]

        for record in report.records {
            if let index = recordIndexByID[record.id] {
                if record.timestamp >= records[index].timestamp {
                    records[index] = record
                }
            } else {
                recordIndexByID[record.id] = records.count
                records.append(record)
            }
        }

        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        return records.filter { $0.timestamp >= cutoff && $0.timestamp <= now }
    }

    private static func parentMap(for records: [UsageActivityRecord]) -> [String: String] {
        var parents: [String: String] = [:]
        for record in records {
            guard let parent = record.parentSessionID,
                  !parent.isEmpty,
                  parent != record.sessionID
            else { continue }
            if parents[record.sessionID] == nil {
                parents[record.sessionID] = parent
            }
        }
        return parents
    }

    private static func rootSessionID(
        for start: String,
        parents: [String: String]
    ) -> String {
        var current = start
        var visited: Set<String> = []
        while true {
            guard visited.insert(current).inserted else { return start }
            guard let parent = parents[current] else { return current }
            current = parent
        }
    }

    private static func sessionSummaries(
        records: [UsageActivityRecord],
        parents: [String: String]
    ) -> [UsageSessionSummary] {
        var groups: [String: [UsageActivityRecord]] = [:]
        for record in records {
            let root = rootSessionID(for: record.sessionID, parents: parents)
            groups[root, default: []].append(record)
        }

        return groups.compactMap { entry -> UsageSessionSummary? in
            let root = entry.key
            let group = entry.value
            guard group.contains(where: { $0.tokens.total > 0 }) else { return nil }
            let ordered = chronologicallySorted(group)
            let rootProject = ordered.first(where: {
                $0.sessionID == root && $0.project != nil
            })?.project
            let project = rootProject ?? ordered.first(where: { $0.project != nil })?.project
            guard let first = ordered.first, let last = ordered.last else { return nil }
            return UsageSessionSummary(
                id: root,
                project: project,
                lastActivity: last.timestamp,
                firstActivity: first.timestamp
            )
        }.sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
            return lhs.id < rhs.id
        }
    }

    private static func makeSummary(
        records: [UsageActivityRecord],
        parents: [String: String],
        identity: HistoryIdentity,
        sessionID: String?
    ) -> UsageAnalyticsSummary {
        var tokens = UsageTokenCounts()
        var requestCount = 0
        var rootsWithTokens: Set<String> = []
        var activeSeconds = 0.0
        var hasActiveSeconds = false
        var linesAdded = 0
        var hasLinesAdded = false
        var linesRemoved = 0
        var hasLinesRemoved = false

        for record in records {
            tokens.add(record.tokens)
            guard record.tokens.total > 0 else { continue }
            requestCount += 1
            rootsWithTokens.insert(rootSessionID(for: record.sessionID, parents: parents))
        }

        for record in records {
            if let value = record.activeSeconds, value.isFinite, value >= 0 {
                activeSeconds += value
                hasActiveSeconds = true
            }
            if let value = record.linesAdded, value >= 0 {
                linesAdded = saturatedNonnegativeSum(linesAdded, value)
                hasLinesAdded = true
            }
            if let value = record.linesRemoved, value >= 0 {
                linesRemoved = saturatedNonnegativeSum(linesRemoved, value)
                hasLinesRemoved = true
            }
        }

        let modelRows = breakdowns(
            records: records,
            denominator: tokens.total,
            keyAndLabel: { record in (record.model, record.model) },
            explicitLabel: { _ in nil }
        )
        let contributorRows = breakdowns(
            records: records,
            denominator: tokens.total,
            keyAndLabel: contributorIdentity,
            explicitLabel: { $0.agentName }
        )
        let pricing = estimateValue(for: records, identity: identity)
        let dates = records.map(\.timestamp)

        return UsageAnalyticsSummary(
            tokens: tokens,
            requestCount: requestCount,
            sessionCount: rootsWithTokens.count,
            firstActivity: dates.min(),
            lastActivity: dates.max(),
            recordedActiveSeconds: hasActiveSeconds ? activeSeconds : nil,
            linesAdded: hasLinesAdded ? linesAdded : nil,
            linesRemoved: hasLinesRemoved ? linesRemoved : nil,
            estimatedValueUSD: pricing.value,
            unpricedRequestCount: pricing.unpricedRequestCount,
            models: modelRows,
            contributors: contributorRows,
            sessionID: sessionID
        )
    }

    private static func breakdowns(
        records: [UsageActivityRecord],
        denominator: Int,
        keyAndLabel: (UsageActivityRecord) -> (key: String, label: String),
        explicitLabel: (UsageActivityRecord) -> String?
    ) -> [UsageBreakdown] {
        var order: [String] = []
        var accumulators: [String: BreakdownAccumulator] = [:]

        for record in records where record.tokens.total > 0 {
            let identity = keyAndLabel(record)
            var accumulator = accumulators[identity.key] ?? BreakdownAccumulator(
                fallbackLabel: identity.label,
                explicitLabel: nil
            )
            if accumulator.explicitLabel == nil,
               let explicit = explicitLabel(record),
               !explicit.isEmpty {
                accumulator.explicitLabel = explicit
            }
            accumulator.tokens.add(record.tokens)
            accumulator.requestCount += 1
            if accumulators[identity.key] == nil { order.append(identity.key) }
            accumulators[identity.key] = accumulator
        }

        return order.compactMap { key in
            guard let accumulator = accumulators[key] else { return nil }
            let share = denominator > 0
                ? Double(accumulator.tokens.total) / Double(denominator) * 100
                : 0
            return UsageBreakdown(
                id: key,
                label: accumulator.label,
                tokens: accumulator.tokens,
                requestCount: accumulator.requestCount,
                sharePct: share
            )
        }.sorted { lhs, rhs in
            if lhs.tokens.total != rhs.tokens.total { return lhs.tokens.total > rhs.tokens.total }
            if lhs.label != rhs.label { return lhs.label < rhs.label }
            return lhs.id < rhs.id
        }
    }

    private static func contributorIdentity(
        _ record: UsageActivityRecord
    ) -> (key: String, label: String) {
        if let agentID = record.agentID {
            let fallback = "Subagent \(String(agentID.prefix(8)))"
            return ("agent:\(record.sessionID):\(agentID)", fallback)
        }

        let isSubagent = record.parentSessionID != nil
        let fallback: String
        if isSubagent {
            fallback = "Subagent \(String(record.sessionID.prefix(8)))"
        } else {
            fallback = "Main session \(String(record.sessionID.prefix(8)))"
        }
        return ("session:\(record.sessionID)", fallback)
    }

    private static func estimateValue(
        for records: [UsageActivityRecord],
        identity: HistoryIdentity
    ) -> (value: Double?, unpricedRequestCount: Int) {
        let kind = ProviderKind(rawValue: identity.kind)
        var value = 0.0
        var hasPricedRequest = false
        var unpricedRequestCount = 0

        for record in records where record.tokens.total > 0 {
            guard let kind,
                  let estimate = UsagePricing.estimateUSD(
                    kind: kind,
                    model: record.model,
                    input: record.tokens.input,
                    output: record.tokens.output,
                    cacheRead: record.tokens.cacheRead,
                    cacheWrite: record.tokens.cacheWrite,
                    cacheWrite1h: record.tokens.cacheWrite1h
                  )
            else {
                unpricedRequestCount += 1
                continue
            }
            value += estimate
            hasPricedRequest = true
        }

        return (hasPricedRequest ? value : nil, unpricedRequestCount)
    }

    private static func chronologicallySorted(
        _ records: [UsageActivityRecord]
    ) -> [UsageActivityRecord] {
        records.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp < rhs.element.timestamp
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func emptySummary() -> UsageAnalyticsSummary {
        UsageAnalyticsSummary(
            tokens: UsageTokenCounts(),
            requestCount: 0,
            sessionCount: 0,
            firstActivity: nil,
            lastActivity: nil,
            recordedActiveSeconds: nil,
            linesAdded: nil,
            linesRemoved: nil,
            estimatedValueUSD: nil,
            unpricedRequestCount: 0,
            models: [],
            contributors: [],
            sessionID: nil
        )
    }
}
