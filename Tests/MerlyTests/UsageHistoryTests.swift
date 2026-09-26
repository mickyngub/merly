import Foundation
import XCTest
@testable import Merly

private func historyTestConfig(
    id: String = "claude-a",
    kind: ProviderKind = .claude,
    dir: String = "~/.claude-a",
    name: String = "Claude",
    account: String = "A"
) -> ProviderConfig {
    ProviderConfig(id: id, name: name, account: account, kind: kind, dir: dir)
}

private func historyTestSnapshot(
    _ config: ProviderConfig,
    pct: Double = 40,
    estimated: Bool = false,
    stale: Bool = false,
    failure: ProviderFailure? = nil,
    weekly: [WeeklyMetric] = []
) -> ProviderSnapshot {
    ProviderSnapshot(
        config: config,
        sessionPct: pct,
        sessionResetAt: nil,
        weekly: weekly,
        isActive: false,
        isEstimated: estimated,
        sessionWindowSeconds: 5 * 60 * 60,
        isStale: stale,
        failure: failure
    )
}

private func historyTestSample(
    identity: HistoryIdentity,
    timestamp: Date,
    pct: Double,
    resetAt: Date? = nil,
    durationSeconds: Double? = 18_000,
    includePrimary: Bool = true
) -> UsageHistorySample {
    UsageHistorySample(
        identity: identity,
        timestamp: timestamp,
        windows: includePrimary ? [UsageHistoryWindow(
            id: "primary", label: "5h", pct: pct,
            resetAt: resetAt, durationSeconds: durationSeconds
        )] : []
    )
}

private func historyTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MerlyUsageHistoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

final class UsageHistoryTests: XCTestCase {
    func testFreshReadingsPersistAcrossRestartAndAccountsStaySeparate() throws {
        let directory = try historyTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage-history.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let configs = [
            historyTestConfig(id: "claude-personal", dir: "~/.claude"),
            historyTestConfig(id: "claude-work", dir: "~/.claude-work", account: "Work")
        ]

        let firstRun = UsageHistoryStore(url: url)
        firstRun.record(snapshots: configs.map { historyTestSnapshot($0) }, now: now)
        XCTAssertEqual(firstRun.samples.count, 2)
        XCTAssertEqual(Set(firstRun.samples.map(\.identity.providerID)), ["claude-personal", "claude-work"])

        let restarted = UsageHistoryStore(url: url)
        restarted.record(snapshots: [], now: now.addingTimeInterval(60))
        XCTAssertEqual(restarted.samples, firstRun.samples)
    }

