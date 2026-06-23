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

    /// Sprite sheets this kind's mascot may use — its own family only, so the
    /// editor can't dress a Claude provider up as Codex/Kimi. One art per kind:
    /// color is set by the palette (the old "Work" sprite was just a blue Clawd).
    var spriteFamily: [(id: String, label: String)] {
        switch self {
        case .claude: [("clawd-sprite", "Clawd")]
        case .codex: [("codex-sprite", "Codex")]
        case .kimi: [("kimi-sprite", "Kimi")]
        }
    }
}

/// The app's own mascot, shown in the menu bar ("topnav"). Independent of any
/// provider; its look is user-editable while its mood tracks the busiest
/// provider's pressure.
struct DefaultMascot: Codable, Equatable {
    var style: MascotStyle
    /// User-chosen index into the fated deck (see `Fate`). The deck's *hues* are
    /// fixed per machine; only this mapping is editable. Optional so older configs
    /// decode (absent → the signature slot 0).
    var colorSlot: Int?
    /// Bundled sprite-sheet basename; "" renders the drawn critter instead.
    var sprite: String

    static let standard = DefaultMascot(style: .cat, sprite: "clawd-sprite")

    /// Sprite sheet to render, or nil when drawing the critter.
    var resolvedSprite: String? { sprite.isEmpty ? nil : sprite }

    /// The menu bar mascot sits in deck slot 0 by default — the install's
    /// signature hue — so adding or removing providers never recolors it.
    var resolvedColorSlot: Int { colorSlot ?? 0 }

    /// Fate's one-shot shiny verdict for the menu bar mascot.
    var isShiny: Bool { Fate.isShiny(id: "menu-bar-mascot") }

    var resolvedPalette: MascotPalette { Fate.palette(slot: resolvedColorSlot, shiny: isShiny) }
}

/// Per-install destiny for a mascot's color and shininess. Everything derives
/// deterministically from the home path — there is no stored seed, so a mascot's
/// fate can't be re-rolled by deleting or editing providers.json. Reinstalling
/// macOS or changing username gives a new fate; that's the only thing that does.
///
/// **Color** is a "deck": one signature `base` hue per machine, then evenly
/// spread golden-angle hues for each `slot`. The deck's hues are fixed; which
/// `slot` a mascot wears is the only editable part (stored as `colorSlot`).
///
/// **Shiny** is a one-shot lottery keyed by mascot id (independent of color, so a
/// mascot's luck never changes when others are added, removed, or recolored). The
/// lucky few wear a gleaming `+150°` variant. No accumulation, no "moment of
/// catching" — you either were born lucky on this machine or you weren't.
enum Fate {
    /// How many distinct hues the editor offers (the golden-angle deck size).
    static let deckSize = 6
    /// The most-separated rotation increment — successive slots are maximally apart.
    static let goldenAngle = 137.50776405003785

    /// 1-in-N one-shot shiny odds. `LENS_SHINY_RARITY` overrides it for tuning or
    /// testing (set it to 1 to make every mascot shiny).
    static var rarity: UInt64 {
        if let raw = ProcessInfo.processInfo.environment["LENS_SHINY_RARITY"],
           let n = UInt64(raw), n >= 1 { return n }
        return 128
    }

    /// The install's signature hue (0..<360), hashed from the home path.
    static func baseHue(home: String = NSHomeDirectory()) -> Double {
        Double(hash(home) % 360)
    }

    /// Golden-angle deck hue for `slot`: base + slot×137.5°. Evenly spread and
    /// append-stable — a new mascot takes the next slot without moving earlier ones.
    static func deckHue(slot: Int, home: String = NSHomeDirectory()) -> Double {
        (baseHue(home: home) + Double(slot) * goldenAngle)
            .truncatingRemainder(dividingBy: 360)
    }

    /// The resolved palette for a mascot in `slot`, gleaming if `shiny`.
    static func palette(slot: Int, shiny: Bool, home: String = NSHomeDirectory()) -> MascotPalette {
        let hue = deckHue(slot: slot, home: home)
        return shiny
            ? .fromHue(hue + 150, satBoost: 0.08, lightBoost: 0.04)
            : .fromHue(hue)
    }

    /// One-shot shiny verdict, keyed by mascot id. Stable forever.
    static func isShiny(id: String, home: String = NSHomeDirectory()) -> Bool {
        hash("\(home)|\(id)|shiny") % rarity == 0
    }

