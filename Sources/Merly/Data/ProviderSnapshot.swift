// ProviderSnapshot.swift — the usage-reading domain model: limit windows,
// failure states, per-provider snapshots, and the cached "last good" reading.

import Foundation

/// Usage thresholds shared by the data layer and every gauge surface. They live
/// here (not in `Theme`) because snapshot logic like `blockingLimit` and the
/// mascot mood needs them, and the data layer must not depend on SwiftUI.
enum UsageThresholds {
    /// Where a limit turns red — the one severity escalation any gauge applies
    /// (`Theme.limitColor`). There is no amber band: see `limitColor` for why.
    static let dangerPct: Double = 88

    /// Where a limit stops being "nearly out" and starts actually blocking work.
    /// Deliberately not `dangerPct`: a red 94% weekly is still usable, and saying
    /// "maxed" there is wrong. 99.5 rather than 100 so it agrees with the rounded
    /// "100% used" the bars print — the API reports fractions like 99.6.
    static let exhaustedPct: Double = 99.5
}

/// Naming and classifying a limit window by the span the provider reports.
///
/// Nothing may hardcode "5h" or "weekly" from a field's name: Codex moved its
/// primary window from 5h to 7 days with no rename, so every label built on that
/// assumption ("5h limit · resets in 3d 18h") started lying.
enum LimitWindow {
    /// A window at or past this span is *named* "Weekly". Higher than
    /// `standingBudgetSeconds` on purpose: a 3-day window behaves like a standing
    /// budget (lane order, blocking copy) but calling it "Weekly" would lie, so
    /// it's named "3d" while still classified weekly by `isWeekly`.
    static let weeklyNameSeconds: Double = 144 * 3600

    /// A window at or past this span is a standing budget rather than a rolling
    /// session. Drives the ring's lane order and the card's "what's blocking
    /// you" wording (see `isWeekly`).
    static let standingBudgetSeconds: Double = 48 * 3600

    /// "5h", "24h", "3d", "Weekly" — what to call a window of this length.
    /// Defaults to "5h" when a provider reports no span, which is what every
    /// primary window was before Codex changed.
    static func name(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "5h" }
        if seconds >= weeklyNameSeconds { return "Weekly" }
        let hours = seconds / 3600
        if seconds >= standingBudgetSeconds { return "\(Int((hours / 24).rounded()))d" }
        if hours >= 1 { return "\(Int(hours.rounded()))h" }
        return "\(Int((seconds / 60).rounded()))m"
    }

    /// Long enough to be a standing budget rather than a rolling session.
    static func isWeekly(seconds: Double?) -> Bool { (seconds ?? 0) >= standingBudgetSeconds }
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

    /// The label doubles as SwiftUI identity (`id`) and the lane-colour key
    /// (`laneRank`), so it must be unique within one snapshot — but a provider
    /// can report two windows that generate the same label (Kimi lists several
    /// unlabeled "Rate limit" windows). Suffix duplicates "#2", "#3", … at
    /// assembly time so identity never collides.
    static func dedupingLabels(_ metrics: [WeeklyMetric]) -> [WeeklyMetric] {
        var counts: [String: Int] = [:]
        return metrics.map { metric in
            let n = (counts[metric.label] ?? 0) + 1
            counts[metric.label] = n
            guard n > 1 else { return metric }
            var copy = metric
            copy.label = "\(metric.label) #\(n)"
            return copy
        }
    }
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
        guard let binding = bindingLimit, binding.pct >= UsageThresholds.exhaustedPct else { return nil }
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
    /// `ProviderKind.limitColorHex`). The primary window always takes step 0; the
    /// nested windows follow in *alphabetical* order of label.
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

/// Countdown and blocking-limit copy shared by the card's clock line and the
/// headless `--print` snapshot — formatting a *reading*, not a layout choice,
/// so it lives with the data rather than on a view.
enum UsageFormatting {
    /// What's standing between you and the next request, for the clock line. Kept
    /// short enough to sit on one line beside the mascot and the ring.
    static func blockingText(_ blocking: WeeklyMetric, now: Date) -> String {
        let word = blocking.isWeekly ? "Weekly" : "5h cap"
        // Terse because the wider nested ring leaves this line ~136pt; the clock
        // glyph beside it already supplies "resets".
        guard let resetAt = blocking.resetAt else { return "\(word) maxed" }
        return "\(word) in \(duration(until: resetAt, now: now))"
    }

    static func duration(until end: Date, now: Date) -> String {
        let remaining = end.timeIntervalSince(now)
        if remaining <= 0 { return "now" }
        let minutes = Int(remaining / 60)
        let hours = minutes / 60
        // Weekly windows are days out; "91h 55m" is unreadable as a countdown.
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        let seconds = Int(remaining) % 60
        return "\(minutes)m \(seconds)s"
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
