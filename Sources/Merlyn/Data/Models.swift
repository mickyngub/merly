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

    /// Where this kind's limit colours start on the wheel — see `limitColorHex`. The
    /// kinds sit ~100° apart, wide enough that no Claude lane can be mistaken for a
    /// Codex one, and the run avoids the two hues severity owns: `Theme.danger`
    /// (~358°) and `Theme.warn` (~40°) must never be something a healthy limit wears.
    var limitBaseHue: Double {
        switch self {
        case .claude: 60    // yellow → lime → green
        case .codex: 190    // cyan → blue → indigo
        case .kimi: 290     // violet → magenta → pink
        }
    }

    /// The colour a limit lane wears, packed 0xRRGGBB: this kind's band, stepped by
    /// the limit's category rank (see `ProviderSnapshot.laneRank`). Hex rather than
    /// `Color` because the menu bar gauge draws in AppKit.
    ///
    /// Keyed on the *kind*, never on the account's mascot palette: two Claude cards
    /// stack in one panel, and a colour that meant "5h" on one and "weekly" on the
    /// next made the panel unreadable. Account identity stays with the mascot.
    ///
    /// Each step moves hue *and* lightness. Hue alone doesn't separate lanes — 25°
    /// apart in the greens gave "All models" and "Fable only" two near-identical
    /// bars — and hue steps wide enough to fix that would walk out of the kind's
    /// band. Alternating light/dark makes neighbouring lanes differ in value, which
    /// survives a 6pt bar and a 3pt menu bar gauge.
    func limitColorHex(rank: Int) -> UInt32 {
        let hue = limitBaseHue + Double(rank) * 25
        let light = rank == 0 ? 0 : (rank.isMultiple(of: 2) ? -0.15 : 0.14)
        return MascotPalette.fromHue(hue, lightBoost: light).B
    }
}

/// The app's own mascot, shown beside the panel's "Merlyn" title. Independent of
/// any provider; its look is user-editable while its mood tracks the busiest
/// provider's pressure. (The menu bar always wears the *reported provider's*
/// critter instead — see `docs/decisions/menu-bar`.)
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

/// Why a provider has no usable numbers.
///
/// One flag ("unavailable") blurred four different problems into one grey dash,
/// and only one of them is fixable by signing in. Worse, an unclassified failure
/// used to fall through to the local estimate, so an account the server had
/// *refused* rendered as a confident "100% used · vs your busiest week" — a
/// fabricated number wearing a real limit's clothes. A refusal is a reading in
/// its own right, so it gets the gauge's slot and says what it is.
enum ProviderFailure: String, Equatable {
    /// No credentials, or the server rejected the token. The only state where
    /// signing in again is the fix — so the only one that offers the button.
    case signedOut
    /// The server answered and said no (403 lapsed/org-disabled subscription, 402
    /// unpaid, 404 no such resource). There is no quota to read on this account.
    case refused
    /// A standing 429: the endpoint won't report quota right now.
    case rateLimited
    /// Unreachable, timed out, or 5xx.
    case offline

    /// Word under the badge. 9.5pt inside a 50pt slot — keep it to one short word.
    var badgeWord: String {
        switch self {
        case .signedOut: "sign in"
        case .refused: "error"
        case .rateLimited: "limited"
        case .offline: "offline"
        }
    }

    /// Headline for the card's clock line, which has room for two or three words.
    var headline: String {
        switch self {
        case .signedOut: "Signed out"
        case .refused: "No usage access"
        case .rateLimited: "Rate-limited"
        case .offline: "Offline"
        }
    }

    var symbol: String {
        switch self {
        case .signedOut: "person.badge.key"
        case .refused: "exclamationmark.triangle.fill"
        case .rateLimited: "hourglass"
        case .offline: "bolt.slash.fill"
        }
    }

    /// Something is wrong with the account, not merely with this minute's fetch —
    /// the one distinction worth spending red on.
    var isFault: Bool { self == .refused }
}

