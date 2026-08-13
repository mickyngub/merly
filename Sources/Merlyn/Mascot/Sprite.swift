// Sprite.swift — pixel "critter" sprite builder. A family of 16x16 sprites
// differentiated by palette + ear style + accessory, with mood-driven faces.
// Direct port of the design prototype's mascots.jsx.

import SwiftUI

enum Mood: String, Comparable {
    case happy, content, tired, stressed, sleeping, excited, wink, curious
    /// No usage signal at all — the login lapsed (expired / signed out). Renders
    /// the provider's real sprite greyed out and dimmed (see `MascotView`), since
    /// the baked sheets have no dead row of their own.
    case dead

    /// Mood breakpoints below the danger line. `.stressed` deliberately shares
    /// `UsageThresholds.dangerPct` so the critter frets at exactly the moment the
    /// gauges go red — two surfaces disagreeing about "how bad" reads as a bug.
    static let tiredPct: Double = 66
    static let contentPct: Double = 40

    static func from(pct: Double) -> Mood {
        if pct >= UsageThresholds.dangerPct { return .stressed }
        if pct >= tiredPct { return .tired }
        if pct >= contentPct { return .content }
        return .happy
    }

    var tagWord: String {
        switch self {
        case .happy: "CHILL"
        case .content: "OK"
        case .tired: "BUSY"
        case .stressed: "FRIED"
        case .sleeping: "ZZZ"
        case .excited: "GO!"
        case .wink: "WINK"
        case .curious: "HMM?"
        case .dead: "OFFLINE"
        }
    }

    var tagForeground: Color {
        switch self {
        case .happy: Color(hex: 0x1F8A4C)
        case .content: Color(hex: 0x1F6FD6)
        case .tired: Color(hex: 0xB5710E)
        case .stressed: Color(hex: 0xD23B3B)
        case .sleeping: Color(hex: 0x4A7AB5)
        case .excited: Color(hex: 0xD97B20)
        case .wink: Color(hex: 0x8B5CF6)
        case .curious: Color(hex: 0x0891B2)
        case .dead: Color(hex: 0x8A8A8E)
        }
    }

    var tagBackground: Color {
        switch self {
        case .happy: Color(hex: 0x34C759, alpha: 0.16)
        case .content: Color(hex: 0x1F6FD6, alpha: 0.15)
        case .tired: Color(hex: 0xE8A33D, alpha: 0.18)
        case .stressed: Color(hex: 0xE5484D, alpha: 0.18)
        case .sleeping: Color(hex: 0x6B9FD4, alpha: 0.15)
        case .excited: Color(hex: 0xFF9B3D, alpha: 0.18)
        case .wink: Color(hex: 0x8B5CF6, alpha: 0.15)
        case .curious: Color(hex: 0x06B6D4, alpha: 0.15)
        case .dead: Color(hex: 0x8A8A8E, alpha: 0.15)
        }
    }

    // Pressure rank for Comparable — sleeping/excited/wink/curious/dead sit at
    // the happy level (no usage pressure to escalate the mood).
    private var rank: Int {
        switch self {
        case .sleeping, .excited, .wink, .curious, .dead: 0
        case .happy: 1; case .content: 2; case .tired: 3; case .stressed: 4
        }
    }
    static func < (lhs: Mood, rhs: Mood) -> Bool { lhs.rank < rhs.rank }

    /// Row index into a sprite sheet (top→bottom: happy, content, tired, stressed, sleeping, excited, wink, curious).
    /// `.dead` has no row of its own; it borrows row 0 and `MascotView` greys it out.
    var spriteRow: Int {
        switch self {
        case .happy: 0; case .content: 1; case .tired: 2; case .stressed: 3
        case .sleeping: 4; case .excited: 5; case .wink: 6; case .curious: 7
        case .dead: 0
        }
    }

    /// Inverse of `spriteRow`, for picking expressions straight off a sheet.
    static func fromRow(_ row: Int) -> Mood {
        switch row {
        case 0: .happy; case 1: .content; case 2: .tired; case 3: .stressed
        case 4: .sleeping; case 5: .excited; case 6: .wink; case 7: .curious
        default: .happy
        }
    }
}

enum MascotStyle: String, Codable {
    case cat       // pointy ears (Claude Personal)
    case catTie    // pointy ears + tie (Claude Work)
    case robot     // antenna + bolts (Codex)
    case round     // round ears + crescent moon (Kimi)
}

/// Sprite palette. Keys mirror the prototype: B body, D dark shade, L light belly,
/// O outline, E eye, W eye-white, M mouth, C cheek blush, S sweat, A accessory.
struct MascotPalette: Codable, Equatable {
    var B, D, L, O, E, W, M, C, S, A: UInt32

    /// Channel letter → packed hex. The one place the letter mapping lives:
    /// both renderers (SwiftUI `color(for:)`, AppKit in `StatusItemController`)
    /// derive from it, so the two can't drift.
    func hex(for ch: Character) -> UInt32? {
        switch ch {
        case "B": B
        case "D": D
        case "L": L
        case "O": O
        case "E": E
        case "W": W
        case "M": M
        case "C": C
        case "S": S
        case "A": A
        default: nil
        }
    }

