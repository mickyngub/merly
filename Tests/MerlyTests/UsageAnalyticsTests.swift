import Foundation
import XCTest
@testable import Merly

private let analyticsNow = Date(timeIntervalSince1970: 1_800_000_000)

private func analyticsRecord(
    id: String,
    at offset: TimeInterval = 0,
    sessionID: String,
    parentSessionID: String? = nil,
    agentID: String? = nil,
    agentName: String? = nil,
    project: String? = nil,
    model: String = "Unknown model",
    tokens: UsageTokenCounts = UsageTokenCounts(),
    activeSeconds: Double? = nil,
    linesAdded: Int? = nil,
    linesRemoved: Int? = nil
) -> UsageActivityRecord {
    UsageActivityRecord(
        id: id,
        timestamp: analyticsNow.addingTimeInterval(offset),
        sessionID: sessionID,
        parentSessionID: parentSessionID,
        agentID: agentID,
        agentName: agentName,
        project: project,
        model: model,
        tokens: tokens,
        activeSeconds: activeSeconds,
        linesAdded: linesAdded,
        linesRemoved: linesRemoved
    )
}

private func analyticsReport(
    _ records: [UsageActivityRecord],
    kind: String = "claude"
) -> ProviderUsageReport {
    let providerKind = ProviderKind(rawValue: kind) ?? .claude
    return ProviderUsageReport(
        identity: HistoryIdentity(config: ProviderConfig(
            id: "provider-a",
            name: "Provider",
            account: "A",
            kind: providerKind,
            dir: "/tmp/provider-a"
        )),
        loadedAt: analyticsNow,
        records: records
    )
}

final class UsageAnalyticsTests: XCTestCase {
    func testCacheAndReasoningSubsetsAreNotDoubleCounted() {
        var tokens = UsageTokenCounts(
            input: 100,
            output: 50,
            cacheRead: 20,
            cacheWrite: 30,
            cacheWrite1h: 10,
            reasoningOutput: 15
        )
        tokens.add(UsageTokenCounts(
            input: 200,
            output: 10,
            cacheRead: 40,
            cacheWrite: 5,
            cacheWrite1h: 2,
            reasoningOutput: 4
        ))

        XCTAssertEqual(tokens.input, 300)
        XCTAssertEqual(tokens.output, 60)
        XCTAssertEqual(tokens.cacheRead, 60)
        XCTAssertEqual(tokens.cacheWrite, 35)
        XCTAssertEqual(tokens.cacheWrite1h, 12)
        XCTAssertEqual(tokens.reasoningOutput, 19)
        XCTAssertEqual(tokens.inputTotal, 395)
        XCTAssertEqual(tokens.total, 455)
        XCTAssertEqual(tokens.cacheHitPct ?? 0, 60.0 / 395.0 * 100, accuracy: 0.000_001)

        var saturated = UsageTokenCounts(input: Int.max, output: -3, cacheWrite: Int.max)
        saturated.add(UsageTokenCounts(input: 1, output: 2, cacheWrite: 1))
        XCTAssertEqual(saturated.input, Int.max)
        XCTAssertEqual(saturated.output, 2)
        XCTAssertEqual(saturated.cacheWrite, Int.max)
        XCTAssertEqual(saturated.total, Int.max)
    }

    func testLatestSessionIncludesNestedSubagentsAndSeparatesOtherSessions() {
        let records = [
            analyticsRecord(
                id: "root-request",
                at: 0,
                sessionID: "root-session",
                project: "/work/first-project",
                tokens: UsageTokenCounts(input: 10)
            ),
            analyticsRecord(
                id: "child-request",
                at: 10,
                sessionID: "child-session",
                parentSessionID: "root-session",
                agentID: "agent-child",
                tokens: UsageTokenCounts(output: 20)
            ),
            analyticsRecord(
                id: "nested-request",
                at: 20,
                sessionID: "nested-session",
                parentSessionID: "child-session",
                agentID: "agent-nested",
                tokens: UsageTokenCounts(output: 30)
            ),
            analyticsRecord(
                id: "other-request",
                at: 30,
                sessionID: "other-session",
                project: "/work/other-project",
                tokens: UsageTokenCounts(output: 900)
            )
        ]
        let report = analyticsReport(records, kind: "kimi")

        let sessions = UsageAnalytics.sessions(
            in: report,
            now: analyticsNow.addingTimeInterval(30)
        )
        let summary = UsageAnalytics.summarize(
            report,
            range: .latest,
            sessionID: "root-session",
            now: analyticsNow.addingTimeInterval(30)
        )

        XCTAssertEqual(sessions.map(\.id), ["other-session", "root-session"])
        XCTAssertEqual(sessions.first(where: { $0.id == "root-session" })?.project, "/work/first-project")
        XCTAssertEqual(summary.sessionID, "root-session")
        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(summary.requestCount, 3)
        XCTAssertEqual(summary.tokens.total, 60)
        XCTAssertEqual(summary.firstActivity, analyticsNow)
        XCTAssertEqual(summary.lastActivity, analyticsNow.addingTimeInterval(20))
    }