    /// Stable per-id deck slot, used only as a safety fallback when a mascot has
    /// no stored slot yet (normal slots are assigned at creation/migration).
    static func fallbackSlot(id: String, home: String = NSHomeDirectory()) -> Int {
        Int(hash("\(home)|\(id)|slot") % UInt64(deckSize))
    }

    /// FNV-1a over the string's UTF-8 → uniform-ish 64-bit.
    private static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

struct ProviderConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var account: String
    var kind: ProviderKind
    var dir: String
    var style: MascotStyle?
    /// User-chosen index into the fated deck (see `Fate`); the deck's hues are
    /// fixed per machine, only this mapping is editable. Optional so older configs
    /// decode (absent → a slot assigned by position on first load).
    var colorSlot: Int?
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

    /// The deck slot this provider wears, falling back to a stable per-id slot
    /// until the position-based default is persisted (see `ConfigStore.migrate`).
    var resolvedColorSlot: Int { colorSlot ?? Fate.fallbackSlot(id: id) }

    /// Fate's one-shot shiny verdict for this provider.
    var isShiny: Bool { Fate.isShiny(id: id) }

    var resolvedPalette: MascotPalette { Fate.palette(slot: resolvedColorSlot, shiny: isShiny) }

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
    /// True when the provider's login lapsed (token expired / signed out) and we
    /// have no fresh real reading to fall back on — so there is genuinely *no
    /// data*. The card shows a "No data" state and the mascot goes `.dead`
    /// instead of inventing a "vs your busiest week" estimate that reads as real.
    var isUnavailable: Bool = false
    /// Optional note (e.g. why data is missing, or how fresh a cached reading is).
    var note: String?
    /// The provider's subscription tier (e.g. "Max (20x)", "Pro", "Team (5x)"),
    /// shown as a pill beside the provider name. Nil when the provider exposes no
    /// plan info (token-estimated providers) or its login has lapsed.
    var plan: String? = nil

    var id: String { config.id }

    /// How close this provider is to *any* of its limits — a session can be
    /// fresh (0%) while the weekly cap is nearly exhausted. Drives the mascot
    /// mood and the menu bar peak pick. Estimates use the session figure only:
    /// the estimated weekly bars are "vs your busiest week" ratios that trend
    /// to 100% by construction, so they must not drive a stressed mood.
    var pressurePct: Double {
        if isUnavailable { return 0 } // no data → no pressure (never the menu-bar peak)
        return isEstimated ? sessionPct : max(sessionPct, weekly.map(\.pct).max() ?? 0)
    }
    var mood: Mood {
        if isUnavailable { return .dead }
        if !isActive && !isEstimated && pressurePct < 5 { return .sleeping }
        if isActive && pressurePct < 15 { return .excited }
        return Mood.from(pct: pressurePct)
    }

