// ProviderCardView.swift — one provider: mascot + identity + live reset
// countdown + mood tag + session ring, expanding to weekly bars and the
// source config folder.

import SwiftUI

struct ProviderCardView: View {
    let snapshot: ProviderSnapshot

    // --expand pre-opens every card (visual QA without scripted clicks)
    @State private var open = ProcessInfo.processInfo.arguments.contains("--expand")
    @State private var hovering = false
    @Environment(\.theme) private var theme

    private var accent: Color { snapshot.config.resolvedPalette.accent }

    var body: some View {
        VStack(spacing: 0) {
            cardTop
            if open {
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
        .offset(y: hovering ? -1 : 0)
        .shadow(color: .black.opacity(hovering ? 0.10 : 0), radius: 9, y: 6)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onTapGesture {
            withAnimation(Theme.snappy(0.34)) { open.toggle() }
        }
        .onHover { hovering = $0 }
        .help(snapshot.note ?? "")
    }

    private var cardTop: some View {
        HStack(spacing: 11) {
            ZStack(alignment: .topTrailing) {
                MascotView(
                    style: snapshot.config.resolvedStyle,
                    palette: snapshot.config.resolvedPalette,
                    mood: snapshot.mood,
                    px: 48,
                    busy: snapshot.isActive,
                    spriteName: snapshot.config.resolvedSprite
                )
                if snapshot.isActive {
                    ActivityDot()
                        .offset(x: 2, y: 1)
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snapshot.config.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(theme.text)
                    Text(snapshot.config.account)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.2)
                        .foregroundStyle(theme.text2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(theme.chip, in: RoundedRectangle(cornerRadius: 6))
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

            RingView(pct: snapshot.sessionPct, accent: accent, estimated: snapshot.isEstimated)
        }
    }

    private var resetLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.text3)
                if let resetAt = snapshot.sessionResetAt {
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

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(snapshot.config.dir)
                    .font(.system(size: 11, design: .monospaced))
                Spacer(minLength: 6)
                if let note = snapshot.note {
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
