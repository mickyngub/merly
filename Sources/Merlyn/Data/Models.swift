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

    /// The CLI subcommand that starts this kind's own sign-in flow.
    ///
    /// Merlyn never mints or refreshes a token itself — see the never-refresh rule
    /// in `docs/decisions/usage-readers`. The sign-in button runs the CLI's login
    /// in a terminal and lets it own the credentials, exactly as if the user had
    /// opened the agent and typed this.
    var loginCommand: String {
        switch self {
        case .claude: "claude auth login"
        case .codex: "codex login"
        case .kimi: "kimi login"
        }
    }

    /// Env var that points this kind's CLI at a non-default config dir, so a
    /// second account (`~/.claude-2`, `~/.claude-work`) signs into its own profile
    /// instead of overwriting the first. nil when the CLI has no such override.
    var configDirEnvVar: String? {
        switch self {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        case .kimi: nil
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

    static let standard = DefaultMascot(style: .cat, sprite: "merlyn-sprite")

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

    /// 1-in-N one-shot shiny odds. `MERLYN_SHINY_RARITY` overrides it for tuning or
    /// testing (set it to 1 to make every mascot shiny).
    static var rarity: UInt64 {
        if let raw = ProcessInfo.processInfo.environment["MERLYN_SHINY_RARITY"],
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

    /// The hue a mascot actually wears: its deck hue, shifted for a shiny. Exposed
    /// so anything deriving companion colours (the card's ring lanes) starts from
    /// the same hue the mascot is wearing rather than the unshifted deck value.
    static func hue(slot: Int, shiny: Bool, home: String = NSHomeDirectory()) -> Double {
        deckHue(slot: slot, home: home) + (shiny ? 150 : 0)
    }

    /// The resolved palette for a mascot in `slot`, gleaming if `shiny`.
    static func palette(slot: Int, shiny: Bool, home: String = NSHomeDirectory()) -> MascotPalette {
        let hue = hue(slot: slot, shiny: shiny, home: home)
        return shiny
            ? .fromHue(hue, satBoost: 0.08, lightBoost: 0.04)
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

    /// The shell line that signs this specific provider back in: the CLI's own
    /// login, prefixed with the config-dir env var when this provider doesn't live
    /// in the kind's default folder (a second account signs into its own profile).
    var loginShellCommand: String {
        guard dir != kind.defaultDir, let envVar = kind.configDirEnvVar else {
            return kind.loginCommand
        }
        return "\(envVar)=\(expandedDir.shellQuoted) \(kind.loginCommand)"
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

/// Naming and classifying a limit window by the span the provider reports.
///
/// Nothing may hardcode "5h" or "weekly" from a field's name: Codex moved its
/// primary window from 5h to 7 days with no rename, so every label built on that
/// assumption ("5h limit · resets in 3d 18h") started lying.
enum LimitWindow {
    /// "5h", "24h", "3d", "Weekly" — what to call a window of this length.
    /// Defaults to "5h" when a provider reports no span, which is what every
    /// primary window was before Codex changed.
    static func name(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "5h" }
        let hours = seconds / 3600
        if hours >= 144 { return "Weekly" }
        if hours >= 48 { return "\(Int((hours / 24).rounded()))d" }
        if hours >= 1 { return "\(Int(hours.rounded()))h" }
        return "\(Int((seconds / 60).rounded()))m"
    }

    /// Long enough to be a standing budget rather than a rolling session. Drives
    /// the ring's lane order and the card's "what's blocking you" wording.
    static func isWeekly(seconds: Double?) -> Bool { (seconds ?? 0) >= 48 * 3600 }
}

struct WeeklyMetric: Identifiable, Equatable, Codable {
    var label: String
    var pct: Double
    var resetText: String
    /// When this window rolls over, for the card's "what's blocking you" line.
    /// Optional: estimated metrics have no real reset, and cached readings written
    /// before this field existed decode without it.
    var resetAt: Date? = nil
    /// Whether this is a rolling *weekly* cap. Codex and Kimi both report extra
    /// short windows in this same list, so the card can't assume weekly.
    /// nil ⇒ weekly, which every metric but those is.
    var isWeeklyWindow: Bool? = nil

    var isWeekly: Bool { isWeeklyWindow ?? true }
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
    /// Span of the primary window `sessionPct` measures, when the provider reports
    /// one. Not always 5h — see `LimitWindow`.
    var sessionWindowSeconds: Double? = nil
    /// True when these are the last *real* API numbers, served because the live
    /// fetch failed transiently (e.g. HTTP 429). Real, just not fresh.
    var isStale: Bool = false
    /// True when the provider's login lapsed (token expired / signed out) and we
    /// have no fresh real reading to fall back on — so there is genuinely *no
    /// data*. The card shows a "No data" state and the mascot goes `.dead`
    /// instead of inventing a "vs your busiest week" estimate that reads as real.
    var isUnavailable: Bool = false
    /// True when the reader failed specifically because this provider's login
    /// lapsed — as opposed to the server being unreachable or rate-limiting us,
    /// where signing in again would change nothing. Only this state offers the
    /// card's sign-in button.
    var needsSignIn: Bool = false
    /// Optional note (e.g. why data is missing, or how fresh a cached reading is).
    var note: String?
    /// The provider's subscription tier (e.g. "Max (20x)", "Pro", "Team (5x)"),
    /// shown as a pill beside the provider name. Nil when the provider exposes no
    /// plan info (token-estimated providers) or its login has lapsed.
    var plan: String? = nil
    /// Derived idle-game stats (level, XP, streak, evolution form) computed from
    /// the provider's lifetime log metadata. Stored, not computed: it needs file
    /// I/O, so the reader fills it on the work queue (never lazily on the main
    /// thread). Nil until computed / when the log tree is empty.
    var game: GameStats? = nil

    var id: String { config.id }

    /// Sprite sheet for the mascot's current evolution form, degrading to the
    /// highest *available* lower form (and finally the base sheet) so the app
    /// works before any tier art is bundled. Mood still picks the row; form
    /// picks the sheet.
    var resolvedSpriteForm: String? {
        SpriteSheetStore.formSprite(base: config.resolvedSprite, form: game?.form ?? 0)
    }

    /// How close this provider is to *any* of its limits — a session can be
    /// fresh (0%) while the weekly cap is nearly exhausted. Drives the mascot
    /// mood and the menu bar peak pick. Estimates use the session figure only:
    /// the estimated weekly bars are "vs your busiest week" ratios that trend
    /// to 100% by construction, so they must not drive a stressed mood.
    var pressurePct: Double {
        if isUnavailable { return 0 } // no data → no pressure (never the menu-bar peak)
        return isEstimated ? sessionPct : max(sessionPct, weekly.map(\.pct).max() ?? 0)
    }
    /// What to call the primary window: "5h" for a rolling session, "Weekly" for a
    /// provider like Codex whose primary limit spans 7 days.
    var primaryWindowName: String { LimitWindow.name(seconds: sessionWindowSeconds) }

    /// True when the primary window is short enough to be a "current session".
    var hasSessionWindow: Bool { !LimitWindow.isWeekly(seconds: sessionWindowSeconds) }

    /// The reported window closest to full, when it outranks the 5h session — the
    /// limit that actually gates the next request, and so the one the ring
    /// reports. nil for estimates: their weekly bars are "vs your busiest week"
    /// ratios that trend to 100% by construction and must not headline the card.
    var bindingLimit: WeeklyMetric? {
        guard !isEstimated, !isUnavailable,
              let worst = weekly.max(by: { $0.pct < $1.pct }),
              worst.pct > sessionPct
        else { return nil }
        return worst
    }

    /// The limit that has actually run out, when one has. It owns the card's clock
    /// line: an exhausted weekly cap blocks the next request however fresh the 5h
    /// window is, and "No active session" there read as "go ahead".
    ///
    /// Exhausted, not merely red: at 94% weekly the provider still works, so the
    /// line stays on the session countdown and the red ring carries the warning.
    var blockingLimit: WeeklyMetric? {
        guard let binding = bindingLimit, binding.pct >= Theme.exhaustedPct else { return nil }
        return binding
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
    /// show. Renders as a "No data" card with the `.dead` mascot. Pass
    /// `needsSignIn` when the cause was the login itself, so the card can offer
    /// to run the CLI's sign-in.
    static func unavailable(
        _ config: ProviderConfig, note: String? = nil, needsSignIn: Bool = false
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            config: config, sessionPct: 0, sessionResetAt: nil,
            weekly: [], isActive: false, isEstimated: false,
            isUnavailable: true, needsSignIn: needsSignIn, note: note
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
    /// Set on a user-initiated refresh so readers bypass the post-429 cooldown
    /// and re-attempt the live fetch instead of silently returning cached numbers.
    var force: Bool = false
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

    /// Every coding CLI Merlyn can set up out of the box, paired with the on-disk
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
        return base.appendingPathComponent("Merlyn", isDirectory: true)
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
