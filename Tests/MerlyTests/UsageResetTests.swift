import XCTest
@testable import Merly

final class UsageResetTests: XCTestCase {
    private let resetAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func config() -> ProviderConfig {
        ProviderConfig(
            id: "provider", name: "Test", account: "A", kind: .codex,
            dir: "/fixtures/merly-reset-a"
        )
    }

    private func snapshot(
        _ config: ProviderConfig, pct: Double, resetAt: Date? = nil,
        weekly: [WeeklyMetric] = [], estimated: Bool = false
    ) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot.empty(config)
        snapshot.sessionPct = pct
        snapshot.sessionResetAt = resetAt
        snapshot.weekly = weekly
        snapshot.isEstimated = estimated
        return snapshot
    }

    func testRealRolloverEmitsOnceAfterSilentFirstReading() {
        var state = UsageResetState()
        let provider = config()
        let busy = snapshot(provider, pct: 80, resetAt: resetAt)
        let fresh = snapshot(provider, pct: 0, resetAt: resetAt.addingTimeInterval(18_000))

        XCTAssertEqual(state.observe(snapshot: busy, enabled: true), [])
        XCTAssertEqual(state.observe(snapshot: fresh, enabled: true), ["5h"])
        XCTAssertEqual(state.observe(snapshot: fresh, enabled: true), [])
    }

    func testDirectoryOrKindChangeWithSameProviderIDSeedsIndependently() {
        let original = config()
        var changedDirectory = original
        changedDirectory.dir = "/fixtures/merly-reset-b"
        var changedKind = original
        changedKind.kind = .claude

        for changed in [changedDirectory, changedKind] {
            var state = UsageResetState()
            XCTAssertEqual(state.observe(
                snapshot: snapshot(original, pct: 80, resetAt: resetAt), enabled: true
            ), [])
            let firstReading = snapshot(changed, pct: 0, resetAt: resetAt.addingTimeInterval(18_000))
            XCTAssertEqual(state.observe(snapshot: firstReading, enabled: true), [])
        }
    }

    func testMetadataRenameRetainsBaselineForRealRollover() {
        var state = UsageResetState()
        let original = config()
        var renamed = original
        renamed.name = "Renamed"
        renamed.account = "Work"

        XCTAssertEqual(state.observe(
            snapshot: snapshot(original, pct: 80, resetAt: resetAt), enabled: true
        ), [])
        XCTAssertEqual(state.observe(
            snapshot: snapshot(renamed, pct: 0, resetAt: resetAt.addingTimeInterval(18_000)), enabled: true
        ), ["5h"])
    }

    func testEquivalentDirectoryRetainsBaselineForRealRollover() {
        var state = UsageResetState()
        let original = config()
        var normalized = original
        normalized.dir += "/nested/.."

        XCTAssertEqual(state.observe(
            snapshot: snapshot(original, pct: 80, resetAt: resetAt), enabled: true
        ), [])
        XCTAssertEqual(state.observe(
            snapshot: snapshot(normalized, pct: 0, resetAt: resetAt.addingTimeInterval(18_000)), enabled: true
        ), ["5h"])
    }

    func testDisabledReadingsUpdateBaselineWithoutDelayedNotification() {
        var state = UsageResetState()
        let provider = config()
        let busy = snapshot(provider, pct: 80, resetAt: resetAt)
        let fresh = snapshot(provider, pct: 0, resetAt: resetAt.addingTimeInterval(18_000))

        XCTAssertEqual(state.observe(snapshot: busy, enabled: false), [])
        XCTAssertEqual(state.observe(snapshot: busy, enabled: true), [])
        XCTAssertEqual(state.observe(snapshot: fresh, enabled: false), [])
        XCTAssertEqual(state.observe(snapshot: fresh, enabled: true), [])
    }

    func testUnavailableReadingRetainsBaseline() {
        var state = UsageResetState()
        let provider = config()

        XCTAssertEqual(state.observe(
            snapshot: snapshot(provider, pct: 80, resetAt: resetAt), enabled: true
        ), [])
        XCTAssertEqual(state.observe(snapshot: .failed(provider, .offline), enabled: true), [])
        XCTAssertEqual(state.observe(
            snapshot: snapshot(provider, pct: 0, resetAt: resetAt.addingTimeInterval(18_000)), enabled: true
        ), ["5h"])
    }

    func testEstimatedReadingIgnoresSecondaryWindows() {
        var state = UsageResetState()
        let provider = config()
        let busy = snapshot(
            provider, pct: 80,
            weekly: [WeeklyMetric(label: "Weekly", pct: 90, resetText: "")], estimated: true
        )
        let fresh = snapshot(
            provider, pct: 0,
            weekly: [WeeklyMetric(label: "Weekly", pct: 0, resetText: "")], estimated: true
        )

        XCTAssertEqual(state.observe(snapshot: busy, enabled: true), [])
        XCTAssertEqual(state.observe(snapshot: fresh, enabled: true), ["5h"])
    }

    func testRealReadingReturnsAllResetWindowsInSortedOrder() {
        var state = UsageResetState()
        let provider = config()
        let busy = snapshot(provider, pct: 80, weekly: [
            WeeklyMetric(label: "Weekly", pct: 90, resetText: ""),
            WeeklyMetric(label: "Daily", pct: 70, resetText: "")
        ])
        let fresh = snapshot(provider, pct: 0, weekly: [
            WeeklyMetric(label: "Weekly", pct: 0, resetText: ""),
            WeeklyMetric(label: "Daily", pct: 0, resetText: "")
        ])

        XCTAssertEqual(state.observe(snapshot: busy, enabled: true), [])
        XCTAssertEqual(state.observe(snapshot: fresh, enabled: true), ["5h", "Daily", "Weekly"])
    }

    func testResetDetectionPreservesPressureAndTimestampBoundaries() {
        let provider = config()
        let cases: [(before: Double, after: Double, jump: TimeInterval?, expected: [String])] = [
            (49, 0, nil, []),
            (50, 10, nil, ["5h"]),
            (80, 11, nil, []),
            (80, 0, 599, []),
            (80, 79, 600, ["5h"]),
            (80, 80, 600, [])
        ]

        for test in cases {
            var state = UsageResetState()
            let beforeReset = test.jump == nil ? nil : resetAt
            let afterReset = test.jump.map { resetAt.addingTimeInterval($0) }
            XCTAssertEqual(state.observe(
                snapshot: snapshot(provider, pct: test.before, resetAt: beforeReset), enabled: true
            ), [])
            XCTAssertEqual(state.observe(
                snapshot: snapshot(provider, pct: test.after, resetAt: afterReset), enabled: true
            ), test.expected)
        }
    }
}
