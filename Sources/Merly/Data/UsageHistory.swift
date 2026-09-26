import Foundation

struct HistoryIdentity: Codable, Equatable, Hashable {
    var providerID: String
    var kind: String
    var directory: String

    init(config: ProviderConfig) {
        providerID = config.id
        kind = config.kind.rawValue
        directory = URL(fileURLWithPath: config.expandedDir).standardizedFileURL.path
    }
}

struct UsageHistoryWindow: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var pct: Double
    var resetAt: Date?
    var durationSeconds: Double?
}

struct UsageHistorySample: Codable, Equatable {
    var identity: HistoryIdentity
    var timestamp: Date
    var windows: [UsageHistoryWindow]
}

/// Mutable state is confined to `UsageEngine.workQueue`.
final class UsageHistoryStore: @unchecked Sendable {
    private struct Archive: Codable {
        var version: Int
        var samples: [UsageHistorySample]
    }

    private enum ArchiveError: LocalizedError {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version): "Unsupported usage history version: \(version)"
            }
        }
    }

    private let url: URL
    private var loaded = false
    private var readFailed = false
    private var needsSave = false
    private(set) var samples: [UsageHistorySample] = []
    private(set) var errorMessage: String?

    init(url: URL = AppPaths.supportDir.appendingPathComponent("usage-history.json")) {
        self.url = url
    }

    func record(snapshots: [ProviderSnapshot], now: Date) {
        loadIfNeeded()

        let previous = samples
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        samples.removeAll { $0.timestamp < cutoff || $0.timestamp > now }

        for snapshot in snapshots {
            guard snapshot.failure == nil, !snapshot.isEstimated, !snapshot.isStale else { continue }
            let identity = HistoryIdentity(config: snapshot.config)
            var windows: [UsageHistoryWindow] = []
            if Self.isValid(snapshot.sessionPct) {
                windows.append(UsageHistoryWindow(
                    id: "primary",
                    label: snapshot.primaryWindowName,
                    pct: snapshot.sessionPct,
                    resetAt: snapshot.sessionResetAt,
                    durationSeconds: snapshot.sessionWindowSeconds
                ))
            }
            windows.append(contentsOf: snapshot.weekly.compactMap { metric in
                guard Self.isValid(metric.pct) else { return nil }
                return UsageHistoryWindow(
                    id: "secondary:\(metric.label)",
                    label: metric.label,
                    pct: metric.pct,
                    resetAt: metric.resetAt,
                    durationSeconds: metric.isWeekly ? 604_800 : nil
                )
            })
            guard !windows.isEmpty else { continue }

            let sample = UsageHistorySample(identity: identity, timestamp: now, windows: windows)
            let bucket = Self.bucket(now)
            if let index = samples.firstIndex(where: {
                $0.identity == identity && Self.bucket($0.timestamp) == bucket
            }) {
                if samples[index].timestamp <= now { samples[index] = sample }
            } else {
                samples.append(sample)
            }
        }

        samples.sort { $0.timestamp < $1.timestamp }
        if samples != previous { needsSave = true }
        guard needsSave, !readFailed else { return }
        save()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1 else { throw ArchiveError.unsupportedVersion(archive.version) }
            samples = archive.samples
        } catch {
            readFailed = true
            errorMessage = "Saved history could not be read. New readings are available for this session."
            NSLog("Merly: saved usage history could not be read (\(error.localizedDescription))")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(Archive(version: 1, samples: samples))
            guard persist(data, to: url, what: "usage-history.json") else {
                setSaveFailure()
                return
            }
            needsSave = false
            errorMessage = nil
        } catch {
            NSLog("Merly: failed to encode usage history (\(error.localizedDescription))")
            setSaveFailure()
        }
    }

    private func setSaveFailure() {
        needsSave = true
        errorMessage = "History could not be saved. New readings are available for this session."
    }

    private static func bucket(_ date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / 300))
    }

    private static func isValid(_ pct: Double) -> Bool {
        pct.isFinite && (0...100).contains(pct)
    }
}

enum UsageHistoryRange: String, CaseIterable, Identifiable {
    case hours24 = "24h"
    case days7 = "7d"
    case days30 = "30d"

