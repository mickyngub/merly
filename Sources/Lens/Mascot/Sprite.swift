// Sprite.swift — pixel "critter" sprite builder. A family of 16x16 sprites
// differentiated by palette + ear style + accessory, with mood-driven faces.
// Direct port of the design prototype's mascots.jsx.

import SwiftUI

enum Mood: String, Comparable {
    case happy, content, tired, stressed, sleeping, excited, wink, curious

    static func from(pct: Double) -> Mood {
        if pct >= 88 { return .stressed }
        if pct >= 66 { return .tired }
        if pct >= 40 { return .content }
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
        }
    }

    // Pressure rank for Comparable — sleeping/excited/wink/curious sit at the happy level.
    private var rank: Int {
        switch self {
        case .sleeping, .excited, .wink, .curious: 0
        case .happy: 1; case .content: 2; case .tired: 3; case .stressed: 4
        }
    }
    static func < (lhs: Mood, rhs: Mood) -> Bool { lhs.rank < rhs.rank }

    /// Row index into a sprite sheet (top→bottom: happy, content, tired, stressed, sleeping, excited, wink, curious).
    var spriteRow: Int {
        switch self {
        case .happy: 0; case .content: 1; case .tired: 2; case .stressed: 3
        case .sleeping: 4; case .excited: 5; case .wink: 6; case .curious: 7
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

    func color(for ch: Character) -> Color? {
        switch ch {
        case "B": Color(hex: B)
        case "D": Color(hex: D)
        case "L": Color(hex: L)
        case "O": Color(hex: O)
        case "E": Color(hex: E)
        case "W": Color(hex: W)
        case "M": Color(hex: M)
        case "C": Color(hex: C)
        case "S": Color(hex: S)
        case "A": Color(hex: A)
        default: nil
        }
    }

    var accent: Color { Color(hex: B) }

    static let presets: [String: MascotPalette] = [
        "coral":  .init(B: 0xE8825C, D: 0xC2603C, L: 0xF7CBB4, O: 0x80391F, E: 0x3A2416, W: 0xFFFFFF, M: 0x8A3D24, C: 0xFF9C7E, S: 0x8FBFFF, A: 0xF7CBB4),
        "steel":  .init(B: 0x5E80AC, D: 0x3F5C84, L: 0xC6D7EC, O: 0x2B3F5C, E: 0x1E2A3A, W: 0xFFFFFF, M: 0x2B3F5C, C: 0xF0A2AE, S: 0x8FBFFF, A: 0xE8825C),
        "green":  .init(B: 0x41A87C, D: 0x2C7E5A, L: 0xBFE8D2, O: 0x1B5239, E: 0x143526, W: 0xFFFFFF, M: 0x1B5239, C: 0x79D6A8, S: 0x8FBFFF, A: 0xA8ECC8),
        "purple": .init(B: 0x8C6DE2, D: 0x6A4CC2, L: 0xDBCCF7, O: 0x432D85, E: 0x281A4D, W: 0xFFFFFF, M: 0x432D85, C: 0xF0A2D6, S: 0x8FBFFF, A: 0xF5D67A),
        // extra presets so a 5th/6th provider is just a name in providers.json
        "gold":   .init(B: 0xE0A83D, D: 0xB8842A, L: 0xF7E3B4, O: 0x7A5212, E: 0x3A2C10, W: 0xFFFFFF, M: 0x8A5F18, C: 0xFFC97E, S: 0x8FBFFF, A: 0xF7E3B4),
        "pink":   .init(B: 0xE06A9F, D: 0xBC4A7E, L: 0xF7C2DA, O: 0x7E2450, E: 0x3A1426, W: 0xFFFFFF, M: 0x8A2B58, C: 0xFF9CC4, S: 0x8FBFFF, A: 0xF7C2DA),
    ]

    /// Stable display order for palette pickers (dictionaries don't keep one).
    static let presetOrder = ["coral", "steel", "green", "purple", "gold", "pink"]

    static func preset(_ name: String?) -> MascotPalette {
        presets[name ?? "coral"] ?? presets["coral"]!
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
        // sleeping/wink already have intentional eye states — don't let blink overwrite them
        if blink, mood != .stressed, mood != .sleeping, mood != .wink {
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
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
