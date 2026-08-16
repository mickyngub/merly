// MascotView.swift — Canvas-rendered pixel critter with idle bob, random blink,
// and a squash-and-stretch hop on hover (keyframes ported from the prototype).

import SwiftUI

struct MascotView: View {
    let style: MascotStyle
    let palette: MascotPalette
    let mood: Mood
    var px: CGFloat = 48
    var bob: Bool = true
    var busy: Bool = false
    var hopsOnHover: Bool = true
    /// When set and loadable, renders this 4×4 sprite sheet instead of the drawn critter.
    var spriteName: String? = nil
    /// Identity for the shared animation clock — a provider's config id, or
    /// `MascotAnimator.appKey` for the app's own critter. Keyed mascots idle *and*
    /// flourish in lockstep with every other surface drawing the same key (the menu
    /// bar, the collapsed rail). Leave nil for previews: they idle, but never wander
    /// off the mood they were asked to show.
    var animationKey: String? = nil

    @State private var blink = false
    @State private var bobUp = false
    @State private var hopTrigger = 0
    @State private var frameIndex = 0
    @State private var emoteRow: Int? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sheet: SpriteSheet? {
        guard let spriteName else { return nil }
        return SpriteSheetStore.sheet(named: spriteName)
    }

    private struct Hop {
        var y: CGFloat = 0
        var sx: CGFloat = 1
        var sy: CGFloat = 1
    }

    var body: some View {
        content
            .keyframeAnimator(initialValue: Hop(), trigger: hopTrigger) { view, hop in
                view
                    .scaleEffect(x: hop.sx, y: hop.sy, anchor: UnitPoint(x: 0.5, y: 0.9))
                    .offset(y: hop.y)
            } keyframes: { _ in
                // hop: 0.5s — up -9 squashing, land stretching, small rebound
                KeyframeTrack(\.y) {
                    CubicKeyframe(-9, duration: 0.125)
                    CubicKeyframe(0, duration: 0.15)
                    CubicKeyframe(-2, duration: 0.10)
                    CubicKeyframe(0, duration: 0.125)
                }
                KeyframeTrack(\.sx) {
                    CubicKeyframe(0.94, duration: 0.125)
                    CubicKeyframe(1.08, duration: 0.15)
                    CubicKeyframe(0.98, duration: 0.10)
                    CubicKeyframe(1.0, duration: 0.125)
                }
                KeyframeTrack(\.sy) {
                    CubicKeyframe(1.08, duration: 0.125)
                    CubicKeyframe(0.92, duration: 0.15)
                    CubicKeyframe(1.02, duration: 0.10)
                    CubicKeyframe(1.0, duration: 0.125)
                }
            }
            .offset(y: bobUp ? -3 : 0)
            .animation(
                bobActive
                    ? .easeInOut(duration: busy ? 0.65 : 1.4).repeatForever(autoreverses: true)
                    : .default,
                value: bobUp
            )
            .onAppear { if bobActive { bobUp = true } }
            .onChange(of: bobActive) { _, active in bobUp = active }
            .onHover { inside in
                if inside, hopsOnHover, !reduceMotion, mood != .dead { hopTrigger += 1 }
            }
            .task(id: taskKey) {
                // random blink: 2.2–5.0s apart, 140ms long (skipped while stressed)
                guard sheet == nil else { return } // sprite sheets carry their own blink frames
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 2.2...5.0)))
                    guard !Task.isCancelled else { return }
                    blink = true
                    try? await Task.sleep(for: .milliseconds(140))
                    blink = false
                }
            }
            .onAppear { registerWithClock() }
            .onChange(of: mood) { _, _ in registerWithClock() }
            .onChange(of: animationKey) { _, _ in registerWithClock() }
            .onReceive(MascotAnimator.shared.$frame) { _ in
                // The idle cycle lives in the sheet's columns, so the drawn critter
                // takes only the flourish — it has no frames of its own to advance.
                // (Reduce Motion is handled by the clock, which simply stops ticking.)
                if sheet != nil { frameIndex = MascotAnimator.shared.column(for: animationKey) }
                emoteRow = MascotAnimator.shared.emote(for: animationKey)
            }
    }

    /// Keep the shared clock's idea of this critter current, so its flourishes are
    /// picked against the mood it is actually wearing.
    private func registerWithClock() {
        guard let animationKey else { return }
        MascotAnimator.shared.register(animationKey, moodRow: mood.spriteRow,
                                       animates: mood != .dead)
    }

    private var bobActive: Bool { bob && !reduceMotion && mood != .dead }
    private var taskKey: String { "\(style.rawValue)-\(mood.rawValue)" }

    /// The row on screen: the mood, or the flourish borrowed over it. `.dead` is
    /// frozen by the clock, so it never emotes.
    private var displayRow: Int { emoteRow ?? mood.spriteRow }
    private var displayMood: Mood { emoteRow.map(Mood.fromRow) ?? mood }

    @ViewBuilder private var content: some View {
        spriteContent
            // `.dead` keeps the provider's real sprite, just greyed out and dimmed
            // so it reads as "offline" without needing a baked dead row.
            .saturation(mood == .dead ? 0 : 1)
            .opacity(mood == .dead ? 0.5 : 1)
    }

    @ViewBuilder private var spriteContent: some View {
        if let spriteName, sheet != nil,
           let cg = SpriteSheetStore.recoloredFrame(
               name: spriteName, row: displayRow,
               col: mood == .dead ? 0 : frameIndex, // freeze the frame when offline
               accentHex: palette.B
           ) {
            Image(decorative: cg, scale: 1)
                .interpolation(.high)
                .resizable()
                .frame(width: px, height: px)
        } else {
            sprite
        }
    }

    private var sprite: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let grid = SpriteBuilder.build(style: style, mood: displayMood, blink: blink)
            let cell = size.width / 16
            for y in 0..<16 {
                for x in 0..<16 {
                    guard let color = palette.color(for: grid[x, y]) else { continue }
                    // overlap cells a hair to avoid seams at fractional scales
                    let rect = CGRect(
                        x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                        width: cell + 0.01, height: cell + 0.01
                    )
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: px, height: px)
    }
}
