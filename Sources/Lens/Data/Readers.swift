// Readers.swift — per-provider usage readers.
//
// Every reader is API-first (real, provider-reported rate limits via
// ProviderAPI.swift) and falls back to local file analysis when the API is
// unreachable or the login is stale:
//
//  claude — fallback estimates from transcripts under projects/**/*.jsonl
//  codex  — fallback reads the newest rate_limits event from rollout files
//  kimi   — fallback estimates from wire.jsonl event logs

import Foundation

protocol UsageReader {
    func read(config: ProviderConfig, app: AppConfig, ctx: inout ReaderContext, now: Date) -> ProviderSnapshot
}

private let activeThreshold: TimeInterval = 120
/// How long to skip the API after a 429 before trying again.
private let apiCooldown: TimeInterval = 300
/// How old a cached real reading may be and still beat a local estimate.
private let maxStaleAge: TimeInterval = 6 * 3600

/// Shared API-first wrapper: honor any active cooldown, attempt the live fetch,
/// and on failure prefer a recent cached real reading over the local fallback.
/// Records 429s as cooldowns and successes as last-good readings.
private func apiFirst(
    config: ProviderConfig,
    ctx: inout ReaderContext,
    now: Date,
    fetch: () throws -> ProviderSnapshot,
    fallback: (_ fetchError: Error?) -> ProviderSnapshot
) -> ProviderSnapshot {
    // A user-initiated (forced) refresh ignores the post-429 cooldown so an
    // explicit click always re-attempts the live fetch instead of silently
    // returning stale cache. The cooldown still throttles the background poll.
    let cooling = !ctx.force && (ctx.cooldownUntil[config.id].map { $0 > now } ?? false)
    var fetchError: Error?

    if !cooling {
        do {
            let snapshot = try fetch()
            if let reading = snapshot.realReading(at: now) {
                ctx.lastGood[config.id] = reading
            }
            ctx.cooldownUntil[config.id] = nil
            return snapshot
        } catch {
            fetchError = error
            if case ProviderAPIError.http(429) = error {
                ctx.cooldownUntil[config.id] = now.addingTimeInterval(apiCooldown)
            }
        }
    }

    // Prefer the last real numbers over a misleading estimate.
    if let cached = ctx.lastGood[config.id],
       now.timeIntervalSince(cached.capturedAt) < maxStaleAge {
        var snapshot = ProviderSnapshot.fromCache(cached, config: config, now: now)
        // Explain *why* it's stuck on old numbers: an endpoint that's rate-limiting
        // us (cooling down, or a forced retry that 429'd again) reads as
        // "rate-limited" rather than an unexplained old timestamp.
        if cooling || fetchError?.isRateLimited == true, let note = snapshot.note {
            snapshot.note = "rate-limited · \(note)"
        }
        return snapshot
    }

    var snapshot = fallback(fetchError)
    // A "No data" fallback carries its own concise note; don't tack the raw
    // "login expired (…)" reason onto it.
    if !snapshot.isUnavailable {
        let reason = fetchError.map { "\($0)" } ?? "API cooling down"
        snapshot.note = [snapshot.note, reason].compactMap(\.self).joined(separator: " · ")
    }
    return snapshot
}

// MARK: - File discovery helpers

private struct CandidateFile {
    let url: URL
    let mtime: Date
    let size: Int
}

private func jsonlFiles(under root: URL, modifiedWithinDays days: Int) -> [CandidateFile] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
    var out: [CandidateFile] = []
    for case let url as URL in enumerator {
        guard url.pathExtension == "jsonl" else { continue }
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let mtime = values.contentModificationDate,
              mtime > cutoff
        else { continue }
        out.append(CandidateFile(url: url, mtime: mtime, size: values.fileSize ?? 0))
    }
    return out
}

private func forEachLine(of url: URL, _ body: (Substring) -> Void) {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
          let text = String(data: data, encoding: .utf8)
    else { return }
    text.split(separator: "\n", omittingEmptySubsequences: true).forEach(body)
}