/// One-shot grants that clear a rate-limit window early (Codex's
/// `rate_limit_reset_credits`). `applicable` is the subset the provider says can
/// be spent on the window you're actually blocked on right now — you can hold a
/// credit that today's limit has no use for, so the two counts differ and the tag
/// must not promise the bigger one is usable.
struct ResetCredits: Equatable, Codable {
    var available: Int
    var applicable: Int

    var isUsableNow: Bool { applicable > 0 }
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

/// One bar in an icon-sized gauge — the menu bar item and the collapsed rail. Not
/// a `WeeklyMetric`: those are the provider's reported rows, this is a reading
/// already resolved down to what a 2–3pt bar can carry (which window, how full,
/// whether it's a guess, what colour the card gives it).
struct IconGauge: Equatable {
    /// "5h" / "24h" / "wk" — the window this bar measures.
    var window: String
    var pct: Double
    /// A local-token estimate rather than a reported limit. The bar can't say so at
    /// this size, so the tooltip does — see `gaugeTooltip`.
    var estimated: Bool
    /// The colour the card gives this same limit (`ProviderKind.limitColorHex`), so
    /// the same window is the same hue in the ring, the rail, and the menu bar.
    var colorHex: UInt32

    /// The chip text drawn beside the bar: "5h", "24h", "w". Colour alone couldn't
    /// say which bar was which — two lanes of the same provider's band are a hue
    /// apart, which distinguishes them from each other but doesn't *name* either.
    /// Single-letter for weekly because the chip has ~11pt to work in and "wk"
    /// costs a third of it for no gain in clarity.
    var label: String { window == "wk" ? "w" : window }
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
    /// Set when there is genuinely no reading to show — the login lapsed, the
    /// server refused us, or it can't be reached — and no fresh real numbers to
    /// fall back on. The card renders the failure in the gauge's slot and the
    /// mascot goes `.dead`, instead of inventing a "vs your busiest week"
    /// estimate that reads as a real limit.
    var failure: ProviderFailure? = nil
    /// Optional note (e.g. why data is missing, or how fresh a cached reading is).
    var note: String?
    /// The provider's subscription tier (e.g. "Max (20x)", "Pro", "Team (5x)"),
    /// shown as a pill beside the provider name. Nil when the provider exposes no
    /// plan info (token-estimated providers) or its login has lapsed.
    var plan: String? = nil
    /// Spare window resets this account holds, when the provider grants them.
    var resetCredits: ResetCredits? = nil
    /// Derived idle-game stats (level, XP, streak, evolution form) computed from
    /// the provider's lifetime log metadata. Stored, not computed: it needs file
    /// I/O, so the reader fills it on the work queue (never lazily on the main
    /// thread). Nil until computed / when the log tree is empty.
    var game: GameStats? = nil

    var id: String { config.id }

    /// No usable reading, whatever the cause.
    var isUnavailable: Bool { failure != nil }
    /// Signing in again is the fix — as opposed to an unreachable or refusing
    /// server, where it would change nothing. Only this state offers the button.
    var needsSignIn: Bool { failure == .signedOut }

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

