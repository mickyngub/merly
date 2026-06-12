// Models.swift — provider configuration and usage snapshot types.

import Foundation

enum ProviderKind: String, Codable, CaseIterable {
    /// Claude Code-style config dir: transcripts under projects/**/*.jsonl
    case claude
    /// Codex CLI: rollout files under sessions/YYYY/MM/DD/*.jsonl with real rate_limits
    case codex
    /// Kimi Code: wire.jsonl event logs under sessions/wd_*/ses_*/agents/*
    case kimi

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .kimi: "Kimi"
        }
    }

    /// Where the matching CLI keeps its config by default.
    var defaultDir: String {
        switch self {
        case .claude: "~/.claude"
        case .codex: "~/.codex"
        case .kimi: "~/.kimi-code"
        }
    }

    var defaultPaletteName: String {
        switch self {
        case .claude: "coral"
        case .codex: "green"
        case .kimi: "purple"
        }
    }
}

struct ProviderConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var account: String
    var kind: ProviderKind
    var dir: String
    var style: MascotStyle?
    var palette: String?
    /// Bundled sprite-sheet basename (4×4 grid: rows = mood, cols = idle frames).
    /// When resolvable, the panel mascot renders this art instead of the drawn critter.
    var sprite: String?
    /// Optional fixed denominators for token-estimated providers. When absent,
    /// limits auto-calibrate to the busiest 5h block / 7-day stretch on record.
    var sessionTokenLimit: Int?
    var weeklyTokenLimit: Int?

    var expandedDir: String {
        (dir as NSString).expandingTildeInPath
    }

    var resolvedStyle: MascotStyle {
        if let style { return style }
        switch kind {
        case .claude: return .cat
        case .codex: return .robot
        case .kimi: return .round
        }
    }

    var resolvedPalette: MascotPalette {
        if let palette { return MascotPalette.preset(palette) }
        switch kind {
        case .claude: return MascotPalette.preset("coral")
        case .codex: return MascotPalette.preset("green")
        case .kimi: return MascotPalette.preset("purple")
        }
    }

    /// Sprite sheet to render in the panel, falling back to the per-kind default
    /// art. Returns nil only if a provider explicitly opts out via sprite: "".
    var resolvedSprite: String? {
        if let sprite { return sprite.isEmpty ? nil : sprite }
        switch kind {
        case .claude: return "clawd-sprite"
        case .codex: return "codex-sprite"
        case .kimi: return "kimi-sprite"
        }
    }
}

struct WeeklyMetric: Identifiable, Equatable, Codable {
    var label: String
    var pct: Double
    var resetText: String
    var id: String { label }
}

struct ProviderSnapshot: Identifiable, Equatable {
    var config: ProviderConfig
    /// 0–100 "used" figure for the current session window.
    var sessionPct: Double
    /// When the current session window resets; nil when no session is active.
    var sessionResetAt: Date?
    var weekly: [WeeklyMetric]
    /// Activity within the last couple of minutes (drives the green ping dot).
    var isActive: Bool
    /// True when the percentage is a local-token estimate rather than a
    /// provider-reported rate limit.
    var isEstimated: Bool
    /// True when these are the last *real* API numbers, served because the live
    /// fetch failed transiently (e.g. HTTP 429). Real, just not fresh.
    var isStale: Bool = false
    /// Optional note (e.g. Codex plan type, or why data is missing).
    var note: String?

    var id: String { config.id }

    /// How close this provider is to *any* of its limits — a session can be
    /// fresh (0%) while the weekly cap is nearly exhausted. Drives the mascot
    /// mood and the menu bar peak pick. Estimates use the session figure only:
    /// the estimated weekly bars are "vs your busiest week" ratios that trend
    /// to 100% by construction, so they must not drive a stressed mood.
    var pressurePct: Double {
        isEstimated ? sessionPct : max(sessionPct, weekly.map(\.pct).max() ?? 0)
    }
    var mood: Mood { Mood.from(pct: pressurePct) }

