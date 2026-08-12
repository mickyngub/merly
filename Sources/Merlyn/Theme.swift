// Theme.swift — design tokens ported from the Usage Dock prototype CSS.
// Light/dark variants resolve through the SwiftUI color scheme.

import SwiftUI

struct Theme {
    let text: Color
    let text2: Color
    let text3: Color
    let hairline: Color
    let panelTint: Color
    let panelEdge: Color
    let cardBackground: Color
    let cardBackgroundHover: Color
    let cardBorder: Color
    let track: Color
    let chip: Color

    static let light = Theme(
        text: Color(hex: 0x1D1D1F),
        text2: Color(.sRGB, red: 40/255, green: 40/255, blue: 46/255, opacity: 0.82),
        text3: Color(.sRGB, red: 50/255, green: 50/255, blue: 56/255, opacity: 0.58),
        hairline: Color.black.opacity(0.09),
        panelTint: Color(.sRGB, red: 250/255, green: 250/255, blue: 252/255, opacity: 0.45),
        panelEdge: Color.white.opacity(0.7),
        cardBackground: Color.white.opacity(0.72),
        cardBackgroundHover: Color.white.opacity(0.92),
        cardBorder: Color.black.opacity(0.07),
        track: Color.black.opacity(0.10),
        chip: Color.black.opacity(0.05)
    )

    static let dark = Theme(
        text: Color(hex: 0xF5F5F7),
        text2: Color(.sRGB, red: 238/255, green: 238/255, blue: 246/255, opacity: 0.82),
        text3: Color(.sRGB, red: 232/255, green: 232/255, blue: 242/255, opacity: 0.56),
        hairline: Color.white.opacity(0.10),
        panelTint: Color(.sRGB, red: 28/255, green: 28/255, blue: 32/255, opacity: 0.38),
        panelEdge: Color.white.opacity(0.10),
        cardBackground: Color.white.opacity(0.055),
        cardBackgroundHover: Color.white.opacity(0.10),
        cardBorder: Color.white.opacity(0.09),
        track: Color.white.opacity(0.13),
        chip: Color.white.opacity(0.08)
    )

    static func resolve(_ scheme: ColorScheme) -> Theme {
        scheme == .dark ? .dark : .light
    }

    /// Where a limit turns red — the one severity escalation any gauge applies
    /// (`limitColor`). There is no amber band: see `limitColor` for why.
    static let dangerPct: Double = 88

    /// Where a limit stops being "nearly out" and starts actually blocking work.
    /// Deliberately not `dangerPct`: a red 94% weekly is still usable, and saying
    /// "maxed" there is wrong. 99.5 rather than 100 so it agrees with the rounded
    /// "100% used" the bars print — the API reports fractions like 99.6.
    static let exhaustedPct: Double = 99.5

    static let danger = Color(hex: 0xE5484D)
    /// Amber. Not a usage band — it tints the failure badges, where it means "this
    /// fixes itself" as against `danger`'s "this account is broken".
    static let warn = Color(hex: 0xE8A33D)

    /// The colour a limit is drawn in: its own lane colour (see
    /// `ProviderKind.limitColorHex`), red once it's close to blocking.
    ///
    /// **The one escalation every surface uses** — ring lane, card bar, rail gauge,
    /// menu bar gauge. It deliberately skips the amber warn band: amber is a *third*
    /// meaning laid over a scale where colour already means "which limit", so a 70%
    /// week went amber in the menu bar while the card drew it in its own hue, and the
    /// two surfaces disagreed about the same reading. Only `dangerPct` earns the
    /// override — being about to get blocked is worth breaking the scheme for.
    static func limitColor(pct: Double, lane: Color) -> Color {
        pct >= dangerPct ? danger : lane
    }

    /// Whether near-black ink reads better than white on this colour. Weighted
    /// luminance, not a plain channel average: the eye reads green far brighter than
    /// blue, and an unweighted test put white on Claude's yellow lane and black on
    /// Kimi's violet — both unreadable.
    ///
    /// Needed because the lane band spans both answers by design: `limitColorHex` is
    /// HSL(hue, 0.62, 0.62±), so hue alone decides, and anything writing *on* a lane
    /// colour has to ask rather than assume. Lives beside `limitColor` because it's
    /// the same kind of rule — how a limit's colour is used, not where.
    static func prefersDarkInk(on hex: UInt32) -> Bool {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.55
    }

    /// `hex` blended toward white or black by `amount` (0…1), keeping its hue.
    static func blend(_ hex: UInt32, towardWhite: Bool, amount: Double) -> UInt32 {
        let target = towardWhite ? 255.0 : 0.0
        func mix(_ shift: UInt32) -> UInt32 {
            let channel = Double((hex >> shift) & 0xFF)
            return UInt32((channel + (target - channel) * amount).rounded())
        }
        return mix(16) << 16 | mix(8) << 8 | mix(0)
    }

    /// The 0.32,0.72,0,1 curve used for nearly every transition in the prototype.
    static func snappy(_ duration: Double) -> Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: duration)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
