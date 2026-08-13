// ProviderConfig.swift — the user-editable provider entries in providers.json,
// plus the app's own (menu bar) mascot config.

import Foundation

/// The app's own mascot, shown beside the panel's "Merlyn" title. Independent of
/// any provider; its look is user-editable while its mood tracks the busiest
/// provider's pressure. (The menu bar always wears the *reported provider's*
/// critter instead, so a reading always has a visible subject.)
struct DefaultMascot: Codable, Equatable {
    var style: MascotStyle
    /// User-chosen index into the fated deck (see `Fate`). The deck's *hues* are
    /// fixed per machine; only this mapping is editable. Optional so older configs
    /// decode (absent → the signature slot 0).
    var colorSlot: Int?
    /// Bundled sprite-sheet basename; "" renders the drawn critter instead.
    var sprite: String

    static let standard = DefaultMascot(style: .cat, sprite: "merlyn-sprite")

    /// Sprite sheet to render, or nil when drawing the critter.
    var resolvedSprite: String? { sprite.isEmpty ? nil : sprite }

    /// The menu bar mascot sits in deck slot 0 by default — the install's
    /// signature hue — so adding or removing providers never recolors it.
    var resolvedColorSlot: Int { colorSlot ?? 0 }

    /// Fate's one-shot shiny verdict for the menu bar mascot.
    var isShiny: Bool { Fate.isShiny(id: "menu-bar-mascot") }

    var resolvedPalette: MascotPalette { Fate.palette(slot: resolvedColorSlot, shiny: isShiny) }
}

struct ProviderConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var account: String
    var kind: ProviderKind
    var dir: String
    var style: MascotStyle?
    /// User-chosen index into the fated deck (see `Fate`); the deck's hues are
    /// fixed per machine, only this mapping is editable. Optional so older configs
    /// decode (absent → a slot assigned by position on first load).
    var colorSlot: Int?
    /// Bundled sprite-sheet basename (4-column grid: rows = mood, cols = idle frames).
    /// When resolvable, the panel mascot renders this art instead of the drawn critter.
    var sprite: String?
    /// Optional fixed denominators for token-estimated providers. When absent,
    /// limits auto-calibrate to the busiest 5h block / 7-day stretch on record.
    var sessionTokenLimit: Int?
    var weeklyTokenLimit: Int?

    var expandedDir: String {
        (dir as NSString).expandingTildeInPath
    }

    /// The shell line that signs this specific provider back in: the CLI's own
    /// login, prefixed with the config-dir env var when this provider doesn't live
    /// in the kind's default folder (a second account signs into its own profile).
    var loginShellCommand: String {
        guard dir != kind.defaultDir, let envVar = kind.configDirEnvVar else {
            return kind.loginCommand
        }
        return "\(envVar)=\(expandedDir.shellQuoted) \(kind.loginCommand)"
    }

    var resolvedStyle: MascotStyle { style ?? kind.defaultStyle }

    /// The deck slot this provider wears, falling back to a stable per-id slot
    /// until the position-based default is persisted (see `ConfigStore.migrate`).
    var resolvedColorSlot: Int { colorSlot ?? Fate.fallbackSlot(id: id) }

    /// Fate's one-shot shiny verdict for this provider.
    var isShiny: Bool { Fate.isShiny(id: id) }

    var resolvedPalette: MascotPalette { Fate.palette(slot: resolvedColorSlot, shiny: isShiny) }

    /// Sprite sheet to render in the panel, falling back to the per-kind default
    /// art. Returns nil only if a provider explicitly opts out via sprite: "".
    var resolvedSprite: String? {
        if let sprite { return sprite.isEmpty ? nil : sprite }
        return kind.defaultSprite
    }
}