    func testEstimatesStaleAndFailuresAreExcluded() throws {
        let directory = try historyTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageHistoryStore(url: directory.appendingPathComponent("history.json"))
        let config = historyTestConfig()
        let snapshots = [
            historyTestSnapshot(config, estimated: true),
            historyTestSnapshot(config, stale: true),
            historyTestSnapshot(config, failure: .offline)
        ]

        store.record(snapshots: snapshots, now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertTrue(store.samples.isEmpty)
    }

    func testFiveMinuteBucketsKeepLatestAndRetentionPrunes() throws {
        let directory = try historyTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = UsageHistoryStore(url: url)
        let config = historyTestConfig()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        store.record(snapshots: [historyTestSnapshot(config, pct: 10)], now: now)
        store.record(snapshots: [historyTestSnapshot(config, pct: 25)], now: now.addingTimeInterval(120))
        store.record(snapshots: [historyTestSnapshot(config, pct: 60)], now: now.addingTimeInterval(301))

        XCTAssertEqual(store.samples.count, 2)
        XCTAssertEqual(store.samples[0].windows.first?.pct, 25)
        XCTAssertEqual(store.samples[1].windows.first?.pct, 60)

        let later = now.addingTimeInterval(30 * 24 * 60 * 60 + 302)
        store.record(snapshots: [historyTestSnapshot(config, pct: 70)], now: later)
        XCTAssertEqual(store.samples.count, 1)
        XCTAssertEqual(store.samples.first?.timestamp, later)

        store.record(snapshots: [historyTestSnapshot(config, pct: 80)], now: later.addingTimeInterval(3_600))
        let afterClockRollback = UsageHistoryStore(url: url)
        afterClockRollback.record(snapshots: [historyTestSnapshot(config, pct: 90)], now: later)
        XCTAssertEqual(afterClockRollback.samples.count, 1)
        XCTAssertEqual(afterClockRollback.samples.first?.windows.first?.pct, 90)
    }

    func testIdentityChangesSeparateHistoryButRenamePreservesIt() throws {
        let directory = try historyTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageHistoryStore(url: directory.appendingPathComponent("history.json"))
        let original = historyTestConfig()
        let renamed = historyTestConfig(name: "Renamed Claude", account: "Personal")
        let moved = historyTestConfig(dir: "~/.claude-moved")
        let changedKind = historyTestConfig(kind: .codex)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        store.record(
            snapshots: [original, renamed, moved, changedKind].map { historyTestSnapshot($0) },
            now: now
        )

        XCTAssertEqual(store.samples.count, 3)
        XCTAssertEqual(HistoryIdentity(config: original), HistoryIdentity(config: renamed))
        XCTAssertNotEqual(HistoryIdentity(config: original), HistoryIdentity(config: moved))
        XCTAssertNotEqual(HistoryIdentity(config: original), HistoryIdentity(config: changedKind))
    }

    func testCorruptAndUnknownVersionFilesAreNotOverwritten() throws {
        let directory = try historyTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = historyTestConfig()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let corruptURL = directory.appendingPathComponent("corrupt.json")
        let corruptData = Data("not-json".utf8)
        try corruptData.write(to: corruptURL)
        let corruptStore = UsageHistoryStore(url: corruptURL)
        corruptStore.record(snapshots: [historyTestSnapshot(config)], now: now)
        XCTAssertEqual(try Data(contentsOf: corruptURL), corruptData)
        XCTAssertEqual(corruptStore.samples.count, 1)
        XCTAssertEqual(
            corruptStore.errorMessage,
            "Saved history could not be read. New readings are available for this session."
        )

        let unknownURL = directory.appendingPathComponent("unknown.json")
        let unknownData = Data("{\"version\":99,\"samples\":[]}".utf8)
        try unknownData.write(to: unknownURL)
        let unknownStore = UsageHistoryStore(url: unknownURL)
        unknownStore.record(snapshots: [historyTestSnapshot(config)], now: now)
        XCTAssertEqual(try Data(contentsOf: unknownURL), unknownData)
        XCTAssertEqual(unknownStore.samples.count, 1)
        XCTAssertEqual(
            unknownStore.errorMessage,
            "Saved history could not be read. New readings are available for this session."
        )
    }

    func testSaveFailureKeepsInMemoryReadingsAndRetries() throws {
        let directory = try historyTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("blocker")
        try Data("file blocks parent directory".utf8).write(to: blocker)
        let url = blocker.appendingPathComponent("usage-history.json")
        let store = UsageHistoryStore(url: url)
        let config = historyTestConfig()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        store.record(snapshots: [historyTestSnapshot(config)], now: now)
        XCTAssertEqual(store.samples.count, 1)
        XCTAssertEqual(
            store.errorMessage,
            "History could not be saved. New readings are available for this session."
        )

        try FileManager.default.removeItem(at: blocker)
        store.record(snapshots: [], now: now)

        XCTAssertNil(store.errorMessage)
        let restarted = UsageHistoryStore(url: url)
        restarted.record(snapshots: [], now: now)
        XCTAssertEqual(restarted.samples, store.samples)
    }

    func testSeriesBreaksAtResetsDecreasesMissingWindowsAndGaps() {
        let identity = HistoryIdentity(config: historyTestConfig())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let changedReset = start.addingTimeInterval(10_000)
        let samples = [
            historyTestSample(identity: identity, timestamp: start, pct: 10),
            historyTestSample(identity: identity, timestamp: start.addingTimeInterval(60), pct: 12),
            historyTestSample(identity: identity, timestamp: start.addingTimeInterval(120), pct: 15, durationSeconds: 86_400),
            historyTestSample(identity: identity, timestamp: start.addingTimeInterval(180), pct: 16, resetAt: changedReset, durationSeconds: 86_400),
            historyTestSample(identity: identity, timestamp: start.addingTimeInterval(240), pct: 4, resetAt: changedReset, durationSeconds: 86_400),
            historyTestSample(identity: identity, timestamp: start.addingTimeInterval(300), pct: 4, includePrimary: false),
            historyTestSample(identity: identity, timestamp: start.addingTimeInterval(360), pct: 5, resetAt: changedReset, durationSeconds: 86_400),
            historyTestSample(identity: identity, timestamp: start.addingTimeInterval(1_261), pct: 6, resetAt: changedReset, durationSeconds: 86_400)
        ]

        let series = UsageHistorySeries.query(
            samples: samples,
            identity: identity,
            windowID: "primary",
            range: .days7,
            now: start.addingTimeInterval(2_000),
            refreshSeconds: 60
        )

        XCTAssertEqual(series.segments.map { $0.points.count }, [2, 1, 1, 1, 1, 1])
    }

    func testRangeFilteringAndDownsamplingPreservePeakAndEndpoints() {
        let identity = HistoryIdentity(config: historyTestConfig())
        let nowValue = 1_800_000_000.0
        let hour = floor(nowValue / 3_600) * 3_600 - 3_600
        let first = Date(timeIntervalSince1970: hour + 10)
        let regular: [UsageHistorySample] = (0..<13).map { index -> UsageHistorySample in
            let date: Date = first.addingTimeInterval(Double(index) * 180)
            let pct: Double = index == 6 ? 95 : Double(20 + index)
            return historyTestSample(
                identity: identity,
                timestamp: date,
                pct: pct
            )
        }
        let samples = [
            historyTestSample(identity: identity, timestamp: Date(timeIntervalSince1970: nowValue - 25 * 3_600), pct: 30)
        ] + regular + [
            historyTestSample(identity: identity, timestamp: Date(timeIntervalSince1970: nowValue + 1), pct: 99)
        ]
        let now = Date(timeIntervalSince1970: nowValue)

        let day = UsageHistorySeries.query(
            samples: samples, identity: identity, windowID: "primary",
            range: .hours24, now: now, refreshSeconds: 60
        )
        XCTAssertEqual(day.readingCount, regular.count)
        XCTAssertEqual(day.firstObservedAt, regular.first?.timestamp)
        XCTAssertEqual(day.lastObservedAt, regular.last?.timestamp)

        let week = UsageHistorySeries.query(
            samples: samples, identity: identity, windowID: "primary",
            range: .days7, now: now, refreshSeconds: 60
        )
        XCTAssertEqual(week.readingCount, regular.count + 1)
        XCTAssertEqual(week.peakObservedPct, 95)
        XCTAssertEqual(week.latestObservedPct, regular.last?.windows.first?.pct)
        let chartPoints = week.segments.flatMap(\.points)
        XCTAssertLessThan(chartPoints.count, week.readingCount)
        let retainedIDs = Set(chartPoints.map(\.id))
        let firstID = "primary|\(regular[0].timestamp.timeIntervalSince1970.bitPattern)"
        let lastID = "primary|\(regular[regular.count - 1].timestamp.timeIntervalSince1970.bitPattern)"
        XCTAssertTrue(retainedIDs.contains(firstID))
        XCTAssertTrue(retainedIDs.contains(lastID))
        XCTAssertEqual(chartPoints.last?.timestamp, regular.last?.timestamp)
    }

    func testInvalidPercentagesAreExcluded() throws {
        let directory = try historyTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageHistoryStore(url: directory.appendingPathComponent("history.json"))
        let config = historyTestConfig()
        var snapshot = historyTestSnapshot(config, pct: .infinity, weekly: [
            WeeklyMetric(label: "Below", pct: -1, resetText: ""),
            WeeklyMetric(label: "Above", pct: 101, resetText: "")
        ])
        store.record(snapshots: [snapshot], now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(store.samples.isEmpty)

        snapshot.sessionPct = 40
        snapshot.weekly.append(WeeklyMetric(label: "Valid", pct: 65, resetText: ""))
        snapshot.weekly.append(WeeklyMetric(label: "Infinite", pct: .infinity, resetText: ""))
        store.record(snapshots: [snapshot], now: Date(timeIntervalSince1970: 1_800_000_301))
        XCTAssertEqual(store.samples.first?.windows.map(\.id), ["primary", "secondary:Valid"])
    }
}
