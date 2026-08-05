// ProviderCardView.swift — one provider: mascot + identity + live reset
// countdown + mood tag + session ring, expanding to weekly bars and the
// source config folder.

import SwiftUI

struct ProviderCardView: View {
    let snapshot: ProviderSnapshot
    /// Edit mode swaps the session ring for a delete button + drag grip and
    /// pauses tap-to-expand so reordering drags don't toggle the detail.
    var editing: Bool = false
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}

    // --expand pre-opens every card (visual QA without scripted clicks)
    @State private var open = ProcessInfo.processInfo.arguments.contains("--expand")
    @State private var hovering = false
    @Environment(\.theme) private var theme

    private var accent: Color { snapshot.config.resolvedPalette.accent }

    /// Ring lanes, outermost first — the order comes from the snapshot (see
    /// `ringWindows`); the card only supplies the colours, since only it knows the
    /// provider's palette.
    private var ringLimits: [RingLimit] {
        let baseHue = Fate.hue(slot: snapshot.config.resolvedColorSlot,
                               shiny: snapshot.config.isShiny)
        return snapshot.ringWindows(maxLanes: RingView.maxLanes).enumerated().map { index, window in
            RingLimit(id: window.label, pct: window.pct,
                      color: laneColor(pct: window.pct, index: index, baseHue: baseHue))
        }
    }

    /// Lane hue identifies the *window*, stepped 55° off the provider's own hue so
    /// the lanes are tellable apart while the ring still reads as this provider's.
    ///
    /// Severity keeps exactly one override: a lane at or past the danger threshold
    /// goes red. Being about to get blocked is the one thing worth breaking the
    /// colour scheme for — the amber warn band stays on the bars, which have labels.
    private func laneColor(pct: Double, index: Int, baseHue: Double) -> Color {
        guard pct < Theme.dangerPct else { return Theme.danger }
        return MascotPalette.fromHue(baseHue + Double(index) * 55).accent
    }

    /// The colour a window's bar shares with its ring lane, matched on label. Ties
    /// the two views together: the arc and the bar are the same limit, so reading
    /// them as one object is the whole point of colouring lanes by category.
    private func laneColor(matching label: String) -> Color {
        ringLimits.first { $0.id == label }?.color
            ?? Theme.usageColor(pct: 0, accent: accent)
    }

    var body: some View {
        VStack(spacing: 0) {
            cardTop
            if open, !editing {
                detail
                    .transition(.opacity)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(hovering ? theme.cardBackgroundHover : theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .offset(y: hovering && !editing ? -1 : 0)
        .shadow(color: .black.opacity(hovering && !editing ? 0.10 : 0), radius: 9, y: 6)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onTapGesture {
            if editing {
                onEdit()
            } else {
                withAnimation(Theme.snappy(0.34)) { open.toggle() }
            }
        }
        .onHover { hovering = $0 }
        .help(snapshot.note ?? "")
    }

    private var cardTop: some View {
        HStack(spacing: 11) {
            if editing {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.text3)
                    .help("Drag to reorder")
            }
            VStack(spacing: 3) {
                ZStack {
                    MascotView(
                        style: snapshot.config.resolvedStyle,
                        palette: snapshot.config.resolvedPalette,
                        mood: snapshot.mood,
                        px: 48,
                        busy: snapshot.isActive,
                        spriteName: snapshot.resolvedSpriteForm
                    )
                }
                .frame(width: 48, height: 48)
                .overlay(alignment: .topLeading) {
                    if snapshot.config.isShiny {
                        ShinySparkle()
                            .help("Shiny! A rare mascot color.")
                    }
                }
                // Streak rides the top-right corner; the live-activity ping
                // moves to bottom-right so the two don't fight for one spot.
                .overlay(alignment: .topTrailing) {
                    if let game = snapshot.game, !snapshot.isUnavailable, game.streakDays >= 2 {
                        MascotStreakBadge(days: game.streakDays)
                            .offset(x: 7, y: -4)
                            .help("\(game.streakDays)-day streak — consecutive days used")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if snapshot.isActive {
                        ActivityDot()
                            .offset(x: 1, y: -1)
                    }
                }

                // Level + XP as a tiny progress bar beneath the sprite.
                if let game = snapshot.game, !snapshot.isUnavailable {
                    MascotLevelBar(level: game.level, xp: game.xpInLevel, accent: accent)
                }
            }

            // Nothing in here may be `fixedSize()`. Every card is as wide as the
            // widest one, so a single rigid row wider than the panel pushes the
            // whole list past the panel edge and swallows its side padding — a
            // visible shift the moment plan pills arrive from the API.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(snapshot.config.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(snapshot.config.account)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.2)
                        .foregroundStyle(theme.text2)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(theme.chip, in: RoundedRectangle(cornerRadius: 6))
                    Spacer(minLength: 0)
                }
                resetLine
                // The plan pill rides with the mood tag rather than the title: the
                // title row has the least slack (name + account chip already), and
                // this line is otherwise near-empty.
                HStack(spacing: 5) {
                    Text(snapshot.mood.tagWord)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(snapshot.mood.tagForeground)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(snapshot.mood.tagBackground, in: RoundedRectangle(cornerRadius: 6))
                    if let plan = snapshot.plan {
                        Text(plan)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.1)
                            .foregroundStyle(accent)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                            .help("Subscription plan")
                    }
                    if let credits = snapshot.resetCredits, credits.available > 0 {
                        ResetCreditTag(credits: credits, provider: snapshot.config.name)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if editing {
                    DeleteButton(action: onDelete)
                } else if snapshot.needsSignIn {
                    SignInBadge(config: snapshot.config)
                } else if let failure = snapshot.failure {
                    failureBadge(failure)
                } else {
                    RingView(estimated: snapshot.isEstimated, limits: ringLimits)
                }
            }
            // The ring is a circle, so its widest point lands exactly on the reset
            // line — the row's longest text. Without this they nearly touch.
            .padding(.leading, 6)
        }
    }

    /// The ring's slot when there's nothing to plot. Deliberately ring-shaped and
    /// deliberately loud: the failure *is* this card's reading, so it gets the
    /// gauge's weight rather than a muted dash that reads as a real 0%. Dashed,
    /// like the estimate lanes, because there is no measurement behind it.
    private func failureBadge(_ failure: ProviderFailure) -> some View {
        let tint = failure.isFault ? Theme.danger : Theme.warn
        return ZStack {
            Circle()
                .stroke(tint.opacity(0.28),
                        style: StrokeStyle(lineWidth: 4.5, dash: [3, 2.5]))
            Image(systemName: failure.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: 38, height: 38)
        .padding(6)
        .overlay(alignment: .bottom) {
            Text(failure.badgeWord)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .offset(y: 7)
        }
        .help(snapshot.note ?? failure.headline)
    }

    private var resetLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                Image(systemName: snapshot.failure?.symbol ?? "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(snapshot.failure?.isFault == true ? Theme.danger : theme.text3)
                if let failure = snapshot.failure {
                    Text(failure.headline)
                } else if let blocking = snapshot.blockingLimit {
                    Text(Self.blockingText(blocking, now: context.date))
                } else if let resetAt = snapshot.sessionResetAt {
                    Text("Resets in \(Self.duration(until: resetAt, now: context.date))")
                } else {
                    Text("No active session")
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            // Truncate rather than wrap: the longest of these ("Weekly resets in
            // 3d 19h") is a hair off the width, and wrapping would grow the card.
            .lineLimit(1)
            .foregroundStyle(snapshot.failure?.isFault == true ? Theme.danger : theme.text2)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 11) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
                .padding(.top, 11)

            if let failure = snapshot.failure {
                failureDetail(failure)
            } else {
                usageDetail
            }

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(snapshot.config.dir)
                    .font(.system(size: 11, design: .monospaced))
                Spacer(minLength: 6)
                if !snapshot.isUnavailable, let note = snapshot.note {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.text3)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(theme.text2)
        }
        .padding(.top, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Expanded body when there's no reading: no fabricated bars, just what went
    /// wrong and a one-line nudge on how to get data back.
    private func failureDetail(_ failure: ProviderFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(failure.headline)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(failure.isFault ? Theme.danger : theme.text)
            if let note = snapshot.note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.text2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var usageDetail: some View {
        // Current session (5h window) — the same figure as the ring, shown
        // as a labeled bar so it sits alongside the weekly limits.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // Named from the span the provider reports. Codex's primary window is
            // 7 days, so "Current session · 5h limit" was wrong there on both counts.
            UsageBar(
                label: snapshot.hasSessionWindow ? "Current session" : "\(snapshot.primaryWindowName) usage",
                pct: snapshot.sessionPct,
                caption: snapshot.sessionResetAt.map {
                    "\(snapshot.primaryWindowName) limit · resets in \(Self.duration(until: $0, now: context.date))"
                } ?? "\(snapshot.primaryWindowName) limit · no active session",
                color: laneColor(matching: snapshot.primaryWindowName)
            )
        }

        if !snapshot.weekly.isEmpty {
            // "Weekly limits" under a bar that *is* the weekly limit reads as a
            // contradiction — when the primary window is the standing budget
            // (Codex), what follows are the extra caps nested inside it.
            Text(snapshot.hasSessionWindow ? "Weekly limits" : "Other limits")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(theme.text3)
                .padding(.top, 1)
        }
        ForEach(snapshot.weekly) { metric in
            UsageBar(
                label: metric.label, pct: metric.pct, caption: metric.resetText,
                color: laneColor(matching: metric.label)
            )
        }
    }

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

/// A capsule filled to `fraction` of the space it's given.
///
/// The fraction is the shape's only animatable data, so a bar grows when its
/// number changes and re-lays-out instantly when the layout changes. Driving the
/// fill with `frame(width: geo.size.width * pct)` instead puts a pixel width
/// inside the same transaction, so a card resizing while `pct` animates made the
/// fill slide sideways from its old geometry — bars smearing across the panel as
/// usage landed.
struct BarFill: Shape, Animatable {
    var fraction: Double
    /// Keeps a stub visible at zero. The level bar wants one; usage bars don't.
    var minWidth: CGFloat = 0

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = max(minWidth, rect.width * min(max(fraction, 0), 1))
        guard width > 0 else { return Path() }
        return Capsule().path(in: CGRect(x: rect.minX, y: rect.minY,
                                        width: width, height: rect.height))
    }
}

/// A labeled usage bar: title + "N% used", progress fill, and a reset caption.
/// Used for both the current-session (5h) and weekly windows.
struct UsageBar: View {
    let label: String
    let pct: Double
    let caption: String
    /// Supplied by the card, matched to this window's ring lane. The escalation to
    /// red lives there too, so the bar and the arc can't disagree — and an
    /// estimated provider stays on its own hue rather than escalating off a "vs
    /// your busiest week" ratio that hits 100% by construction.
    let color: Color

    @Environment(\.theme) private var theme

    var body: some View {
        let fill = color
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.text)
                Spacer()
                Text("\(Int(pct.rounded()))% used")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(theme.text2)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                BarFill(fraction: pct / 100)
                    .fill(fill)
                    .animation(Theme.snappy(0.5), value: pct)
            }
            .frame(height: 6)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(theme.text2)
                .padding(.top, -1)
        }
    }
}