private let isoParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func parseISO(_ s: String) -> Date? {
    isoParser.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

private func hourEpoch(_ date: Date) -> Int {
    let t = Int(date.timeIntervalSince1970)
    return t - t % 3600
}

let resetFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE h:mm a"
    return f
}()

private func weeklyResetText(_ date: Date?) -> String {
    date.map { "Weekly limit · resets \(resetFormatter.string(from: $0))" } ?? "Weekly limit"
}

/// Session windows report a reset time even when idle; suppress it at 0% so
/// the card reads "No active session" instead of counting down to nothing.
private func sessionReset(_ window: UsageWindow?) -> Date? {
    guard let window, window.usedPct > 0 else { return nil }
    return window.resetsAt
}

private func recentActivity(under root: URL, now: Date) -> Bool {
    jsonlFiles(under: root, modifiedWithinDays: 1)
        .contains { now.timeIntervalSince($0.mtime) < activeThreshold }
}

/// Whole-history metadata sweep → stateless idle-game stats. Sums log-file
/// sizes (lifetime bytes, drives level + XP) and collects active local-calendar
/// days from mtimes (drives the streak). Reads no file *contents* — just the
/// `stat` metadata `jsonlFiles` already prefetches — so it stays cheap and
/// monotonic. Returns nil when the log tree doesn't exist yet.
func computeGameStats(root: URL, now: Date) -> GameStats? {
    guard FileManager.default.fileExists(atPath: root.path) else { return nil }
    // ~100y window = "all history": effectively no mtime cutoff.
    let files = jsonlFiles(under: root, modifiedWithinDays: 36_500)
    guard !files.isEmpty else { return nil }
    var bytes = 0
    var days: Set<Int> = []
    for f in files {
        bytes += f.size
        days.insert(GameStats.dayIndex(f.mtime))
    }
    return GameStats.make(lifetimeBytes: bytes, activeDays: days, today: GameStats.dayIndex(now))
}

// MARK: - Claude

struct ClaudeReader: UsageReader {
    func read(config: ProviderConfig, app: AppConfig, ctx: inout ReaderContext, now: Date) -> ProviderSnapshot {
        let projectsRoot = URL(fileURLWithPath: config.expandedDir).appendingPathComponent("projects")
        var fileCache = ctx.fileCache
        defer { ctx.fileCache = fileCache }
        var snap = apiFirst(config: config, ctx: &ctx, now: now, fetch: {
            let usage = try ClaudeUsageAPI.fetch(configDir: config.expandedDir)
            var weekly: [WeeklyMetric] = []
            if let week = usage.sevenDay {
                weekly.append(WeeklyMetric(
                    label: "All models", pct: week.usedPct,
                    resetText: weeklyResetText(week.resetsAt)
                ))
            }
            for (label, window) in usage.sevenDayModels {
                weekly.append(WeeklyMetric(
                    label: label, pct: window.usedPct,
                    resetText: weeklyResetText(window.resetsAt)
                ))
            }
            return ProviderSnapshot(
                config: config,
                sessionPct: usage.fiveHour?.usedPct ?? 0,
                sessionResetAt: sessionReset(usage.fiveHour),
                weekly: weekly,
                isActive: recentActivity(under: projectsRoot, now: now),
                isEstimated: false,
                plan: usage.planLabel
            )
        }, fallback: { error in
            // Login lapsed → genuinely no data. Don't fall back to the
            // "vs your busiest week" estimate, which reads as real 100% usage.
            if error?.isAuthLapse == true {
                return .unavailable(config, note: "Sign in again — run any \(config.name) command")
            }
            // Server unreachable with no fresh cache left to ride on → same
            // honest "No data"/offline mascot rather than a fabricated estimate.
            if error?.isServerUnreachable == true {
                return .unavailable(config, note: "Offline — can't reach \(config.name)")
            }
            return estimate(config: config, app: app, cache: &fileCache, now: now, root: projectsRoot)
        })
        snap.game = computeGameStats(root: projectsRoot, now: now)
        return snap
    }

