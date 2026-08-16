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
    // A cooldown is itself the reason: the only thing that sets one is a 429. Left
    // as a nil error, the fallback read it as "unexplained" and papered over a
    // standing rate limit with a local estimate.
    var fetchError: Error? = cooling ? ProviderAPIError.http(429) : nil

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
    // A failure snapshot carries its own concise note; don't tack the raw
    // "login expired (…)" reason onto it.
    if !snapshot.isUnavailable {
        let reason = cooling ? "API cooling down" : fetchError.map { "\($0)" } ?? "API unavailable"
        // `compactMap { $0 }`, not `compactMap(\.self)`: the key-path form fails to
        // type-check on the Swift shipped with the macos-14 CI runner.
        snapshot.note = [snapshot.note, reason].compactMap { $0 }.joined(separator: " · ")
    }
    return snapshot
}

/// Maps a fetch failure onto the card's error state, for readers whose only other
/// option is a local estimate. Returns nil when the error doesn't rule the
/// estimate out (schema drift, or no error at all) — an unreadable *response* from
/// a healthy account is exactly what the offline safety net is for, while a
/// refusal, a lapse or a dead endpoint means there is no quota to stand in for.
private func failureSnapshot(_ error: Error?, config: ProviderConfig) -> ProviderSnapshot? {
    guard let error else { return nil }
    if error.isAuthLapse {
        // An *expired* token still has a live refresh token behind it (we never
        // refresh Claude/Codex ourselves), so using the CLI again brings it back.
        // Missing credentials genuinely need the sign-in.
        return .failed(config, .signedOut, note: error.isExpiredLogin
            ? "Expired — sign in, or run any \(config.name) command"
            : "Signed out — sign in to see usage again")
    }
    if error.isRateLimited {
        return .failed(config, .rateLimited,
                       note: "Rate-limited — \(config.name) won't report quota right now")
    }
    if error.isAccessDenied {
        return .failed(config, .refused,
                       note: "\(error) — this account has no usage access. Check its subscription.")
    }
    if error.isServerUnreachable {
        return .failed(config, .offline, note: "Offline — can't reach \(config.name)")
    }
    return nil
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

/// Streams a file line by line in bounded chunks. Transcript trees hold files
/// running to hundreds of MB, so materializing a whole file as one String (the
/// obvious `Data(contentsOf:)` + split) spiked memory on every cache miss;
/// this keeps the high-water mark at ~chunk size + the longest line.
private func forEachLine(of url: URL, _ body: (String) -> Void) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }
    let chunkSize = 4 << 20 // 4 MiB
    let newline: UInt8 = 0x0A

    func emit(_ lineData: Data) {
        guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { return }
        body(line)
    }

    var buffer = Data()
    while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
        buffer.append(chunk)
        guard let lastNewline = buffer.lastIndex(of: newline) else { continue }
        for lineData in buffer[..<lastNewline].split(separator: newline) {
            emit(Data(lineData))
        }
        buffer = Data(buffer[buffer.index(after: lastNewline)...])
    }
    for lineData in buffer.split(separator: newline) {
        emit(Data(lineData))
    }
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

/// Formats reset times for captions ("resets Mon 3:00 PM"). Locale pinned to
/// en_US_POSIX because the app's strings are English (see CONTRIBUTING.md) and
/// the output is persisted into cached readings — a locale change mid-cache
/// would mix formats. Only ever touched from the engine's work queue.
private let resetFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
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

/// Memoizes `computeGameStats` per log root. The sweep is stat-only but walks
/// the provider's *entire* log tree (tens of thousands of files on a heavy
/// install), which is too much to repeat on every 60s refresh — and the stats
/// move on the scale of days, so a few minutes of staleness is invisible.
/// Only ever touched from the engine's work queue (or the one-shot `--print`).
private nonisolated(unsafe) var gameStatsCache: [String: (computedAt: Date, stats: GameStats?)] = [:]
private let gameStatsInterval: TimeInterval = 10 * 60

/// Whole-history metadata sweep → stateless idle-game stats. Sums log-file
/// sizes (lifetime bytes, drives level + XP) and collects active local-calendar
/// days from mtimes (drives the streak). Reads no file *contents* — just the
/// `stat` metadata `jsonlFiles` already prefetches — so it stays cheap and
/// monotonic. Returns nil when the log tree doesn't exist yet.
func computeGameStats(root: URL, now: Date) -> GameStats? {
    if let hit = gameStatsCache[root.path], now.timeIntervalSince(hit.computedAt) < gameStatsInterval {
        return hit.stats
    }
    let stats = sweepGameStats(root: root, now: now)
    gameStatsCache[root.path] = (now, stats)
    return stats
}

