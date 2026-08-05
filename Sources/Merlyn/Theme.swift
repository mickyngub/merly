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

    /// Ring/bar warning escalation from the prototype: amber at 66%, red at 88%.
    static let warnPct: Double = 66
    static let dangerPct: Double = 88

    /// Where a limit stops being "nearly out" and starts actually blocking work.
    /// Deliberately not `dangerPct`: a red 94% weekly is still usable, and saying
    /// "maxed" there is wrong. 99.5 rather than 100 so it agrees with the rounded
    /// "100% used" the bars print — the API reports fractions like 99.6.
    static let exhaustedPct: Double = 99.5

    static let danger = Color(hex: 0xE5484D)
    static let warn = Color(hex: 0xE8A33D)

    static func usageColor(pct: Double, accent: Color) -> Color {
        if pct >= dangerPct { return danger }
        if pct >= warnPct { return warn }
        return accent
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