    /// Every window worth plotting, outermost ring lane first: the longest out on
    /// the rim, the shortest innermost. Estimated providers contribute only their
    /// primary window — their weekly figures are "vs your busiest week" ratios that
    /// trend to 100% by construction.
    ///
    /// Which lane the primary window takes follows its *span*, not its being
    /// primary. Codex's primary limit is a 7-day budget, so pinning it inside put
    /// the cap that gates every request on the innermost lane while a 0% per-model
    /// weekly owned the rim. A genuine rolling session still keeps the innermost
    /// lane unconditionally, so "right now" is always in the same place and can
    /// never be the lane truncation drops.
    ///
    /// Lives here rather than in the card because it's a reading of the provider,
    /// not a layout choice — and `--print` verifies the order without a screenshot.
    func ringWindows(maxLanes: Int) -> [(label: String, pct: Double)] {
        // A failure has no quantity behind it: the card swaps the whole ring for the
        // error badge, and a 0% lane would read as "nothing used yet".
        guard failure == nil else { return [] }
        let primary = (label: primaryWindowName, pct: sessionPct)
        // Partitioned rather than sorted: Swift's sort isn't stable, and two weekly
        // caps tie, so sorting could swap lanes between renders.
        let reported = isEstimated ? [] : weekly
        let nested = (reported.filter(\.isWeekly) + reported.filter { !$0.isWeekly })
            .map { (label: $0.label, pct: $0.pct) }
            // A nested window can carry the primary's name (Codex reports a 7-day
            // primary *and* a 7-day secondary, both "Weekly"). Lane ids must stay
            // unique, and the primary is the one that owns the name.
            .filter { $0.label != primary.label }

        guard hasSessionWindow else { return [primary] + nested.prefix(maxLanes - 1) }
        return Array(nested.prefix(maxLanes - 1)) + [primary]
    }

    /// Which colour step a limit takes inside its provider's band (see
    /// `ProviderKind.limitHue`). The primary window always takes step 0; the nested
    /// windows follow in *alphabetical* order of label.
    ///
    /// Ranked by label rather than by lane position because lane position is a
    /// reading of one account's reported list: a provider that reports an extra
    /// per-model cap would shift every lane after it, so the same weekly limit would
    /// wear a different colour on two accounts of the same provider. Alphabetical is
    /// also immune to the API listing the same windows in a different order.
    ///
    /// Unknown labels fall to step 0 — a bar for a window the snapshot doesn't list
    /// can only be the primary one.
    func laneRank(of label: String) -> Int {
        guard label != primaryWindowName else { return 0 }
        let nested = weekly.map(\.label).filter { $0 != primaryWindowName }.sorted()
        guard let index = nested.firstIndex(of: label) else { return 0 }
        return index + 1
    }

    /// Reported nested windows, or nothing for an estimate — whose weekly figures
    /// are ratios against the user's busiest week rather than a real cap, and so
    /// can't headline anything outside the card.
    private var reportedWeekly: [WeeklyMetric] { isEstimated ? [] : weekly }

    /// The limits worth reporting outside the panel, one bar each: the rolling
    /// session window first, then the weekly cap. **Two readings, not one worst-of.**
    ///
    /// A single binding bar conflated the two questions the menu bar exists to
    /// answer. "Can I work right now" and "will I last the week" have opposite
    /// answers in the two states that matter most — a fresh 5h window under a spent
    /// week, and a spent 5h window under a fresh week — and both drew the same
    /// hundred-percent bar. Which one you were looking at was only in the tooltip.
    ///
    /// One bar when the provider genuinely has one limit, never a padded pair: Codex's
    /// primary limit *is* a 7-day budget, so it takes the weekly bar and there is no
    /// session lane to draw. An estimated provider likewise reports only its session.
    ///
    /// Nested *short* windows stay out. They belong to the card's ring; here they'd
    /// make the item's height a function of which provider is pinned.
    var iconGauges: [IconGauge] {
        // A failure has no quantity behind it — both drawers swap the bars for a
        // badge rather than show a measurement of nothing.
        guard failure == nil else { return [] }

        func lane(_ window: String, _ pct: Double, _ estimated: Bool, label: String) -> IconGauge {
            IconGauge(window: window, pct: pct, estimated: estimated,
                      colorHex: config.kind.limitColorHex(rank: laneRank(of: label)))
        }
        // Worst of the reported weekly caps: an account with a per-model cap has
        // several, and the tightest is the one that blocks first. "wk" rather than
        // "7d" because a weekly window's exact length isn't always reported (Kimi
        // states none for its rolling budget).
        let weekliest = reportedWeekly.filter(\.isWeekly).max(by: { $0.pct < $1.pct })

        // The primary window is the session lane only when it's short enough to be
        // one. Codex's spans 7 days, so there the primary *is* the weekly lane.
        guard hasSessionWindow else {
            if let weekliest, weekliest.pct > sessionPct {
                return [lane("wk", weekliest.pct, false, label: weekliest.label)]
            }
            return [lane("wk", sessionPct, isEstimated, label: primaryWindowName)]
        }

        var lanes = [lane(primaryWindowName, sessionPct, isEstimated, label: primaryWindowName)]
        if let weekliest {
            lanes.append(lane("wk", weekliest.pct, false, label: weekliest.label))
        }
        return lanes
    }