    static func empty(_ config: ProviderConfig, note: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            config: config, sessionPct: 0, sessionResetAt: nil,
            weekly: [], isActive: false, isEstimated: true, note: note
        )
    }

    /// The real numbers worth caching to ride out a transient API failure.
    func realReading(at now: Date) -> RealReading? {
        guard !isEstimated, !isStale else { return nil }
        return RealReading(
            sessionPct: sessionPct, sessionResetAt: sessionResetAt,
            weekly: weekly, planNote: note, capturedAt: now
        )
    }

    /// Rebuild a snapshot from a cached real reading, flagged stale with an age.
    static func fromCache(_ reading: RealReading, config: ProviderConfig, now: Date) -> ProviderSnapshot {
        let age = Int(now.timeIntervalSince(reading.capturedAt) / 60)
        let ageText = age < 1 ? "moments ago" : age < 60 ? "\(age)m ago" : "\(age / 60)h ago"
        let note = [reading.planNote, "as of \(ageText)"].compactMap(\.self).joined(separator: " · ")
        return ProviderSnapshot(
            config: config, sessionPct: reading.sessionPct, sessionResetAt: reading.sessionResetAt,
            weekly: reading.weekly, isActive: false, isEstimated: false, isStale: true, note: note
        )
    }
}

/// Persisted last-good API reading, used to survive a transient fetch failure
/// instead of dropping to misleading local estimates.
struct RealReading: Codable {
    var sessionPct: Double
    var sessionResetAt: Date?
    var weekly: [WeeklyMetric]
    var planNote: String?
    var capturedAt: Date
}

/// Mutable state threaded through a refresh pass: the file-parse cache, the
/// last-good readings, and per-provider API cooldowns (set after a 429 so we
/// stop hammering an endpoint that's already rate-limiting us).
struct ReaderContext {
    var fileCache: FileBucketCache
    var lastGood: [String: RealReading]
    var cooldownUntil: [String: Date]
}

enum LastGoodStore {
    static var file: URL { AppPaths.supportDir.appendingPathComponent("last-good.json") }

    static func load() -> [String: RealReading] {
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONDecoder().decode([String: RealReading].self, from: data)
        else { return [:] }
        return dict
    }

    static func save(_ dict: [String: RealReading]) {
        try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: file)
        }
    }
}

/// User-tunable alerting. Persisted inside AppConfig so it rides the same
/// providers.json the engine reloads every refresh.
struct NotificationSettings: Codable, Equatable {
    /// Master switch for all usage alerts.
    var enabled: Bool = false
    /// Notify when a provider's closest-limit pressure first crosses this %.
    var thresholdPct: Double = 80
    /// Notify when a previously-busy session window resets and frees up.
    var notifyOnReset: Bool = true
}

struct AppConfig: Codable {
    var sessionHours: Double
    var refreshSeconds: Double
    var providers: [ProviderConfig]
    /// Optional so configs written before alerts existed still decode (a missing
    /// key would otherwise throw and wipe the user's providers back to default).
    var notifications: NotificationSettings?

    /// Always-present view of the alert settings, defaulting when absent.
    var notificationSettings: NotificationSettings {
        get { notifications ?? NotificationSettings() }
        set { notifications = newValue }
    }

    static let `default` = AppConfig(
        sessionHours: 5,
        refreshSeconds: 60,
        providers: [
            ProviderConfig(id: "claude-personal", name: "Claude", account: "Personal",
                           kind: .claude, dir: "~/.claude", style: .cat, palette: "coral"),
            ProviderConfig(id: "claude-work", name: "Claude", account: "Work",
                           kind: .claude, dir: "~/.claude-work", style: .catTie, palette: "steel",
                           sprite: "clawd-work-sprite"),
            ProviderConfig(id: "codex", name: "Codex", account: "OpenAI",
                           kind: .codex, dir: "~/.codex", style: .robot, palette: "green"),
            ProviderConfig(id: "kimi", name: "Kimi", account: "Moonshot",
                           kind: .kimi, dir: "~/.kimi-code", style: .round, palette: "purple"),
        ],
        notifications: NotificationSettings()
    )
}

enum AppPaths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Lens", isDirectory: true)
    }
    static var configFile: URL { supportDir.appendingPathComponent("providers.json") }
    static var cacheFile: URL { supportDir.appendingPathComponent("usage-cache.json") }
}

enum ConfigStore {
    static func load() -> AppConfig {
        let url = AppPaths.configFile
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config
        }
        let config = AppConfig.default
        save(config)
        return config
    }

    static func save(_ config: AppConfig) {
        try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: AppPaths.configFile)
        }
    }
}
