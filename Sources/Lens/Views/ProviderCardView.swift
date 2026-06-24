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

    var body: some View {
        VStack(spacing: 0) {
            cardTop
            if open, !editing {
                detail
                    .transition(.opacity)
            }
        }
        .padding(12)
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

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(snapshot.config.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(theme.text)
                        .fixedSize()
                    Text(snapshot.config.account)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.2)
                        .foregroundStyle(theme.text2)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(theme.chip, in: RoundedRectangle(cornerRadius: 6))
                        .fixedSize()
                    if let plan = snapshot.plan {
                        Text(plan)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.1)
                            .foregroundStyle(accent)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                            .fixedSize()
                            .help("Subscription plan")
                    }
                    Spacer(minLength: 0)
                }
                resetLine
                Text(snapshot.mood.tagWord)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(snapshot.mood.tagForeground)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(snapshot.mood.tagBackground, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if editing {
                DeleteButton(action: onDelete)
            } else if snapshot.isUnavailable {
                noDataBadge
            } else {
                RingView(pct: snapshot.sessionPct, accent: accent, estimated: snapshot.isEstimated)
            }
        }
    }

    /// Stand-in for the ring when there's no data to plot — a muted dash so the
    /// card doesn't imply a real 0%.
    private var noDataBadge: some View {
        ZStack {
            Circle().stroke(theme.track, lineWidth: 4.5)
            Text("—")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.text3)
        }
        .frame(width: 38, height: 38)
        .padding(6)
        .overlay(alignment: .bottom) {
            Text("no data")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.text2)
                .offset(y: 7)
        }
    }

    private var resetLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                Image(systemName: snapshot.isUnavailable ? "bolt.slash" : "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.text3)
                if snapshot.isUnavailable {
                    Text("No data")
                } else if let resetAt = snapshot.sessionResetAt {
                    Text("Resets in \(Self.duration(until: resetAt, now: context.date))")
                } else {
                    Text("No active session")
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(theme.text2)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 11) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
                .padding(.top, 11)

            if snapshot.isUnavailable {
                noDataDetail
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

    /// Expanded body when the login lapsed: no fabricated bars, just the state
    /// and a one-line nudge on how to get data back.
    private var noDataDetail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No usage data")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.text)
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
            UsageBar(
                label: "Current session",
                pct: snapshot.sessionPct,
                caption: snapshot.sessionResetAt.map {
                    "5h limit · resets in \(Self.duration(until: $0, now: context.date))"
                } ?? "5h limit · no active session",
                accent: accent,
                estimated: snapshot.isEstimated
            )
        }

        if !snapshot.weekly.isEmpty {
            Text("Weekly limits")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(theme.text3)
                .padding(.top, 1)
        }
        ForEach(snapshot.weekly) { metric in
            UsageBar(
                label: metric.label, pct: metric.pct, caption: metric.resetText,
                accent: accent, estimated: snapshot.isEstimated
            )
        }
    }

    static func duration(until end: Date, now: Date) -> String {
        let remaining = end.timeIntervalSince(now)
        if remaining <= 0 { return "now" }
        let minutes = Int(remaining / 60)
        let hours = minutes / 60
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        let seconds = Int(remaining) % 60
        return "\(minutes)m \(seconds)s"
    }
}

/// A labeled usage bar: title + "N% used", progress fill, and a reset caption.
/// Used for both the current-session (5h) and weekly windows.
struct UsageBar: View {
    let label: String
    let pct: Double
    let caption: String
    let accent: Color
    /// Estimated bars use the provider accent and never escalate to amber/red —
    /// a "vs your busiest week" ratio hitting 100% is not a real warning.
    var estimated: Bool = false

    @Environment(\.theme) private var theme

    var body: some View {
        let fill = estimated ? accent : Theme.usageColor(pct: pct, accent: accent)
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
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track)
                    Capsule()
                        .fill(fill)
                        .frame(width: max(0, geo.size.width * pct / 100))
                        .animation(Theme.snappy(0.5), value: pct)
                }
            }
            .frame(height: 6)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(theme.text2)
                .padding(.top, -1)
        }
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
                GeometryReader { geo in
                    Capsule()
                        .fill(accent)
                        .frame(width: max(2, geo.size.width * xp))
                        .animation(Theme.snappy(0.5), value: xp)
                }
            }
            .frame(height: 3)
        }
        .frame(width: 52)
        .help("Level \(level) · \(Int((xp * 100).rounded()))% to the next level")
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
