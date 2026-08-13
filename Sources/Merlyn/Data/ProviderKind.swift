// ProviderKind.swift — the supported provider kinds and the one-stop fact
// table (`ProviderDescriptor`) each kind derives everything from.

import Foundation

/// Everything the app must know about a provider *kind*, in one place.
///
/// Adding a provider kind = one descriptor below + one reader (and, for an
/// API-backed provider, an API client — see `docs/provider-integration.md`)
/// + a bundled sprite sheet + an entry in `AppConfig.knownProviders` for
/// first-run auto-detection. Every `ProviderKind` member derives from this
/// table, so nothing else in the app switches on the kind.
struct ProviderDescriptor {
    /// Human-facing kind name ("Claude").
    let displayName: String
    /// Where the matching CLI keeps its config by default.
    let defaultDir: String
    /// The CLI subcommand that starts this kind's own sign-in flow.
    ///
    /// Merlyn never mints or refreshes a token itself — see the never-refresh
    /// rule in `docs/provider-integration.md`. The sign-in button runs the
    /// CLI's login in a terminal and lets it own the credentials, exactly as
    /// if the user had opened the agent and typed this.
    let loginCommand: String
    /// Env var that points this kind's CLI at a non-default config dir, so a
    /// second account (`~/.claude-2`, `~/.claude-work`) signs into its own
    /// profile instead of overwriting the first. nil when the CLI has no such
    /// override.
    let configDirEnvVar: String?
    /// Sprite sheets this kind's mascot may use — its own family only, so the
    /// editor can't dress a Claude provider up as Codex/Kimi. One art per
    /// kind: color is set by the palette (the old "Work" sprite was just a
    /// blue Clawd). The first entry is the kind's default art.
    let spriteFamily: [(id: String, label: String)]
    /// Drawn-critter style used when a provider has none configured.
    let defaultStyle: MascotStyle
    /// Where this kind's limit colours start on the wheel — see
    /// `ProviderKind.limitColorHex`. The kinds sit ~100° apart, wide enough
    /// that no Claude lane can be mistaken for a Codex one, and the run avoids
    /// the two hues severity owns: `Theme.danger` (~358°) and `Theme.warn`
    /// (~40°) must never be something a healthy limit wears.
    let limitBaseHue: Double
    /// Builds this kind's usage reader (see `Readers.swift`).
    let makeReader: () -> UsageReader
}

extension ProviderDescriptor {
    static let claude = ProviderDescriptor(
        displayName: "Claude",
        defaultDir: "~/.claude",
        loginCommand: "claude auth login",
        configDirEnvVar: "CLAUDE_CONFIG_DIR",
        spriteFamily: [("clawd-sprite", "Clawd")],
        defaultStyle: .cat,
        limitBaseHue: 60,    // yellow → lime → green
        makeReader: { ClaudeReader() }
    )

    static let codex = ProviderDescriptor(
        displayName: "Codex",
        defaultDir: "~/.codex",
        loginCommand: "codex login",
        configDirEnvVar: "CODEX_HOME",
        spriteFamily: [("codex-sprite", "Codex")],
        defaultStyle: .robot,
        limitBaseHue: 190,   // cyan → blue → indigo
        makeReader: { CodexReader() }
    )

    static let kimi = ProviderDescriptor(
        displayName: "Kimi",
        defaultDir: "~/.kimi-code",
        loginCommand: "kimi login",
        configDirEnvVar: nil,
        spriteFamily: [("kimi-sprite", "Kimi")],
        defaultStyle: .round,
        limitBaseHue: 290,   // violet → magenta → pink
        makeReader: { KimiReader() }
    )
}

enum ProviderKind: String, Codable, CaseIterable {
    /// Claude Code-style config dir: transcripts under projects/**/*.jsonl
    case claude
    /// Codex CLI: rollout files under sessions/YYYY/MM/DD/*.jsonl with real rate_limits
    case codex
    /// Kimi Code: wire.jsonl event logs under sessions/wd_*/ses_*/agents/*
    case kimi

    /// The kind's fact table. A switch rather than a dictionary lookup so a new
    /// case is a compile error until its descriptor exists.
    var descriptor: ProviderDescriptor {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .kimi: .kimi
        }
    }

    var displayName: String { descriptor.displayName }
    var defaultDir: String { descriptor.defaultDir }
    var loginCommand: String { descriptor.loginCommand }
    var configDirEnvVar: String? { descriptor.configDirEnvVar }
    var spriteFamily: [(id: String, label: String)] { descriptor.spriteFamily }
    /// The kind's default sprite art — the first (and today only) family entry.
    var defaultSprite: String? { descriptor.spriteFamily.first?.id }
    var defaultStyle: MascotStyle { descriptor.defaultStyle }

    /// The colour a limit lane wears, packed 0xRRGGBB: this kind's band, stepped by
    /// the limit's category rank (see `ProviderSnapshot.laneRank`). Hex rather than
    /// `Color` because the menu bar gauge draws in AppKit.
    ///
    /// Keyed on the *kind*, never on the account's mascot palette: two Claude cards
    /// stack in one panel, and a colour that meant "5h" on one and "weekly" on the
    /// next made the panel unreadable. Account identity stays with the mascot.
    ///
    /// Each step moves hue *and* lightness. Hue alone doesn't separate lanes — 25°
    /// apart in the greens gave "All models" and "Fable only" two near-identical
    /// bars — and hue steps wide enough to fix that would walk out of the kind's
    /// band. Alternating light/dark makes neighbouring lanes differ in value, which
    /// survives a 6pt bar and a 3pt menu bar gauge.
    func limitColorHex(rank: Int) -> UInt32 {
        let hue = descriptor.limitBaseHue + Double(rank) * 25
        let light = rank == 0 ? 0 : (rank.isMultiple(of: 2) ? -0.15 : 0.14)
        return MascotPalette.fromHue(hue, lightBoost: light).B
    }
}

/// Builds the reader for a provider kind — a thin alias over the registry.
func reader(for kind: ProviderKind) -> UsageReader {
    kind.descriptor.makeReader()
}