    private func estimate(
        config: ProviderConfig, app: AppConfig,
        cache: inout FileBucketCache, now: Date, root: URL
    ) -> ProviderSnapshot {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return .empty(config, note: "No transcripts yet in \(config.dir)")
        }
        let files = jsonlFiles(under: root, modifiedWithinDays: TokenWindowEstimator.scanWindowDays)
        guard !files.isEmpty else {
            return .empty(config, note: "No recent activity in \(config.dir)")
        }

        var merged: HourBuckets = [:]
        for file in files {
            let buckets = cache.buckets(for: file.url, mtime: file.mtime, size: file.size, parse: Self.parse)
            mergeBuckets(&merged, buckets)
        }

        let result = TokenWindowEstimator.evaluate(
            buckets: merged, now: now, sessionHours: app.sessionHours,
            sessionLimitOverride: config.sessionTokenLimit,
            weeklyLimitOverride: config.weeklyTokenLimit
        )
        let active = files.contains { now.timeIntervalSince($0.mtime) < activeThreshold }
        return ProviderSnapshot(
            config: config, sessionPct: result.pct, sessionResetAt: result.resetAt,
            weekly: result.weekly, isActive: active, isEstimated: true, note: nil
        )
    }

    /// Parses one Claude Code transcript. Assistant messages repeat when streamed,
    /// so entries are deduped on message id + requestId.
    static func parse(_ url: URL) -> HourBuckets {
        var buckets: HourBuckets = [:]
        var seen = Set<String>()
        forEachLine(of: url) { line in
            guard line.contains("\"usage\""), line.contains("\"assistant\"") else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let ts = obj["timestamp"] as? String,
                  let date = parseISO(ts),
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { return }

            let msgId = message["id"] as? String ?? ""
            let reqId = obj["requestId"] as? String ?? ""
            if !msgId.isEmpty || !reqId.isEmpty {
                let key = "\(msgId):\(reqId)"
                guard seen.insert(key).inserted else { return }
            }

            let tokens = (usage["input_tokens"] as? Int ?? 0)
                + (usage["output_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)
            guard tokens > 0 else { return }

            let family = TokenWindowEstimator.modelFamily(message["model"] as? String ?? "")
            let hour = hourEpoch(date)
            buckets[hour, default: [:]]["all", default: 0] += tokens
            buckets[hour, default: [:]][family, default: 0] += tokens
        }
        return buckets
    }
}

// MARK: - Codex

struct CodexReader: UsageReader {
    func read(config: ProviderConfig, app: AppConfig, ctx: inout ReaderContext, now: Date) -> ProviderSnapshot {
        let sessionsRoot = URL(fileURLWithPath: config.expandedDir).appendingPathComponent("sessions")
        var snap = apiFirst(config: config, ctx: &ctx, now: now, fetch: {
            let usage = try CodexUsageAPI.fetch(configDir: config.expandedDir)
            var weekly: [WeeklyMetric] = []
            if let week = usage.secondary {
                weekly.append(WeeklyMetric(
                    label: "Weekly", pct: week.usedPct,
                    resetText: weeklyResetText(week.resetsAt)
                ))
            }
            for extra in usage.additional {
                if let w = extra.fiveHour, w.usedPct > 0 || extra.weekly == nil {
                    weekly.append(WeeklyMetric(
                        label: "\(extra.name) · 5h", pct: w.usedPct,
                        resetText: w.resetsAt.map { "Resets \(resetFormatter.string(from: $0))" } ?? ""
                    ))
                }
                if let w = extra.weekly {
                    weekly.append(WeeklyMetric(
                        label: "\(extra.name) · weekly", pct: w.usedPct,
                        resetText: weeklyResetText(w.resetsAt)
                    ))
                }
            }
            return ProviderSnapshot(
                config: config,
                sessionPct: usage.primary?.usedPct ?? 0,
                sessionResetAt: sessionReset(usage.primary),
                weekly: Array(weekly.prefix(4)),
                isActive: recentActivity(under: sessionsRoot, now: now),
                isEstimated: false,
                plan: usage.planLabel
            )
        }, fallback: { error in
            // Codex rollout files carry real rate_limits events, so the offline
            // fallback is genuine data (not an estimate) even when auth lapses or
            // the server is unreachable — keep showing it (aged) rather than dead.
            if let real = rolloutFallback(config: config, now: now, root: sessionsRoot) {
                return real
            }
            // Nothing on disk either: a server we couldn't reach is a true
            // offline/no-data state; otherwise it's just an empty profile.
            return error?.isServerUnreachable == true
                ? .unavailable(config, note: "Offline — can't reach \(config.name)")
                : .empty(config, note: "No rate-limit history in \(config.dir)")
        })
        snap.game = computeGameStats(root: sessionsRoot, now: now)
        return snap
    }

    /// Offline fallback: the newest rate_limits event a rollout file captured.
    /// Returns nil when no rollout rate-limit data exists on disk at all, so the
    /// caller can distinguish "real but stale numbers" from a true no-data state.
    private func rolloutFallback(config: ProviderConfig, now: Date, root: URL) -> ProviderSnapshot? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let files = jsonlFiles(under: root, modifiedWithinDays: 8)
            .sorted { $0.mtime > $1.mtime }
        guard !files.isEmpty else { return nil }

        // Newest rate_limits event across the most recent rollouts wins.
        var best: (date: Date, limits: [String: Any])?
        for file in files.prefix(12) {
            guard let found = Self.lastRateLimits(in: file.url) else { continue }
            if best == nil || found.date > best!.date { best = found }
            if best != nil { break } // files are mtime-sorted; first hit is the newest
        }
        guard let (eventDate, limits) = best else { return nil }

        func window(_ key: String) -> (pct: Double, resetsAt: Date?)? {
            guard let w = limits[key] as? [String: Any],
                  let pct = (w["used_percent"] as? NSNumber)?.doubleValue
            else { return nil }
            let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return (pct, resets)
        }

        var sessionPct = 0.0
        var sessionResetAt: Date?
        if let primary = window("primary") {
            if let resets = primary.resetsAt, resets <= now {
                sessionPct = 0 // window already rolled over since the last event
            } else {
                sessionPct = primary.pct
                sessionResetAt = primary.resetsAt
            }
        }

        var weekly: [WeeklyMetric] = []
        if let secondary = window("secondary") {
            let stillCurrent = secondary.resetsAt.map { $0 > now } ?? true
            weekly.append(WeeklyMetric(
                label: "Weekly",
                pct: stillCurrent ? secondary.pct : 0,
                resetText: secondary.resetsAt.map {
                    stillCurrent ? "Weekly limit · resets \(resetFormatter.string(from: $0))" : "Weekly limit · rolled over"
                } ?? "Weekly limit"
            ))
        }

        let plan = (limits["plan_type"] as? String)?.capitalized
        let active = files.contains { now.timeIntervalSince($0.mtime) < activeThreshold }
        let ageMin = Int(now.timeIntervalSince(eventDate) / 60)

        return ProviderSnapshot(
            config: config, sessionPct: sessionPct, sessionResetAt: sessionResetAt,
            weekly: weekly, isActive: active, isEstimated: true,
            note: ageMin > 60 ? "as of \(ageMin / 60)h ago" : nil, plan: plan
        )
    }

    /// Tail-reads a rollout file and returns its newest rate_limits payload.
    static func lastRateLimits(in url: URL) -> (date: Date, limits: [String: Any])? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 256 * 1024
        let offset = size > tail ? size - tail : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any]
            else { continue }
            let date = (obj["timestamp"] as? String).flatMap(parseISO) ?? Date.distantPast
            return (date, limits)
        }
        return nil
    }

}