    var id: String { rawValue }

    var durationSeconds: TimeInterval {
        switch self {
        case .hours24: 24 * 60 * 60
        case .days7: 7 * 24 * 60 * 60
        case .days30: 30 * 24 * 60 * 60
        }
    }

    var downsampleBucketSeconds: TimeInterval {
        switch self {
        case .hours24: 5 * 60
        case .days7: 60 * 60
        case .days30: 6 * 60 * 60
        }
    }
}

struct UsageHistoryPoint: Identifiable, Equatable {
    var id: String
    var timestamp: Date
    var pct: Double
    var segmentID: String
}

struct UsageHistorySegment: Identifiable, Equatable {
    var id: String
    var points: [UsageHistoryPoint]
}

struct UsageHistorySeries: Equatable {
    var segments: [UsageHistorySegment]
    var latestObservedPct: Double?
    var peakObservedPct: Double?
    var readingCount: Int
    var firstObservedAt: Date?
    var lastObservedAt: Date?

    static func query(
        samples: [UsageHistorySample],
        identity: HistoryIdentity,
        windowID: String,
        range: UsageHistoryRange,
        now: Date,
        refreshSeconds: TimeInterval
    ) -> UsageHistorySeries {
        let start = now.addingTimeInterval(-range.durationSeconds)
        let retained = samples
            .filter { $0.identity == identity && $0.timestamp >= start && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }

        var rawSegments: [[(timestamp: Date, window: UsageHistoryWindow)]] = []
        var current: [(timestamp: Date, window: UsageHistoryWindow)] = []
        let maximumGap = max(15 * 60, refreshSeconds * 3)

        for sample in retained {
            guard let window = sample.windows.first(where: {
                $0.id == windowID && $0.pct.isFinite && (0...100).contains($0.pct)
            }) else {
                if !current.isEmpty {
                    rawSegments.append(current)
                    current = []
                }
                continue
            }

            if let previous = current.last {
                let gap = sample.timestamp.timeIntervalSince(previous.timestamp)
                let breaks = window.resetAt != previous.window.resetAt
                    || window.pct < previous.window.pct
                    || window.durationSeconds != previous.window.durationSeconds
                    || gap > maximumGap
                if breaks {
                    rawSegments.append(current)
                    current = []
                }
            }
            current.append((sample.timestamp, window))
        }
        if !current.isEmpty { rawSegments.append(current) }

        let rawPoints = rawSegments.flatMap { $0 }
        let allPoints = rawSegments.map { segment -> UsageHistorySegment in
            let segmentID = Self.pointID(timestamp: segment[0].timestamp, windowID: windowID)
            let points = segment.map { item in
                UsageHistoryPoint(
                    id: Self.pointID(timestamp: item.timestamp, windowID: windowID),
                    timestamp: item.timestamp,
                    pct: item.window.pct,
                    segmentID: segmentID
                )
            }
            return UsageHistorySegment(id: segmentID, points: Self.downsample(
                points, bucketSeconds: range.downsampleBucketSeconds
            ))
        }

        return UsageHistorySeries(
            segments: allPoints,
            latestObservedPct: rawPoints.last?.window.pct,
            peakObservedPct: rawPoints.map(\.window.pct).max(),
            readingCount: rawPoints.count,
            firstObservedAt: rawPoints.first?.timestamp,
            lastObservedAt: rawPoints.last?.timestamp
        )
    }

    private static func pointID(timestamp: Date, windowID: String) -> String {
        "\(windowID)|\(timestamp.timeIntervalSince1970.bitPattern)"
    }

    private static func downsample(
        _ points: [UsageHistoryPoint],
        bucketSeconds: TimeInterval
    ) -> [UsageHistoryPoint] {
        guard points.count > 2 else { return points }
        var lastByBucket: [Int64: UsageHistoryPoint] = [:]
        for point in points {
            let bucket = Int64(floor(point.timestamp.timeIntervalSince1970 / bucketSeconds))
            lastByBucket[bucket] = point
        }
        let retainedIDs = Set(lastByBucket.values.map(\.id) + [points[0].id, points[points.count - 1].id])
        return points.filter { retainedIDs.contains($0.id) }
    }
}