/// Spare window resets the account is holding — a glyph and a count, sized to sit
/// third on a row that already carries the mood tag and the plan pill.
///
/// Lit only when the provider says a credit is spendable on the window you're
/// actually blocked on: holding one that today's limit can't use is worth knowing
/// about but isn't an escape hatch, and a bright green "1" would read as one.
struct ResetCreditTag: View {
    let credits: ResetCredits
    let provider: String

    @Environment(\.theme) private var theme

    private var tint: Color { credits.isUsableNow ? Color(hex: 0x34C759) : theme.text2 }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 8.5, weight: .bold))
            Text("\(credits.available)")
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(tint.opacity(credits.isUsableNow ? 0.16 : 0.10),
                    in: RoundedRectangle(cornerRadius: 6))
        .help(helpText)
    }

    private var helpText: String {
        let noun = credits.available == 1 ? "reset" : "resets"
        return credits.isUsableNow
            ? "\(credits.available) limit \(noun) available — \(credits.applicable) can clear the window blocking you now"
            : "\(credits.available) limit \(noun) available, but none applies to \(provider)'s current window"
    }
}

/// Sprite-aligned streak marker. The flame is a generated pixel asset rather
/// than the platform emoji so it stays on-theme with the mascots.
struct MascotStreakBadge: View {
    let days: Int