private func sweepGameStats(root: URL, now: Date) -> GameStats? {
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

/// Shared local-token estimation for transcript-style providers (Claude, Kimi):
/// scan recent jsonl files under `root`, merge per-file hour buckets through the
/// parse cache, and evaluate session/weekly percentages against the historical
/// peak (see `TokenWindowEstimator`). The per-provider differences — which files
/// count, how a line parses, how the weekly rows are labeled — ride in as
/// parameters, so a new estimated provider is a parse function plus this call.
private func estimateSnapshot(
    config: ProviderConfig, app: AppConfig, cache: inout FileBucketCache,
    now: Date, root: URL,
    historyNoun: String,
    fileFilter: (CandidateFile) -> Bool = { _ in true },
    parse: (URL) -> HourBuckets,
    sessionWindowSeconds: Double? = nil,
    mapWeekly: ([WeeklyMetric]) -> [WeeklyMetric] = { $0 }
) -> ProviderSnapshot {
    guard FileManager.default.fileExists(atPath: root.path) else {
        return .empty(config, note: "No \(historyNoun) yet in \(config.dir)")
    }
    let files = jsonlFiles(under: root, modifiedWithinDays: TokenWindowEstimator.scanWindowDays)
        .filter(fileFilter)
    guard !files.isEmpty else {
        return .empty(config, note: "No recent activity in \(config.dir)")
    }

    var merged: HourBuckets = [:]
    for file in files {
        let buckets = cache.buckets(for: file.url, mtime: file.mtime, size: file.size, parse: parse)
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
        weekly: mapWeekly(result.weekly), isActive: active, isEstimated: true,
        sessionWindowSeconds: sessionWindowSeconds, note: nil
    )
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
                    resetText: weeklyResetText(week.resetsAt),
                    resetAt: week.resetsAt
                ))
            }
            for (label, window) in usage.sevenDayModels {
                weekly.append(WeeklyMetric(
                    label: label, pct: window.usedPct,
                    resetText: weeklyResetText(window.resetsAt),
                    resetAt: window.resetsAt
                ))
            }
            return ProviderSnapshot(
                config: config,
                sessionPct: usage.fiveHour?.usedPct ?? 0,
                sessionResetAt: sessionReset(usage.fiveHour),
                weekly: WeeklyMetric.dedupingLabels(weekly),
                isActive: recentActivity(under: projectsRoot, now: now),
                isEstimated: false,
                sessionWindowSeconds: usage.fiveHour?.windowSeconds,
                plan: usage.planLabel
            )
        }, fallback: { error in
            // Claude has no real offline source — only the "vs your busiest week"
            // token estimate, which trends to 100% by construction. So any failure
            // that means "there is no quota to read here" (lapsed login, refused
            // account, standing 429, dead endpoint) shows as an error instead: a
            // fabricated 100% reads exactly like a maxed real limit. Transient 429s
            // already rode out on the cached real reading up in apiFirst.
            if var failed = failureSnapshot(error, config: config) {
                // The plan pill comes from the keychain, which no API failure
                // touches — keep it so the card still says which plan is broken.
                failed.plan = ClaudeUsageAPI.planLabel(configDir: config.expandedDir)
                return failed
            }
            return estimateSnapshot(
                config: config, app: app, cache: &fileCache, now: now, root: projectsRoot,
                historyNoun: "transcripts", parse: Self.parse,
                sessionWindowSeconds: app.sessionHours * 3600
            )
        })
        snap.game = computeGameStats(root: projectsRoot, now: now)
        return snap
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
    /// A per-model cap, labelled and classified by the span the API reports for it.
    private func extraMetric(name: String, window w: UsageWindow) -> WeeklyMetric {
        let isWeekly = LimitWindow.isWeekly(seconds: w.windowSeconds)
        return WeeklyMetric(
            label: "\(name) · \(LimitWindow.name(seconds: w.windowSeconds).lowercased())",
            pct: w.usedPct,
            resetText: isWeekly
                ? weeklyResetText(w.resetsAt)
                : w.resetsAt.map { "Resets \(resetFormatter.string(from: $0))" } ?? "",
            resetAt: w.resetsAt,
            isWeeklyWindow: isWeekly
        )
    }

    func read(config: ProviderConfig, app: AppConfig, ctx: inout ReaderContext, now: Date) -> ProviderSnapshot {
        let sessionsRoot = URL(fileURLWithPath: config.expandedDir).appendingPathComponent("sessions")
        var snap = apiFirst(config: config, ctx: &ctx, now: now, fetch: {
            let usage = try CodexUsageAPI.fetch(configDir: config.expandedDir)
            var weekly: [WeeklyMetric] = []
            if let week = usage.secondary {
                weekly.append(WeeklyMetric(
                    label: "Weekly", pct: week.usedPct,
                    resetText: weeklyResetText(week.resetsAt),
                    resetAt: week.resetsAt
                ))
            }
            for extra in usage.additional {
                // Both slots are named for the span the API reports, not for the
                // field they arrived in — Codex serves 7-day caps in `primary_window`.
                if let w = extra.fiveHour, w.usedPct > 0 || extra.weekly == nil {
                    weekly.append(extraMetric(name: extra.name, window: w))
                }
                if let w = extra.weekly {
                    weekly.append(extraMetric(name: extra.name, window: w))
                }
            }
            return ProviderSnapshot(
                config: config,
                sessionPct: usage.primary?.usedPct ?? 0,
                sessionResetAt: sessionReset(usage.primary),
                weekly: WeeklyMetric.dedupingLabels(Array(weekly.prefix(4))),
                isActive: recentActivity(under: sessionsRoot, now: now),
                isEstimated: false,
                sessionWindowSeconds: usage.primary?.windowSeconds,
                plan: usage.planLabel,
                resetCredits: usage.resetCredits
            )
        }, fallback: { error in
            // Codex rollout files carry real rate_limits events, so the offline
            // fallback is genuine data (not an estimate) even when auth lapses or
            // the server is unreachable — keep showing it (aged) rather than dead.
            if let real = rolloutFallback(config: config, now: now, root: sessionsRoot) {
                return real
            }
            // Nothing on disk either, so the failure is all there is to report.
            // Anything we can't classify is just an empty profile.
            return failureSnapshot(error, config: config)
                ?? .empty(config, note: "No rate-limit history in \(config.dir)")
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

        // Files are newest-mtime-first, so the first file that holds any
        // rate_limits event wins — its mtime bounds every event inside it, making
        // it at least as fresh as anything an older file could hold. The prefix
        // caps the tail-reads when many recent rollouts carry no limits at all.
        var best: (date: Date, limits: [String: Any])?
        for file in files.prefix(12) {
            if let found = Self.lastRateLimits(in: file.url) {
                best = found
                break
            }
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
                    resetText: weeklyResetText(week.resetsAt),
                    resetAt: week.resetsAt
                ))
            }
            for (label, window) in usage.shortWindows.dropFirst() {
                weekly.append(WeeklyMetric(
                    label: label, pct: window.usedPct,
                    resetText: window.resetsAt.map { "Resets \(resetFormatter.string(from: $0))" } ?? "",
                    resetAt: window.resetsAt, isWeeklyWindow: false
                ))
            }
            return ProviderSnapshot(
                config: config,
                sessionPct: session?.usedPct ?? 0,
                sessionResetAt: sessionReset(session),
                weekly: WeeklyMetric.dedupingLabels(weekly),
                isActive: recentActivity(under: sessionsRoot, now: now),
                isEstimated: false,
                sessionWindowSeconds: session?.windowSeconds,
                plan: usage.planLabel
            )
        }, fallback: { error in
            // Same rule as Claude: the local estimate is only an offline safety net,
            // never a stand-in for an account whose quota we've been told we can't
            // read (see `failureSnapshot`).
            if let failed = failureSnapshot(error, config: config) { return failed }
            return estimateSnapshot(
                config: config, app: app, cache: &fileCache, now: now, root: sessionsRoot,
                historyNoun: "sessions",
                fileFilter: { $0.url.lastPathComponent == "wire.jsonl" },
                parse: Self.parse,
                // Kimi logs don't split by model; keep just the aggregate row.
                mapWeekly: { weekly in
                    weekly.filter { $0.label == "All models" }
                        .map { WeeklyMetric(label: "Weekly", pct: $0.pct, resetText: $0.resetText) }
                }
            )
        })
        snap.game = computeGameStats(root: sessionsRoot, now: now)
        return snap
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