    /// The figures an icon-sized gauge can't spell out: who they belong to, which
    /// window each bar measures, and whether it's an estimate. Shared by both places
    /// that draw `iconGauges` as bare bars — the menu bar item and the collapsed rail
    /// — so the two can't drift into describing the same reading differently. It's
    /// also the only place an estimate is marked at that size: a 2–3pt dashed bar is
    /// mush, so the word does the work the dash does on the card.
    ///
    /// `qualifier` rides with the name for callers that must say *which* provider
    /// this is (the menu bar's "(busiest provider)").
    func gaugeTooltip(qualifier: String = "") -> String {
        let who = "\(config.name) · \(config.account)\(qualifier)"
        if let failure { return "\(who) — \(failure.headline.lowercased())" }
        let lanes = iconGauges
        guard !lanes.isEmpty else { return who }
        // Top bar first, matching the draw order, so the list can be read off the
        // icon rather than matched against it.
        let readings = lanes.map { lane in
            let window = lane.window == "wk" ? "weekly limit" : "\(lane.window) window"
            return "\(window) \(lane.estimated ? "≈" : "")\(Int(lane.pct.rounded()))% used"
        }
        return "\(who) — \(readings.joined(separator: " · "))"
            + (lanes.contains(where: \.estimated) ? ", estimated" : "")
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

    /// No usable reading, and `failure` says why. Renders as an error card with
    /// the `.dead` mascot — the sign-in button only for `.signedOut`, where it's
    /// actually the fix.
    static func failed(
        _ config: ProviderConfig, _ failure: ProviderFailure, note: String? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            config: config, sessionPct: 0, sessionResetAt: nil,
            weekly: [], isActive: false, isEstimated: false,
            failure: failure, note: note
        )
    }

    /// The real numbers worth caching to ride out a transient API failure.
    func realReading(at now: Date) -> RealReading? {
        guard !isEstimated, !isStale, !isUnavailable else { return nil }
        return RealReading(
            sessionPct: sessionPct, sessionResetAt: sessionResetAt,
            weekly: weekly, planNote: plan, capturedAt: now,
            resetCredits: resetCredits
        )
    }

    /// Rebuild a snapshot from a cached real reading, flagged stale with an age.
    static func fromCache(_ reading: RealReading, config: ProviderConfig, now: Date) -> ProviderSnapshot {
        let age = Int(now.timeIntervalSince(reading.capturedAt) / 60)
        let ageText = age < 1 ? "moments ago" : age < 60 ? "\(age)m ago" : "\(age / 60)h ago"
        return ProviderSnapshot(
            config: config, sessionPct: reading.sessionPct, sessionResetAt: reading.sessionResetAt,
            weekly: reading.weekly, isActive: false, isEstimated: false, isStale: true,
            note: "as of \(ageText)", plan: reading.planNote,
            resetCredits: reading.resetCredits
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
    /// Optional so readings cached before reset credits existed still decode.
    var resetCredits: ResetCredits? = nil
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
    /// Which provider the menu bar gauge reports on. nil (and an id that no longer
    /// matches a provider) means whichever is closest to a limit — the app's
    /// original always-busiest behaviour, kept as the default because it's the one
    /// pick that can't go stale.
    var menuBarProviderId: String? = nil

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
