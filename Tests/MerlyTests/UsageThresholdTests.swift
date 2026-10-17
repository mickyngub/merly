import XCTest
@testable import Merly

final class UsageThresholdTests: XCTestCase {
    private func identity(_ directory: String = "/tmp/merly-threshold-a") -> HistoryIdentity {
        HistoryIdentity(config: ProviderConfig(
            id: "provider", name: "Test", account: "", kind: .codex, dir: directory
        ))
    }

    func testStartupAboveThresholdStaysSilentUntilAnotherCrossing() {
        var state = UsageThresholdState()
        let key = identity()
        for pressure in [90.0, 90, 70] {
            XCTAssertFalse(state.observe(identity: key, pressure: pressure, threshold: 80, enabled: true))
        }
        XCTAssertTrue(state.observe(identity: key, pressure: 90, threshold: 80, enabled: true))
        XCTAssertFalse(state.observe(identity: key, pressure: 95, threshold: 80, enabled: true))
    }

    func testDisabledAlertsStillTrackPressureWithoutDelayedNotification() {
        var state = UsageThresholdState()
        let key = identity()
        XCTAssertFalse(state.observe(identity: key, pressure: 70, threshold: 80, enabled: false))
        XCTAssertFalse(state.observe(identity: key, pressure: 90, threshold: 80, enabled: false))
        XCTAssertFalse(state.observe(identity: key, pressure: 90, threshold: 80, enabled: true))
        XCTAssertFalse(state.observe(identity: key, pressure: 70, threshold: 80, enabled: true))
        XCTAssertTrue(state.observe(identity: key, pressure: 80, threshold: 80, enabled: true))
    }

    func testDifferentAccountWithSameProviderIDSeedsIndependently() {
        var state = UsageThresholdState()
        XCTAssertFalse(state.observe(identity: identity(), pressure: 20, threshold: 80, enabled: true))
        let changed = identity("/tmp/merly-threshold-b")
        XCTAssertFalse(state.observe(identity: changed, pressure: 90, threshold: 80, enabled: true))
        XCTAssertFalse(state.observe(identity: changed, pressure: 90, threshold: 80, enabled: true))
    }
}