// MARK: - Kimi

struct KimiReader: UsageReader {
    func read(config: ProviderConfig, app: AppConfig, ctx: inout ReaderContext, now: Date) -> ProviderSnapshot {
        let sessionsRoot = URL(fileURLWithPath: config.expandedDir).appendingPathComponent("sessions")
        var fileCache = ctx.fileCache
        defer { ctx.fileCache = fileCache }
        var snap = apiFirst(config: config, ctx: &ctx, now: now, fetch: {
            let usage = try KimiUsageAPI.fetch(configDir: config.expandedDir)
            // session ring = the shortest reported window (the ~5h rate limit)
            let session = usage.shortWindows.first?.window
            var weekly: [WeeklyMetric] = []
            if let week = usage.weekly {
                weekly.append(WeeklyMetric(
                    label: "Weekly", pct: week.usedPct,
                    resetText: weeklyResetText(week.resetsAt)
                ))
            }
            for (label, window) in usage.shortWindows.dropFirst() {
                weekly.append(WeeklyMetric(
                    label: label, pct: window.usedPct,
                    resetText: window.resetsAt.map { "Resets \(resetFormatter.string(from: $0))" } ?? ""
                ))
            }
            return ProviderSnapshot(
                config: config,
                sessionPct: session?.usedPct ?? 0,
                sessionResetAt: sessionReset(session),
                weekly: weekly,
                isActive: recentActivity(under: sessionsRoot, now: now),
                isEstimated: false,
                plan: usage.planLabel
            )
        }, fallback: { error in
            if error?.isAuthLapse == true {
                return .unavailable(config, note: "Sign in again — run any \(config.name) command")
            }
            if error?.isServerUnreachable == true {
                return .unavailable(config, note: "Offline — can't reach \(config.name)")
            }
            return estimate(config: config, app: app, cache: &fileCache, now: now, root: sessionsRoot)
        })
        snap.game = computeGameStats(root: sessionsRoot, now: now)
        return snap
    }

