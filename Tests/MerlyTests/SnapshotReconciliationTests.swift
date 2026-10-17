import XCTest
@testable import Merly

private func reconciliationConfig(_ id: String) -> ProviderConfig {
    ProviderConfig(id: id, name: id, account: "A", kind: .claude, dir: "/fixtures/\(id)")
}

private func reconciliationSnapshot(_ config: ProviderConfig, pct: Double) -> ProviderSnapshot {
    var snapshot = ProviderSnapshot.empty(config)
    snapshot.sessionPct = pct
    snapshot.isEstimated = false
    return snapshot
}

final class SnapshotReconciliationTests: XCTestCase {
    func testInflightResultKeepsLiveMetadataAndFreshReading() {
        let original = reconciliationConfig("claude")
        var edited = original
        edited.name = "Renamed"
        edited.account = "Work"
        edited.style = .catTie
        edited.colorSlot = 4
        edited.sprite = "merly-sprite"

        let snapshots = UsageEngine.reconciledSnapshots(
            providers: [edited],
            results: [reconciliationSnapshot(original, pct: 80)],
            current: [reconciliationSnapshot(edited, pct: 20)]
        )

        XCTAssertEqual(snapshots.map(\.config), [edited])
        XCTAssertEqual(snapshots.map(\.sessionPct), [80])
    }

    func testReorderDeletionAndAdditionFollowLiveProviders() {
        let first = reconciliationConfig("first")
        let removed = reconciliationConfig("removed")
        let added = reconciliationConfig("added")
        let unread = reconciliationConfig("unread")

        let snapshots = UsageEngine.reconciledSnapshots(
            providers: [added, first, unread],
            results: [
                reconciliationSnapshot(first, pct: 80),
                reconciliationSnapshot(removed, pct: 90)
            ],
            current: [
                reconciliationSnapshot(first, pct: 20),
                reconciliationSnapshot(added, pct: 40)
            ]
        )

        XCTAssertEqual(snapshots.map(\.id), ["added", "first", "unread"])
        XCTAssertEqual(snapshots.map(\.sessionPct), [40, 80, 0])
        XCTAssertEqual(snapshots.last, .empty(unread))
    }

    func testChangedIdentityRejectsInflightResultAndKeepsMatchingCurrent() {
        let original = reconciliationConfig("provider")
        var changedKind = original
        changedKind.kind = .codex
        var changedDirectory = original
        changedDirectory.dir = "/fixtures/other"

        for live in [changedKind, changedDirectory] {
            let current = reconciliationSnapshot(live, pct: 25)
            let snapshots = UsageEngine.reconciledSnapshots(
                providers: [live],
                results: [reconciliationSnapshot(original, pct: 90)],
                current: [current]
            )

            XCTAssertEqual(snapshots, [current])
        }
    }

    func testChangedIdentityWithoutMatchingReadingBecomesEmpty() {
        let original = reconciliationConfig("provider")
        var live = original
        live.dir = "/fixtures/other"

        let snapshots = UsageEngine.reconciledSnapshots(
            providers: [live],
            results: [reconciliationSnapshot(original, pct: 90)],
            current: [reconciliationSnapshot(original, pct: 80)]
        )

        XCTAssertEqual(snapshots, [.empty(live)])
    }

    func testMetadataEditWithoutFreshResultKeepsCurrentReading() {
        let original = reconciliationConfig("provider")
        var live = original
        live.name = "Renamed"

        let snapshots = UsageEngine.reconciledSnapshots(
            providers: [live],
            results: [],
            current: [reconciliationSnapshot(original, pct: 80)]
        )

        XCTAssertEqual(snapshots.map(\.config), [live])
        XCTAssertEqual(snapshots.map(\.sessionPct), [80])
    }
}