    func color(for ch: Character) -> Color? {
        hex(for: ch).map { Color(hex: $0) }
    }

    var accent: Color { Color(hex: B) }

    /// A full critter palette generated from a single hue (degrees). Saturation
    /// and lightness are pinned per channel to pleasant bands, so *any* hue yields
    /// a readable mascot — no mud, no neon. `satBoost`/`lightBoost` nudge every
    /// generated channel: the shiny "gleam". The sweat drop keeps its universal
    /// blue and the eye-white stays white regardless of hue. Sprite mascots tint
    /// toward `B` (see `SpriteRecolor`); the rest drive the drawn critter.
    static func fromHue(_ hue: Double, satBoost: Double = 0, lightBoost: Double = 0) -> MascotPalette {
        func ch(_ s: Double, _ l: Double) -> UInt32 {
            hslHex(h: hue, s: min(1, max(0, s + satBoost)), l: min(1, max(0, l + lightBoost)))
        }
        return MascotPalette(
            B: ch(0.62, 0.62),   // body
            D: ch(0.55, 0.47),   // dark shade
            L: ch(0.70, 0.84),   // light belly
            O: ch(0.58, 0.28),   // outline
            E: ch(0.40, 0.14),   // eye — near-black, faintly hue-tinted
            W: 0xFFFFFF,         // eye-white
            M: ch(0.58, 0.28),   // mouth (= outline)
            C: ch(0.82, 0.75),   // cheek blush
            S: 0x8FBFFF,         // sweat drop — fixed blue
            A: ch(0.70, 0.84)    // accessory (= light belly)
        )
    }

