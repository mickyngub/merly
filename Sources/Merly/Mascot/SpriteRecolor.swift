// SpriteRecolor.swift — duotone-tints a baked sprite frame toward a palette
// accent. Sprite sheets are fixed-color art (coral Clawd, blue Codex blob,
// black Kimi), so the only way a chosen color can reach them is a tint. We map
// each pixel's luminance through a dark→accent→light ramp, preserving the art's
// shading, face, and alpha — so the mascot follows its color the same way the
// drawn critter does. Frames cycle at ~5fps across several mascots, so every
// (frame, accent) result is memoized.

import CoreGraphics

/// `@MainActor` because the memo cache is unsynchronized shared state and both
/// renderers (`MascotView`, `StatusItemController`) already call from the main
/// thread. The cache is unbounded but effectively capped by the art: entries are
/// keyed (sheet, row, col, accent), and all of those are small finite sets.
@MainActor
enum SpriteRecolor {
    /// Duotone endpoints, blending the accent toward black (shadows) and white
    /// (highlights). Tuned so Clawd's near-black eyes stay crisp while a mostly
    /// black sprite like Kimi still takes on the color.
    private static let shadow = 0.15
    private static let highlight = 0.90

    private static var cache: [String: CGImage] = [:]

    /// Recolor `image` toward `accentHex` (0xRRGGBB). `cacheKey` should uniquely
    /// identify the source frame (e.g. "sheet|row|col"); the accent is folded in.
    static func tint(_ image: CGImage, cacheKey: String, accentHex hex: UInt32) -> CGImage? {
        let key = "\(cacheKey)|\(hex)"
        if let hit = cache[key] { return hit }
        guard let out = render(image, accentHex: hex) else { return nil }
        cache[key] = out
        return out
    }

    private static func render(_ image: CGImage, accentHex hex: UInt32) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let bytesPerRow = w * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let ar = Double((hex >> 16) & 0xFF)
        let ag = Double((hex >> 8) & 0xFF)
        let ab = Double(hex & 0xFF)
        let dr = ar * shadow, dg = ag * shadow, db = ab * shadow
        let lr = ar + (255 - ar) * highlight
        let lg = ag + (255 - ag) * highlight
        let lb = ab + (255 - ab) * highlight

        // Luminance (0...1) → tritone ramp: dark → accent (mid) → light.
        @inline(__always) func ramp(_ l: Double) -> (Double, Double, Double) {
            if l <= 0.5 {
                let t = l / 0.5
                return (dr + (ar - dr) * t, dg + (ag - dg) * t, db + (ab - db) * t)
            }
            let t = (l - 0.5) / 0.5
            return (ar + (lr - ar) * t, ag + (lg - ag) * t, ab + (lb - ab) * t)
        }

        var i = 0
        while i < buf.count {
            let a = buf[i + 3]
            if a != 0 {
                // Premultiplied buffer: un-premultiply to recover true color for
                // luminance, recolor, then re-premultiply. (r ≤ a always holds,
                // so r/af stays in 0...255.)
                let af = Double(a) / 255.0
                let r = Double(buf[i]) / af
                let g = Double(buf[i + 1]) / af
                let b = Double(buf[i + 2]) / af
                let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                let (nr, ng, nb) = ramp(min(max(lum, 0), 1))
                buf[i]     = UInt8(min(255, max(0, (nr * af).rounded())))
                buf[i + 1] = UInt8(min(255, max(0, (ng * af).rounded())))
                buf[i + 2] = UInt8(min(255, max(0, (nb * af).rounded())))
            }
            i += 4
        }
        return ctx.makeImage()
    }
}

extension SpriteSheetStore {
    /// A sprite frame recolored toward `accentHex`, the one-stop call both the
    /// panel (SwiftUI) and menu bar (AppKit) renderers use.
    static func recoloredFrame(name: String, row: Int, col: Int, accentHex: UInt32) -> CGImage? {
        guard let frame = sheet(named: name)?.frame(row: row, col: col) else { return nil }
        // Full-colour designed sheets could opt out of the tint here to keep their
        // own palette; none do today — the Merly wizard included, so its swatches
        // recolour it like every other mascot.
        if fullColorSheets.contains(name) { return frame }
        return SpriteRecolor.tint(frame, cacheKey: "\(name)|\(row)|\(col)", accentHex: accentHex)
    }

    /// Sheets rendered as-is (their own palette), never accent-tinted. Empty today.
    private static let fullColorSheets: Set<String> = []
}
