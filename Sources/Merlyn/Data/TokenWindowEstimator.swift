// TokenWindowEstimator.swift — turns hourly token buckets into session-block and
// rolling-week usage percentages for providers that don't report rate limits
// locally (Claude, Kimi). Limits auto-calibrate to the historical peak unless
// the user pins them in providers.json.

import Foundation

/// Hour-bucketed token counts, split by model family ("all" plus e.g. "sonnet").
typealias HourBuckets = [Int: [String: Int]] // hourEpoch -> family -> tokens

enum TokenWindowEstimator {
    static let scanWindowDays = 35

    /// At most this many weekly rows ("All models" + the first N-1 model families
    /// alphabetically). The card lists every row it gets, so this caps a heavy
    /// multi-model week from flooding the detail view with estimate bars.
    static let maxWeeklyRows = 3

    struct SessionResult {
        var pct: Double
        var resetAt: Date?
        var weekly: [WeeklyMetric]
    }

    /// Session blocks follow the convention popularized by ccusage: a block
    /// starts at the floor-to-hour of the first activity after the previous
    /// block ended, and lasts `sessionHours`.
    static func evaluate(
        buckets: HourBuckets,
        now: Date,
        sessionHours: Double,
        sessionLimitOverride: Int?,
        weeklyLimitOverride: Int?
    ) -> SessionResult {
        let hourLen = 3600
        let blockLen = Int(sessionHours * 3600)
        let hours = buckets.keys.sorted()
        guard !hours.isEmpty else {
            return SessionResult(pct: 0, resetAt: nil, weekly: [])
        }

        func total(_ hour: Int) -> Int { buckets[hour]?["all"] ?? 0 }

        // Walk hours ascending, grouping into blocks.
        var blocks: [(start: Int, total: Int)] = []
        var blockStart = hours[0]
        var blockTotal = 0
        for hour in hours {
            if hour >= blockStart + blockLen {
                blocks.append((blockStart, blockTotal))
                blockStart = hour
                blockTotal = 0
            }
            blockTotal += total(hour)
        }
        blocks.append((blockStart, blockTotal))

        let nowEpoch = Int(now.timeIntervalSince1970)
        let current = blocks.last.flatMap { last in
            (nowEpoch < last.start + blockLen) ? last : nil
        }

        let peakBlock = blocks.map(\.total).max() ?? 1
        let sessionLimit = max(sessionLimitOverride ?? peakBlock, 1)
        let sessionPct = current.map { min(100, Double($0.total) / Double(sessionLimit) * 100) } ?? 0
        let resetAt = current.map { Date(timeIntervalSince1970: Double($0.start + blockLen)) }

        // Rolling 7-day totals per family, calibrated against the busiest
        // 7-day stretch in the scan window (sampled at day granularity).
        let weekLen = 7 * 24 * hourLen
        var families = Set(buckets.values.flatMap(\.keys))
        families.remove("all")

        func windowTotal(family: String, from: Int, to: Int) -> Int {
            buckets.reduce(0) { acc, entry in
                (entry.key >= from && entry.key < to) ? acc + (entry.value[family] ?? 0) : acc
            }
        }

        func peakWeek(family: String) -> Int {
            guard let first = hours.first, let last = hours.last else { return 1 }
            var peak = 0
            var dayStart = first - first % 86400
            while dayStart <= last {
                peak = max(peak, windowTotal(family: family, from: dayStart, to: dayStart + weekLen))
                dayStart += 86400
            }
            return max(peak, 1)
        }

        // Without a configured limit the denominator is the busiest 7-day
        // stretch on record — say so, or "100%" reads as a hit quota.
        let weeklyCaption = weeklyLimitOverride != nil
            ? "Weekly limit · rolling 7 days"
            : "vs your busiest week · rolling 7 days"
        var weekly: [WeeklyMetric] = []
        let weekFrom = nowEpoch - weekLen
        let allCurrent = windowTotal(family: "all", from: weekFrom, to: nowEpoch)
        let allLimit = max(weeklyLimitOverride ?? peakWeek(family: "all"), 1)
        weekly.append(WeeklyMetric(
            label: "All models",
            pct: min(100, Double(allCurrent) / Double(allLimit) * 100),
            resetText: weeklyCaption
        ))
        for family in families.sorted() {
            let current = windowTotal(family: family, from: weekFrom, to: nowEpoch)
            guard current > 0 else { continue }
            let limit = weeklyLimitOverride.map { max($0, 1) } ?? peakWeek(family: family)
            weekly.append(WeeklyMetric(
                label: "\(family.capitalized) only",
                pct: min(100, Double(current) / Double(limit) * 100),
                resetText: weeklyCaption
            ))
        }
        if weekly.count > maxWeeklyRows { weekly = Array(weekly.prefix(maxWeeklyRows)) }

        return SessionResult(pct: sessionPct, resetAt: resetAt, weekly: weekly)
    }

    /// Buckets a model id into a family for the per-family weekly rows. The list
    /// is a hardcoded snapshot of Anthropic's family names — a new family lands
    /// in "other" until it's added here, which only affects how estimate rows are
    /// grouped, never the real API-reported limits.
    static func modelFamily(_ model: String) -> String {
        let lower = model.lowercased()
        for family in ["opus", "sonnet", "haiku", "fable"] where lower.contains(family) {
            return family
        }
        return "other"
    }
}

/// Per-file parse cache so a refresh only re-reads files that changed.
struct FileBucketCache: Codable {
    struct Entry: Codable {
        var mtime: Double
        var size: Int
        var buckets: HourBuckets
    }
    var entries: [String: Entry] = [:]

    static func load() -> FileBucketCache {
        guard let data = try? Data(contentsOf: AppPaths.cacheFile),
              let cache = try? JSONDecoder().decode(FileBucketCache.self, from: data)
        else { return FileBucketCache() }
        return cache
    }

    func save() {
        // drop entries whose files have aged out of every scan window
        var pruned = self
        let cutoff = Date().addingTimeInterval(-Double(TokenWindowEstimator.scanWindowDays + 5) * 86400)
            .timeIntervalSince1970
        pruned.entries = entries.filter { $0.value.mtime > cutoff }

        do {
            let data = try JSONEncoder().encode(pruned)
            persist(data, to: AppPaths.cacheFile, what: "usage-cache.json")
        } catch {
            NSLog("Merlyn: failed to encode usage-cache.json: \(error.localizedDescription)")
        }
    }

    /// Returns cached buckets when (mtime, size) match, else parses and stores.
    mutating func buckets(
        for url: URL, mtime: Date, size: Int,
        parse: (URL) -> HourBuckets
    ) -> HourBuckets {
        let key = url.path
        if let entry = entries[key], entry.mtime == mtime.timeIntervalSince1970, entry.size == size {
            return entry.buckets
        }
        let parsed = parse(url)
        entries[key] = Entry(mtime: mtime.timeIntervalSince1970, size: size, buckets: parsed)
        return parsed
    }

}

func mergeBuckets(_ into: inout HourBuckets, _ from: HourBuckets) {
    for (hour, families) in from {
        for (family, tokens) in families {
            into[hour, default: [:]][family, default: 0] += tokens
        }
    }
}