    /// HSL (h in degrees, s & l in 0...1) → packed 0xRRGGBB.
    static func hslHex(h: Double, s: Double, l: Double) -> UInt32 {
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 360
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func toRGB(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let r = s == 0 ? l : toRGB(hh + 1.0 / 3)
        let g = s == 0 ? l : toRGB(hh)
        let b = s == 0 ? l : toRGB(hh - 1.0 / 3)
        func byte(_ v: Double) -> UInt32 { UInt32(min(255, max(0, (v * 255).rounded()))) }
        return (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }
}

/// 16x16 character grid; "." is transparent.
struct SpriteGrid {
    private(set) var cells: [[Character]]

    init() { cells = Array(repeating: Array(repeating: ".", count: 16), count: 16) }

    mutating func set(_ x: Int, _ y: Int, _ ch: Character) {
        guard (0..<16).contains(x), (0..<16).contains(y) else { return }
        cells[y][x] = ch
    }

    subscript(x: Int, y: Int) -> Character { cells[y][x] }
}

enum SpriteBuilder {
    // y row -> inclusive [start, end] body span
    private static let bodyRows: [Int: (Int, Int)] = [
        5: (5, 10), 6: (4, 11), 7: (3, 12), 8: (3, 12), 9: (3, 12),
        10: (3, 12), 11: (3, 12), 12: (3, 12), 13: (4, 11), 14: (5, 10),
    ]

    static func build(style: MascotStyle, mood: Mood, blink: Bool) -> SpriteGrid {
        var g = base(style: style)
        outline(&g)
        stampFace(&g, mood: mood, blink: blink)
        return g
    }

    private static func base(style: MascotStyle) -> SpriteGrid {
        var g = SpriteGrid()
        for (y, span) in bodyRows {
            for x in span.0...span.1 { g.set(x, y, "B") }
        }
        // belly highlight
        for y in 10...12 { for x in 6...9 { g.set(x, y, "L") } }
        // feet (split the bottom into two)
        g.set(7, 14, "."); g.set(8, 14, ".")
        g.set(5, 14, "D"); g.set(6, 14, "D"); g.set(9, 14, "D"); g.set(10, 14, "D")

        switch style {
        case .cat, .catTie:
            // cat / fox ears
            g.set(3, 3, "B"); g.set(3, 4, "B"); g.set(4, 4, "B"); g.set(4, 5, "B")
            g.set(12, 3, "B"); g.set(12, 4, "B"); g.set(11, 4, "B"); g.set(11, 5, "B")
            g.set(4, 4, "D"); g.set(11, 4, "D")
            if style == .catTie { g.set(8, 12, "A"); g.set(8, 13, "A") } // tie
        case .robot:
            // antenna
            g.set(8, 4, "A"); g.set(8, 3, "A"); g.set(7, 2, "A"); g.set(8, 2, "A")
            // side bolts
            g.set(3, 9, "D"); g.set(12, 9, "D")
        case .round:
            // round ears
            g.set(4, 4, "B"); g.set(5, 4, "B"); g.set(4, 5, "B")
            g.set(10, 4, "B"); g.set(11, 4, "B"); g.set(11, 5, "B")
            // floating crescent moon accent
            g.set(13, 3, "A"); g.set(13, 4, "A"); g.set(14, 4, "A"); g.set(13, 5, "A")
        }
        return g
    }

    private static let solid: Set<Character> = ["B", "D", "L", "A"]

    private static func outline(_ g: inout SpriteGrid) {
        let dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        var adds: [(Int, Int)] = []
        for y in 0..<16 {
            for x in 0..<16 where g[x, y] == "." {
                for (dx, dy) in dirs {
                    let nx = x + dx, ny = y + dy
                    if (0..<16).contains(nx), (0..<16).contains(ny), solid.contains(g[nx, ny]) {
                        adds.append((x, y))
                        break
                    }
                }
            }
        }
        for (x, y) in adds { g.set(x, y, "O") }
    }

    private static func stampFace(_ g: inout SpriteGrid, mood: Mood, blink: Bool) {
        let lx = 6, rx = 9 // eye columns
        // sleeping/wink/dead already have intentional eye states — don't let blink overwrite them
        if blink, mood != .stressed, mood != .sleeping, mood != .wink, mood != .dead {
            g.set(lx, 8, "E"); g.set(rx, 8, "E")
            g.set(7, 11, "M"); g.set(8, 11, "M") // flat smile underneath stays
            return
        }
        switch mood {
        case .happy:
            g.set(lx, 8, "E"); g.set(rx, 8, "E")
            g.set(5, 9, "C"); g.set(10, 9, "C")                                   // blush
            g.set(6, 11, "M"); g.set(9, 11, "M"); g.set(7, 12, "M"); g.set(8, 12, "M") // smile
        case .content:
            g.set(lx, 8, "E"); g.set(rx, 8, "E")
            g.set(7, 11, "M"); g.set(8, 11, "M")
        case .tired:
            g.set(lx, 8, "E"); g.set(rx, 8, "E")
            g.set(5, 7, "D"); g.set(6, 7, "D"); g.set(9, 7, "D"); g.set(10, 7, "D") // heavy lids
            g.set(7, 12, "M"); g.set(8, 12, "M")                                    // low mouth
            g.set(12, 7, "S"); g.set(12, 8, "S")                                    // sweat drop
        case .stressed:
            g.set(5, 7, "W"); g.set(6, 7, "W"); g.set(5, 8, "W"); g.set(6, 8, "W"); g.set(6, 8, "E")
            g.set(9, 7, "W"); g.set(10, 7, "W"); g.set(9, 8, "W"); g.set(10, 8, "W"); g.set(9, 8, "E")
            g.set(7, 11, "M"); g.set(8, 11, "M"); g.set(7, 12, "M"); g.set(8, 12, "M") // open mouth
            g.set(3, 7, "S"); g.set(12, 7, "S")                                        // sweat
        case .sleeping:
            g.set(5, 8, "D"); g.set(6, 8, "D")                                     // left eye closed
            g.set(9, 8, "D"); g.set(10, 8, "D")                                    // right eye closed
            g.set(11, 5, "S"); g.set(12, 5, "S")                                   // zzz top stroke
            g.set(12, 6, "S")                                                       // zzz diagonal
            g.set(11, 7, "S"); g.set(12, 7, "S")                                   // zzz bottom stroke
            g.set(7, 12, "M"); g.set(8, 12, "M")                                   // relaxed mouth
        case .excited:
            g.set(lx, 8, "E"); g.set(rx, 8, "E")
            g.set(5, 6, "A"); g.set(10, 6, "A")                                    // sparkle dots above eyes
            g.set(4, 9, "C"); g.set(5, 9, "C"); g.set(10, 9, "C"); g.set(11, 9, "C") // wide cheeks
            g.set(6, 11, "M"); g.set(9, 11, "M"); g.set(7, 12, "M"); g.set(8, 12, "M") // big smile
        case .wink:
            g.set(5, 8, "D"); g.set(6, 8, "D")                                     // left eye closed (line)
            g.set(rx, 8, "E")                                                       // right eye open
            g.set(5, 9, "C"); g.set(10, 9, "C")                                    // cheeks
            g.set(6, 11, "M"); g.set(9, 11, "M"); g.set(7, 12, "M"); g.set(8, 12, "M") // smile
        case .curious:
            g.set(7, 7, "E"); g.set(10, 7, "E")                                    // eyes shifted up-right
            g.set(12, 5, "S"); g.set(12, 6, "S")                                   // small ! dot (noticing something)
            g.set(7, 11, "M"); g.set(8, 11, "M")                                   // flat mouth
        case .dead:
            // knocked-out "X" eyes + flat mouth (login lapsed — no data)
            g.set(5, 7, "E"); g.set(7, 7, "E"); g.set(6, 8, "E"); g.set(5, 9, "E"); g.set(7, 9, "E") // left ✕
            g.set(8, 7, "E"); g.set(10, 7, "E"); g.set(9, 8, "E"); g.set(8, 9, "E"); g.set(10, 9, "E") // right ✕
            g.set(7, 12, "M"); g.set(8, 12, "M")                                    // low flat mouth
        }
    }
}