    static func empty(_ config: ProviderConfig, note: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            config: config, sessionPct: 0, sessionResetAt: nil,
            weekly: [], isActive: false, isEstimated: true, note: note
        )
    }

    /// No usable data: the login lapsed and there's no fresh real reading to
    /// show. Renders as a "No data" card with the `.dead` mascot.
    static func unavailable(_ config: ProviderConfig, note: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            config: config, sessionPct: 0, sessionResetAt: nil,
            weekly: [], isActive: false, isEstimated: false,
            isUnavailable: true, note: note
        )
    }

    /// The real numbers worth caching to ride out a transient API failure.
    func realReading(at now: Date) -> RealReading? {
        guard !isEstimated, !isStale, !isUnavailable else { return nil }
        return RealReading(
            sessionPct: sessionPct, sessionResetAt: sessionResetAt,
            weekly: weekly, planNote: plan, capturedAt: now
        )
    }

    /// Rebuild a snapshot from a cached real reading, flagged stale with an age.
    static func fromCache(_ reading: RealReading, config: ProviderConfig, now: Date) -> ProviderSnapshot {
        let age = Int(now.timeIntervalSince(reading.capturedAt) / 60)
        let ageText = age < 1 ? "moments ago" : age < 60 ? "\(age)m ago" : "\(age / 60)h ago"
        return ProviderSnapshot(
            config: config, sessionPct: reading.sessionPct, sessionResetAt: reading.sessionResetAt,
            weekly: reading.weekly, isActive: false, isEstimated: false, isStale: true,
            note: "as of \(ageText)", plan: reading.planNote
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
    /// Optional so older configs decode; falls back to `.standard` when absent.
    var defaultMascot: DefaultMascot?

    /// Always-present view of the alert settings, defaulting when absent.
    var notificationSettings: NotificationSettings {
        get { notifications ?? NotificationSettings() }
        set { notifications = newValue }
    }

    /// Always-present view of the menu bar mascot, defaulting when absent.
    var defaultMascotConfig: DefaultMascot {
        get { defaultMascot ?? .standard }
        set { defaultMascot = newValue }
    }

    /// Every coding CLI Lens can set up out of the box, paired with the on-disk
    /// markers that prove the CLI is actually configured. Markers are specific
    /// files (not just the dir), so a dir that merely holds a symlinked
    /// `skills/` folder isn't mistaken for a real install. Drives both the
    /// static default and first-run auto-detection.
    static let knownProviders: [(config: ProviderConfig, markers: [String])] = [
        (ProviderConfig(id: "claude-personal", name: "Claude", account: "Personal",
                        kind: .claude, dir: "~/.claude", style: .cat, colorSlot: 1),
         ["~/.claude/projects", "~/.claude.json"]),
        (ProviderConfig(id: "claude-work", name: "Claude", account: "Work",
                        kind: .claude, dir: "~/.claude-work", style: .catTie, colorSlot: 2),
         ["~/.claude-work/projects", "~/.claude-work.json"]),
        (ProviderConfig(id: "codex", name: "Codex", account: "OpenAI",
                        kind: .codex, dir: "~/.codex", style: .robot, colorSlot: 3),
         ["~/.codex/auth.json"]),
        (ProviderConfig(id: "kimi", name: "Kimi", account: "Moonshot",
                        kind: .kimi, dir: "~/.kimi-code", style: .round, colorSlot: 4),
         ["~/.kimi-code/credentials/kimi-code.json"]),
    ]

    /// First-run discovery: keep only providers whose marker exists on disk.
    static func autodetectedProviders() -> [ProviderConfig] {
        knownProviders
            .filter { $0.markers.contains { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) } }
            .map(\.config)
    }

    /// Static fallback used when auto-detection finds nothing, so a brand-new
    /// install isn't an empty window.
    static let `default` = AppConfig(
        sessionHours: 5,
        refreshSeconds: 60,
        providers: knownProviders.map(\.config),
        notifications: NotificationSettings(),
        defaultMascot: .standard
    )

    /// The config to write on first launch: detected providers when any CLI is
    /// found, otherwise the static default.
    static func firstRun() -> AppConfig {
        let detected = autodetectedProviders()
        guard !detected.isEmpty else { return .default }
        return AppConfig(
            sessionHours: 5, refreshSeconds: 60, providers: detected,
            notifications: NotificationSettings(), defaultMascot: .standard
        )
    }
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
           var config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            if migrate(&config) { save(config) }
            return config
        }
        let config = AppConfig.firstRun()
        save(config)
        return config
    }

    /// Normalize retired identifiers so old configs keep resolving. The "Work"
    /// Claude sprite was a recolored Clawd; now that any sprite follows the
    /// palette, it collapses to "clawd-sprite" (its steel palette still tints it
    /// blue). Returns true when something changed, so the caller can persist.
    private static func migrate(_ config: inout AppConfig) -> Bool {
        var changed = false
        for i in config.providers.indices where config.providers[i].sprite == "clawd-work-sprite" {
            config.providers[i].sprite = "clawd-sprite"
            changed = true
        }
        if config.defaultMascot?.sprite == "clawd-work-sprite" {
            config.defaultMascot?.sprite = "clawd-sprite"
            changed = true
        }
        // Assign each mascot a default deck slot by position the first time we see
        // a config without one (menu bar = 0; providers spread 1..N). The slot is
        // editable afterward; the deck's hues stay fated. See `Fate`.
        for i in config.providers.indices where config.providers[i].colorSlot == nil {
            config.providers[i].colorSlot = (i + 1) % Fate.deckSize
            changed = true
        }
        if config.defaultMascot != nil, config.defaultMascot?.colorSlot == nil {
            config.defaultMascot?.colorSlot = 0
            changed = true
        }
        return changed
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