    func testTimeRangesExcludeOldAndFutureRecords() {
        let records = [
            analyticsRecord(id: "ten-hours", at: -10 * 60 * 60, sessionID: "ten-hours", tokens: UsageTokenCounts(input: 1)),
            analyticsRecord(id: "two-days", at: -2 * 24 * 60 * 60, sessionID: "two-days", tokens: UsageTokenCounts(input: 2)),
            analyticsRecord(id: "ten-days", at: -10 * 24 * 60 * 60, sessionID: "ten-days", tokens: UsageTokenCounts(input: 4)),
            analyticsRecord(id: "thirty-one-days", at: -31 * 24 * 60 * 60, sessionID: "thirty-one-days", tokens: UsageTokenCounts(input: 8)),
            analyticsRecord(id: "future", at: 60, sessionID: "future", tokens: UsageTokenCounts(input: 16))
        ]
        let report = analyticsReport(records, kind: "kimi")

        let lastDay = UsageAnalytics.summarize(report, range: .hours24, now: analyticsNow)
        let lastWeek = UsageAnalytics.summarize(report, range: .days7, now: analyticsNow)
        let lastMonth = UsageAnalytics.summarize(report, range: .days30, now: analyticsNow)

        XCTAssertEqual(lastDay.tokens.total, 1)
        XCTAssertEqual(lastWeek.tokens.total, 3)
        XCTAssertEqual(lastMonth.tokens.total, 7)
        XCTAssertEqual(lastMonth.requestCount, 3)
    }

    func testRepeatedIDsReplaceRatherThanAdd() {
        let report = analyticsReport([
            analyticsRecord(id: "same-request", at: -120, sessionID: "session", tokens: UsageTokenCounts(input: 1)),
            analyticsRecord(id: "same-request", at: -60, sessionID: "session", tokens: UsageTokenCounts(input: 9)),
            analyticsRecord(id: "same-request", at: -60, sessionID: "session", tokens: UsageTokenCounts(output: 17))
        ], kind: "kimi")

        let summary = UsageAnalytics.summarize(report, range: .days30, now: analyticsNow)

        XCTAssertEqual(summary.requestCount, 1)
        XCTAssertEqual(summary.tokens.total, 17)
        XCTAssertEqual(summary.tokens.input, 0)
        XCTAssertEqual(summary.tokens.output, 17)
    }

    func testModelAndContributorSharesUseTokenTotals() {
        let report = analyticsReport([
            analyticsRecord(
                id: "main-one",
                sessionID: "root-one",
                model: "model-alpha",
                tokens: UsageTokenCounts(input: 20)
            ),
            analyticsRecord(
                id: "agent-one",
                at: 1,
                sessionID: "child-one",
                parentSessionID: "root-one",
                agentID: "worker",
                agentName: "Search agent",
                model: "model-beta",
                tokens: UsageTokenCounts(output: 30)
            ),
            analyticsRecord(
                id: "main-two",
                at: 2,
                sessionID: "root-two",
                model: "model-alpha",
                tokens: UsageTokenCounts(output: 50)
            )
        ], kind: "kimi")

        let summary = UsageAnalytics.summarize(report, range: .days30, now: analyticsNow.addingTimeInterval(2))

        XCTAssertEqual(summary.tokens.total, 100)
        XCTAssertEqual(summary.models.map(\.id), ["model-alpha", "model-beta"])
        XCTAssertEqual(summary.models.map(\.sharePct), [70, 30])
        XCTAssertEqual(summary.models.map(\.requestCount), [2, 1])
        XCTAssertEqual(summary.contributors.map(\.id), [
            "session:root-two", "agent:child-one:worker", "session:root-one"
        ])
        XCTAssertEqual(summary.contributors.map(\.sharePct), [50, 30, 20])
        XCTAssertEqual(summary.contributors[1].label, "Search agent")
    }