    private func estimate(
        config: ProviderConfig, app: AppConfig,
        cache: inout FileBucketCache, now: Date, root: URL
    ) -> ProviderSnapshot {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return .empty(config, note: "No sessions yet in \(config.dir)")
        }
        let files = jsonlFiles(under: root, modifiedWithinDays: TokenWindowEstimator.scanWindowDays)
            .filter { $0.url.lastPathComponent == "wire.jsonl" }
        guard !files.isEmpty else {
            return .empty(config, note: "No recent activity in \(config.dir)")
        }

        var merged: HourBuckets = [:]
        for file in files {
            let buckets = cache.buckets(for: file.url, mtime: file.mtime, size: file.size, parse: Self.parse)
            mergeBuckets(&merged, buckets)
        }

        let result = TokenWindowEstimator.evaluate(
            buckets: merged, now: now, sessionHours: app.sessionHours,
            sessionLimitOverride: config.sessionTokenLimit,
            weeklyLimitOverride: config.weeklyTokenLimit
        )
        let active = files.contains { now.timeIntervalSince($0.mtime) < activeThreshold }
        // Kimi logs don't split by model; keep just the aggregate row.
        let weekly = result.weekly.filter { $0.label == "All models" }
            .map { WeeklyMetric(label: "Weekly", pct: $0.pct, resetText: $0.resetText) }
        return ProviderSnapshot(
            config: config, sessionPct: result.pct, sessionResetAt: result.resetAt,
            weekly: weekly, isActive: active, isEstimated: true, note: nil
        )
    }

    /// Parses a Kimi wire.jsonl: step.end loop events carry usage + epoch-ms time.
    static func parse(_ url: URL) -> HourBuckets {
        var buckets: HourBuckets = [:]
        forEachLine(of: url) { line in
            guard line.contains("\"usage\"") else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }

            let timeMs = (obj["time"] as? NSNumber)?.doubleValue
                ?? ((obj["event"] as? [String: Any])?["time"] as? NSNumber)?.doubleValue
            let usage = ((obj["event"] as? [String: Any])?["usage"] as? [String: Any])
                ?? (obj["usage"] as? [String: Any])
            guard let timeMs, let usage else { return }

            let tokens = (usage["inputOther"] as? Int ?? 0)
                + (usage["output"] as? Int ?? 0)
                + (usage["inputCacheRead"] as? Int ?? 0)
                + (usage["inputCacheCreation"] as? Int ?? 0)
            guard tokens > 0 else { return }

            let hour = hourEpoch(Date(timeIntervalSince1970: timeMs / 1000))
            buckets[hour, default: [:]]["all", default: 0] += tokens
        }
        return buckets
    }
}

func reader(for kind: ProviderKind) -> UsageReader {
    switch kind {
    case .claude: ClaudeReader()
    case .codex: CodexReader()
    case .kimi: KimiReader()
    }
}