    @Environment(\.theme) private var theme

    /// Loaded from the `Resources` subdirectory — `.copy("Resources")` preserves
    /// the folder in the bundle, so `Image(_:bundle:)` (which only searches the
    /// bundle root / asset catalog) can't find it. Same path the sprites use.
    private static let flame: NSImage? = {
        guard let url = Bundle.module.url(forResource: "streak-fire",
                                          withExtension: "png",
                                          subdirectory: "Resources"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        return image
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            if let flame = Self.flame {
                Image(nsImage: flame)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 11.5, height: 11.5)
                    .accessibilityHidden(true)
            }
            Text("\(days)")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(theme.text)
                .monospacedDigit()
        }
        .fixedSize()
    }
}

/// Subtle level tell beneath the sprite: a tiny "Lv N" + XP progress bar.
/// Deliberately small — leveling is a background flourish, not the headline.
struct MascotLevelBar: View {
    let level: Int
    let xp: Double          // 0...1 toward next level
    let accent: Color

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3.5) {
            Text("Lv\(level)")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(theme.text2)
                .fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                BarFill(fraction: xp, minWidth: 2)
                    .fill(accent)
                    .animation(Theme.snappy(0.5), value: xp)
            }
            .frame(height: 3)
        }
        .frame(width: 52)
        .help("Level \(level) · \(Int((xp * 100).rounded()))% to the next level")
    }
}