    func testMissingMetricsRemainUnavailableAndObservedMetricsSum() {
        let tokenOnly = analyticsReport([
            analyticsRecord(id: "token", sessionID: "root", tokens: UsageTokenCounts(input: 1))
        ], kind: "kimi")
        let unavailable = UsageAnalytics.summarize(tokenOnly, range: .days30, now: analyticsNow)
        XCTAssertNil(unavailable.recordedActiveSeconds)
        XCTAssertNil(unavailable.linesAdded)
        XCTAssertNil(unavailable.linesRemoved)

        let measured = analyticsReport([
            analyticsRecord(id: "token", sessionID: "root", tokens: UsageTokenCounts(input: 1)),
            analyticsRecord(
                id: "metric-one",
                at: 1,
                sessionID: "root",
                activeSeconds: 2.5,
                linesAdded: 3,
                linesRemoved: 1
            ),
            analyticsRecord(
                id: "metric-two",
                at: 2,
                sessionID: "root",
                activeSeconds: 2,
                linesAdded: 4,
                linesRemoved: 5
            ),
            analyticsRecord(
                id: "invalid-metric",
                at: 3,
                sessionID: "root",
                activeSeconds: .infinity,
                linesAdded: -5,
                linesRemoved: -1
            )
        ], kind: "kimi")
        let summary = UsageAnalytics.summarize(
            measured,
            range: .days30,
            now: analyticsNow.addingTimeInterval(3)
        )

        XCTAssertEqual(summary.recordedActiveSeconds, 4.5)
        XCTAssertEqual(summary.linesAdded, 7)
        XCTAssertEqual(summary.linesRemoved, 6)
        XCTAssertEqual(summary.requestCount, 1)
    }

    func testCyclesAndUnknownParentsDoNotHang() {
        let report = analyticsReport([
            analyticsRecord(id: "cycle-a", sessionID: "cycle-a", parentSessionID: "cycle-b", tokens: UsageTokenCounts(input: 1)),
            analyticsRecord(id: "cycle-b", sessionID: "cycle-b", parentSessionID: "cycle-a", tokens: UsageTokenCounts(input: 2)),
            analyticsRecord(id: "unknown-child", sessionID: "unknown-child", parentSessionID: "missing-root", tokens: UsageTokenCounts(input: 4)),
            analyticsRecord(id: "metric-only", sessionID: "missing-root", parentSessionID: "absent-ancestor")
        ], kind: "kimi")

        let sessions = UsageAnalytics.sessions(in: report, now: analyticsNow)
        let summary = UsageAnalytics.summarize(
            report,
            range: .days30,
            now: analyticsNow.addingTimeInterval(2)
        )

        XCTAssertEqual(Set(sessions.map(\.id)), ["cycle-a", "cycle-b", "absent-ancestor"])
        XCTAssertEqual(summary.sessionCount, 3)
        XCTAssertEqual(summary.tokens.total, 7)
    }

    func testKnownPricingAndUnpricedModelsStayExplicit() {
        let report = analyticsReport([
            analyticsRecord(
                id: "known",
                sessionID: "root",
                model: "claude-opus-5-5",
                tokens: UsageTokenCounts(input: 1_000_000)
            ),
            analyticsRecord(
                id: "unknown",
                at: 1,
                sessionID: "root",
                model: "claude-opus-5-4",
                tokens: UsageTokenCounts(input: 2)
            )
        ])

        let summary = UsageAnalytics.summarize(
            report,
            range: .days30,
            now: analyticsNow.addingTimeInterval(1)
        )

        XCTAssertEqual(summary.estimatedValueUSD, 4)
        XCTAssertEqual(summary.unpricedRequestCount, 1)
    }

    func testEmptyLatestDoesNotInventASession() {
        let report = analyticsReport([
            analyticsRecord(
                id: "metrics-only",
                sessionID: "session-without-tokens",
                project: "/work/no-token-session",
                activeSeconds: 12,
                linesAdded: 10
            )
        ], kind: "kimi")

        let summary = UsageAnalytics.summarize(report, range: .latest, now: analyticsNow)

        XCTAssertEqual(UsageAnalytics.sessions(in: report, now: analyticsNow), [])
        XCTAssertEqual(summary.tokens.total, 0)
        XCTAssertEqual(summary.requestCount, 0)
        XCTAssertEqual(summary.sessionCount, 0)
        XCTAssertNil(summary.sessionID)
        XCTAssertNil(summary.firstActivity)
        XCTAssertNil(summary.recordedActiveSeconds)
        XCTAssertNil(summary.linesAdded)
    }
}
