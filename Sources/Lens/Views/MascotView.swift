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

    @State private var blink = false
    @State private var bobUp = false
    @State private var hopTrigger = 0
    @State private var frameIndex = 0
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
                if inside, hopsOnHover, !reduceMotion { hopTrigger += 1 }
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
            .task(id: spriteName ?? "") {
                // cycle the 4 idle frames of the current mood row (~5 fps)
                guard sheet != nil, !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    frameIndex = (frameIndex + 1) % 4
                }
            }
    }

    private var bobActive: Bool { bob && !reduceMotion }
    private var taskKey: String { "\(style.rawValue)-\(mood.rawValue)" }

    @ViewBuilder private var content: some View {
        if let sheet, let cg = sheet.frame(row: mood.spriteRow, col: frameIndex) {
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
            let grid = SpriteBuilder.build(style: style, mood: mood, blink: blink)
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
