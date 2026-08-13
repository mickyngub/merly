// RingView.swift — the card's usage gauge: one nested arc per limit the provider
// reports. No numbers at rest; hovering a lane names it and shows its figure.

import SwiftUI

/// One lane of the nested ring: a window's label (also its identity), how full it
/// is, and the hue that identifies it. The caller owns the colour so the lane
/// scheme stays with the card that knows the provider's palette.
struct RingLimit: Identifiable, Equatable {
    let id: String
    let pct: Double
    let color: Color
}

struct RingView: View {
    /// Locally-estimated figures dash their lanes, so an estimate can't be mistaken
    /// for a provider-reported limit now that the "≈" caption is gone.
    var estimated: Bool = false
    /// Every limit this provider reports, outermost lane first: the longest window
    /// on the rim, down to the 5h session in the middle.
    let limits: [RingLimit]

    @State private var hovered: RingLimit?
    @Environment(\.theme) private var theme

    // Activity-ring proportions: bands thick relative to their radii, separated by
    // a ~1pt gap, leaving a small hole rather than a large empty middle.
    private static let size: CGFloat = 52
    private static let pad: CGFloat = 3
    private static let step: CGFloat = 6.5
    private static let stroke: CGFloat = 5.5
    /// Beyond three the strokes thin out past legibility; the expanded card lists
    /// every window anyway. Not private: the card reserves the innermost lane for
    /// the session, so it needs to know the budget.
    static let maxLanes = 3

    private var lanes: [RingLimit] { Array(limits.prefix(Self.maxLanes)) }

    /// Radius of the outermost lane's stroke centre, in the padded frame.
    private static var outerRadius: CGFloat { size / 2 - stroke / 2 }

    var body: some View {
        ZStack {
            ForEach(Array(lanes.enumerated()), id: \.element.id) { index, limit in
                lane(limit, index: index)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .padding(Self.pad)
        // Hit-tested by radius rather than per-arc `contentShape`: a stroked circle
        // still reports its whole square for hover, so the outermost lane would
        // answer for every one of them.
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hovered = lane(at: point)
            case .ended: hovered = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        // Anchored trailing so a long label ("GPT-5.3-Codex-Spark · 5h") grows left
        // across the card instead of off its right edge.
        .overlay(alignment: .bottomTrailing) { tooltip }
        // The figures are otherwise hover-only; narrate every lane for VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// "Weekly 62%, 5h 31%" — the hover tooltips, rolled into one sentence.
    private var accessibilitySummary: String {
        guard !lanes.isEmpty else { return "No usage data" }
        let readings = lanes
            .map { "\($0.id) \(Int($0.pct.rounded()))%\(estimated ? " estimated" : "")" }
            .joined(separator: ", ")
        return "Usage: \(readings)"
    }

    private func lane(_ limit: RingLimit, index: Int) -> some View {
        let fraction = min(max(limit.pct / 100, 0), 1)
        let colour = limit.color
        let isHovered = hovered == limit
        let width = Self.stroke + (isHovered ? 1.5 : 0)
        return ZStack {
            // The track is a dark tint of the lane's *own* colour, not a neutral
            // grey. That's what makes each lane read as one object rather than a
            // coloured arc floating on shared scaffolding.
            Circle()
                .stroke(colour.opacity(0.22), lineWidth: width)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    // Brightens toward the head, so the arc has a direction and the
                    // leading cap is the part your eye lands on.
                    AngularGradient(
                        colors: [colour.opacity(0.55), colour],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * max(fraction, 0.001))
                    ),
                    style: StrokeStyle(
                        lineWidth: width,
                        lineCap: .round,
                        dash: estimated ? [3, 2.5] : []
                    )
                )
                .rotationEffect(.degrees(-90))
                // Lifts the band off its track, and off the lane beneath it.
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                .animation(Theme.snappy(0.55), value: fraction)
                .opacity(fraction > 0 ? 1 : 0)
        }
        // Dims the lanes you aren't pointing at, so the tooltip's label is
        // unambiguous — naming a limit is useless if you can't tell which arc it is.
        .opacity(hovered == nil || isHovered ? 1 : 0.45)
        .padding(CGFloat(index) * Self.step)
    }

    @ViewBuilder private var tooltip: some View {
        if let hovered {
            Text("\(hovered.id) \(Int(hovered.pct.rounded()))%")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(theme.text)
                .lineLimit(1)
                // Safe despite the no-fixedSize rule for cards: an overlay never
                // feeds its size back into the card's layout.
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.5))
                .offset(y: 13)
                .transition(.opacity)
        }
    }

    /// Which lane the pointer is over, or nil for the hole, the gaps, and outside.
    private func lane(at point: CGPoint) -> RingLimit? {
        let centre = Self.size / 2 + Self.pad
        let distance = hypot(point.x - centre, point.y - centre)
        let index = Int(((Self.outerRadius + Self.step / 2) - distance) / Self.step)
        guard index >= 0, index < lanes.count else { return nil }
        // Each lane owns its whole band: the gaps are 1pt, so excluding them would
        // only create dead spots the pointer falls into.
        let laneRadius = Self.outerRadius - CGFloat(index) * Self.step
        guard abs(distance - laneRadius) <= Self.step / 2 else { return nil }
        return lanes[index]
    }
}