/// Sign-in affordance in the card's trailing slot, standing in for the session
/// ring when a login has lapsed. Deliberately the same 50pt footprint as
/// `noDataBadge`, so a card that gains it can't widen the list.
struct SignInBadge: View {
    let config: ProviderConfig

    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button { LoginLauncher.openLogin(for: config) } label: {
            ZStack {
                Circle()
                    .fill(hovering ? Color(hex: 0x4C8DFF) : theme.chip)
                Circle()
                    .stroke(hovering ? .clear : theme.track, lineWidth: 1)
                Image(systemName: "person.badge.key")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(hovering ? .white : theme.text2)
            }
            .frame(width: 38, height: 38)
            .padding(6)
            .overlay(alignment: .bottom) {
                Text("sign in")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(hovering ? theme.text : theme.text2)
                    .offset(y: 7)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Sign in to \(config.name) — runs `\(config.loginShellCommand)` in a terminal")
    }
}

/// Round trash button shown on each card in edit mode. Reddens on hover.
struct DeleteButton: View {
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? .white : Color(hex: 0xD9544E))
                .frame(width: 34, height: 34)
                .background(
                    Circle().fill(hovering ? Color(hex: 0xD9544E) : theme.chip)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Remove this provider")
    }
}

/// Tiny twinkling star pinned to a caught-shiny mascot — the at-a-glance tell
/// that its color is the rare variant, not just a chosen palette.
struct ShinySparkle: View {
    @State private var twinkle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color(hex: 0xFFD23D))
            .shadow(color: Color(hex: 0xFFB800, alpha: 0.8), radius: 2)
            .scaleEffect(twinkle ? 1.0 : 0.82)
            .opacity(twinkle ? 1.0 : 0.7)
            .offset(x: -3, y: -3)
            .onAppear { if !reduceMotion { twinkle = true } }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: twinkle
            )
    }
}

struct ActivityDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color(hex: 0x34C759))
            .frame(width: 8, height: 8)
            .background(
                Circle()
                    .stroke(Color(hex: 0x34C759, alpha: 0.5), lineWidth: 3)
                    .scaleEffect(pulse ? 2.2 : 1)
                    .opacity(pulse ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
            )
            .onAppear { pulse = true }
    }
}
