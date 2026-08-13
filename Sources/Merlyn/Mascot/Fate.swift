// Fate.swift — per-install destiny for mascot colors and shininess.

import Foundation

/// Per-install destiny for a mascot's color and shininess. Everything derives
/// deterministically from the home path — there is no stored seed, so a mascot's
/// fate can't be re-rolled by deleting or editing providers.json. Reinstalling
/// macOS or changing username gives a new fate; that's the only thing that does.
///
/// **Color** is a "deck": one signature `base` hue per machine, then evenly
/// spread golden-angle hues for each `slot`. The deck's hues are fixed; which
/// `slot` a mascot wears is the only editable part (stored as `colorSlot`).
///
/// **Shiny** is a one-shot lottery keyed by mascot id (independent of color, so a
/// mascot's luck never changes when others are added, removed, or recolored). The
/// lucky few wear a gleaming `+150°` variant. No accumulation, no "moment of
/// catching" — you either were born lucky on this machine or you weren't.
enum Fate {
    /// How many distinct hues the editor offers (the golden-angle deck size).
    static let deckSize = 6
    /// The most-separated rotation increment — successive slots are maximally apart.
    static let goldenAngle = 137.50776405003785

    /// 1-in-N one-shot shiny odds. `MERLYN_SHINY_RARITY` overrides it for tuning or
    /// testing (set it to 1 to make every mascot shiny).
    static var rarity: UInt64 {
        if let raw = ProcessInfo.processInfo.environment["MERLYN_SHINY_RARITY"],
           let n = UInt64(raw), n >= 1 { return n }
        return 128
    }

    /// The install's signature hue (0..<360), hashed from the home path.
    static func baseHue(home: String = NSHomeDirectory()) -> Double {
        Double(hash(home) % 360)
    }

    /// Golden-angle deck hue for `slot`: base + slot×137.5°. Evenly spread and
    /// append-stable — a new mascot takes the next slot without moving earlier ones.
    static func deckHue(slot: Int, home: String = NSHomeDirectory()) -> Double {
        (baseHue(home: home) + Double(slot) * goldenAngle)
            .truncatingRemainder(dividingBy: 360)
    }

    /// The hue a mascot actually wears: its deck hue, shifted for a shiny. Exposed
    /// so anything deriving companion colours (the card's ring lanes) starts from
    /// the same hue the mascot is wearing rather than the unshifted deck value.
    static func hue(slot: Int, shiny: Bool, home: String = NSHomeDirectory()) -> Double {
        deckHue(slot: slot, home: home) + (shiny ? 150 : 0)
    }

    /// The resolved palette for a mascot in `slot`, gleaming if `shiny`.
    static func palette(slot: Int, shiny: Bool, home: String = NSHomeDirectory()) -> MascotPalette {
        let hue = hue(slot: slot, shiny: shiny, home: home)
        return shiny
            ? .fromHue(hue, satBoost: 0.08, lightBoost: 0.04)
            : .fromHue(hue)
    }

    /// One-shot shiny verdict, keyed by mascot id. Stable forever.
    static func isShiny(id: String, home: String = NSHomeDirectory()) -> Bool {
        hash("\(home)|\(id)|shiny") % rarity == 0
    }

    /// Stable per-id deck slot, used only as a safety fallback when a mascot has
    /// no stored slot yet (normal slots are assigned at creation/migration).
    static func fallbackSlot(id: String, home: String = NSHomeDirectory()) -> Int {
        Int(hash("\(home)|\(id)|slot") % UInt64(deckSize))
    }

    /// FNV-1a over the string's UTF-8 → uniform-ish 64-bit.
    private static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
