import XCTest
@testable import Merlyn

private func makeConfig(kind: ProviderKind = .claude) -> ProviderConfig {
    ProviderConfig(id: "test", name: "Test", account: "A", kind: kind, dir: "~/.test")
}

final class LimitWindowTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(LimitWindow.name(seconds: nil), "5h", "no span defaults to the classic 5h")
        XCTAssertEqual(LimitWindow.name(seconds: 5 * 3600), "5h")
        XCTAssertEqual(LimitWindow.name(seconds: 24 * 3600), "24h")
        XCTAssertEqual(LimitWindow.name(seconds: 3 * 86_400), "3d")
        XCTAssertEqual(LimitWindow.name(seconds: 7 * 86_400), "Weekly")
        XCTAssertEqual(LimitWindow.name(seconds: 30 * 60), "30m")
    }

    func testWeeklyClassification() {
        XCTAssertFalse(LimitWindow.isWeekly(seconds: nil))
        XCTAssertFalse(LimitWindow.isWeekly(seconds: 5 * 3600))
        // A 3-day window is *classified* weekly (standing budget) but *named* "3d".
        XCTAssertTrue(LimitWindow.isWeekly(seconds: 3 * 86_400))
        XCTAssertTrue(LimitWindow.isWeekly(seconds: 7 * 86_400))
    }
}

final class WeeklyMetricTests: XCTestCase {
    func testDedupingLabels() {
        let metrics = [
            WeeklyMetric(label: "Rate limit", pct: 10, resetText: ""),
            WeeklyMetric(label: "Rate limit", pct: 20, resetText: ""),
            WeeklyMetric(label: "Weekly", pct: 30, resetText: ""),
        ]
        let deduped = WeeklyMetric.dedupingLabels(metrics)
        XCTAssertEqual(deduped.map(\.label), ["Rate limit", "Rate limit #2", "Weekly"])
        XCTAssertEqual(Set(deduped.map(\.id)).count, 3, "ids must be unique after dedupe")
    }
}

final class ProviderSnapshotTests: XCTestCase {
    func testRingWindowsPutSessionInnermost() {
        var snap = ProviderSnapshot.empty(makeConfig())
        snap.isEstimated = false
        snap.sessionPct = 30
        snap.sessionWindowSeconds = 5 * 3600
        snap.weekly = [WeeklyMetric(label: "All models", pct: 60, resetText: "")]
        let lanes = snap.ringWindows(maxLanes: 3)
        XCTAssertEqual(lanes.map(\.label), ["All models", "5h"], "rim → centre, session innermost")
    }

    func testRingWindowsWeeklyPrimaryTakesRim() {
        // Codex-style: the primary window *is* a 7-day budget.
        var snap = ProviderSnapshot.empty(makeConfig(kind: .codex))
        snap.isEstimated = false
        snap.sessionPct = 40
        snap.sessionWindowSeconds = 7 * 86_400
        snap.weekly = [WeeklyMetric(label: "Model · weekly", pct: 10, resetText: "")]
        let lanes = snap.ringWindows(maxLanes: 3)
        XCTAssertEqual(lanes.first?.label, "Weekly", "a standing-budget primary owns the rim")
    }

    func testEstimatesContributeOnlyPrimaryLane() {
        var snap = ProviderSnapshot.empty(makeConfig())
        snap.sessionPct = 20
        snap.weekly = [WeeklyMetric(label: "All models", pct: 90, resetText: "")]
        XCTAssertEqual(snap.ringWindows(maxLanes: 3).count, 1,
                       "estimated weekly ratios must not plot as lanes")
    }

    func testFailureClearsGaugesAndLanes() {
        let snap = ProviderSnapshot.failed(makeConfig(), .signedOut)
        XCTAssertTrue(snap.ringWindows(maxLanes: 3).isEmpty)
        XCTAssertTrue(snap.iconGauges.isEmpty)
        XCTAssertEqual(snap.mood, .dead)
        XCTAssertTrue(snap.needsSignIn)
    }

    func testIconGaugesPairSessionAndWorstWeekly() {
        var snap = ProviderSnapshot.empty(makeConfig())
        snap.isEstimated = false
        snap.sessionPct = 10
        snap.sessionWindowSeconds = 5 * 3600
        snap.weekly = [
            WeeklyMetric(label: "All models", pct: 40, resetText: ""),
            WeeklyMetric(label: "Fable only", pct: 70, resetText: ""),
        ]
        let gauges = snap.iconGauges
        XCTAssertEqual(gauges.map(\.window), ["5h", "wk"])
        XCTAssertEqual(gauges.last?.pct, 70, "the tightest weekly cap blocks first")
    }

    func testSingleLimitProviderDrawsOneBar() {
        var snap = ProviderSnapshot.empty(makeConfig(kind: .codex))
        snap.isEstimated = false
        snap.sessionPct = 25
        snap.sessionWindowSeconds = 7 * 86_400
        snap.weekly = []
        XCTAssertEqual(snap.iconGauges.count, 1, "never a padded pair")
        XCTAssertEqual(snap.iconGauges.first?.window, "wk")
    }

    func testBlockingLimitRequiresExhaustion() {
        var snap = ProviderSnapshot.empty(makeConfig())
        snap.isEstimated = false
        snap.sessionPct = 10
        snap.weekly = [WeeklyMetric(label: "All models", pct: 94, resetText: "")]
        XCTAssertNil(snap.blockingLimit, "94% is red but not blocking")
        snap.weekly = [WeeklyMetric(label: "All models", pct: 99.6, resetText: "")]
        XCTAssertEqual(snap.blockingLimit?.label, "All models")
    }

    func testPressureIgnoresEstimatedWeekly() {
        var snap = ProviderSnapshot.empty(makeConfig())
        snap.sessionPct = 10
        snap.weekly = [WeeklyMetric(label: "All models", pct: 100, resetText: "")]
        XCTAssertEqual(snap.pressurePct, 10,
                       "an estimated 'vs busiest week' 100% must not drive the mood")
    }

    func testLaneRankIsAlphabeticalAndPrimaryFirst() {
        var snap = ProviderSnapshot.empty(makeConfig())
        snap.isEstimated = false
        snap.sessionWindowSeconds = 5 * 3600
        snap.weekly = [
            WeeklyMetric(label: "Zeta", pct: 0, resetText: ""),
            WeeklyMetric(label: "Alpha", pct: 0, resetText: ""),
        ]
        XCTAssertEqual(snap.laneRank(of: "5h"), 0)
        XCTAssertEqual(snap.laneRank(of: "Alpha"), 1)
        XCTAssertEqual(snap.laneRank(of: "Zeta"), 2)
        XCTAssertEqual(snap.laneRank(of: "unknown"), 0)
    }
}

final class UsageFormattingTests: XCTestCase {
    func testDuration() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(UsageFormatting.duration(until: now.addingTimeInterval(-5), now: now), "now")
        XCTAssertEqual(UsageFormatting.duration(until: now.addingTimeInterval(125), now: now), "2m 5s")
        XCTAssertEqual(UsageFormatting.duration(until: now.addingTimeInterval(3 * 3600 + 120), now: now), "3h 2m")
        XCTAssertEqual(UsageFormatting.duration(until: now.addingTimeInterval(50 * 3600), now: now), "2d 2h")
    }

    func testBlockingText() {
        let now = Date(timeIntervalSince1970: 0)
        let maxed = WeeklyMetric(label: "All models", pct: 100, resetText: "")
        XCTAssertEqual(UsageFormatting.blockingText(maxed, now: now), "Weekly maxed")
        var withReset = maxed
        withReset.resetAt = now.addingTimeInterval(2 * 3600)
        XCTAssertEqual(UsageFormatting.blockingText(withReset, now: now), "Weekly in 2h 0m")
    }
}
