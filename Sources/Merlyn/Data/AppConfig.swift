// AppConfig.swift — the root of providers.json: providers, refresh cadence,
// alerts, and the menu bar mascot/pin. User-editable at runtime; the engine
// reloads it every refresh cycle.

import Foundation

/// User-tunable alerting. Persisted inside AppConfig so it rides the same
/// providers.json the engine reloads every refresh.
struct NotificationSettings: Codable, Equatable {
    /// Master switch for all usage alerts.
    var enabled: Bool = false
    /// Notify when a provider's closest-limit pressure first crosses this %.
    var thresholdPct: Double = 80
    /// Notify when a previously-busy session window resets and frees up.
    var notifyOnReset: Bool = true
}

/// Where the collapsed rail sits.
///
/// The rail is draggable and snaps to whichever screen edge it was dropped
/// nearest, so this is user state rather than a constant. `offset` is how far
/// along that edge it landed, as a fraction of the travel available (0 = top or
/// leading, 1 = bottom or trailing) — a fraction and not points, so the same
/// placement means the same thing after a resolution change or on a second
/// display.
struct RailPlacement: Codable, Equatable {
    enum Edge: String, Codable, CaseIterable {
        case left, right, top, bottom

        /// Whether the rail *runs* vertically — true for the screen's side edges,
        /// where mascots stack in a column; false along the top and bottom, where
        /// they sit in a row.
        var isVertical: Bool { self == .left || self == .right }
    }

    var edge: Edge = .right
    var offset: Double = 0
}

struct AppConfig: Codable {
    var sessionHours: Double
    var refreshSeconds: Double
    var providers: [ProviderConfig]
    /// Optional so configs written before alerts existed still decode (a missing
    /// key would otherwise throw and wipe the user's providers back to default).
    var notifications: NotificationSettings?
    /// Optional so older configs decode; falls back to `.standard` when absent.
    var defaultMascot: DefaultMascot?
    /// Which provider the menu bar gauge reports on. nil (and an id that no longer
    /// matches a provider) means whichever is closest to a limit — the app's
    /// original always-busiest behaviour, kept as the default because it's the one
    /// pick that can't go stale.
    var menuBarProviderId: String? = nil
    /// Where the collapsed rail was last dropped. Optional so configs written
    /// before the rail was draggable still decode.
    var rail: RailPlacement? = nil

    /// Always-present view of the alert settings, defaulting when absent.
    var notificationSettings: NotificationSettings {
        get { notifications ?? NotificationSettings() }
        set { notifications = newValue }
    }

    /// Always-present view of the rail's placement, defaulting to the right edge
    /// under the menu bar — where it lived before it could be moved.
    var railPlacement: RailPlacement {
        get { rail ?? RailPlacement() }
        set { rail = newValue }
    }

    /// Always-present view of the menu bar mascot, defaulting when absent.
    var defaultMascotConfig: DefaultMascot {
        get { defaultMascot ?? .standard }
        set { defaultMascot = newValue }
    }

    /// Every coding CLI Merlyn can set up out of the box, paired with the on-disk
    /// markers that prove the CLI is actually configured. Markers are specific
    /// files (not just the dir), so a dir that merely holds a symlinked
    /// `skills/` folder isn't mistaken for a real install. Drives both the
    /// static default and first-run auto-detection.
    static let knownProviders: [(config: ProviderConfig, markers: [String])] = [
        (ProviderConfig(id: "claude-personal", name: "Claude", account: "Personal",
                        kind: .claude, dir: "~/.claude", style: .cat, colorSlot: 1),
         ["~/.claude/projects", "~/.claude.json"]),
        (ProviderConfig(id: "claude-work", name: "Claude", account: "Work",
                        kind: .claude, dir: "~/.claude-work", style: .catTie, colorSlot: 2),
         ["~/.claude-work/projects", "~/.claude-work.json"]),
        (ProviderConfig(id: "codex", name: "Codex", account: "OpenAI",
                        kind: .codex, dir: "~/.codex", style: .robot, colorSlot: 3),
         ["~/.codex/auth.json"]),
        (ProviderConfig(id: "kimi", name: "Kimi", account: "Moonshot",
                        kind: .kimi, dir: "~/.kimi-code", style: .round, colorSlot: 4),
         ["~/.kimi-code/credentials/kimi-code.json"]),
    ]

    /// First-run discovery: keep only providers whose marker exists on disk.
    static func autodetectedProviders() -> [ProviderConfig] {
        knownProviders
            .filter { $0.markers.contains { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) } }
            .map(\.config)
    }

    /// Static fallback used when auto-detection finds nothing, so a brand-new
    /// install isn't an empty window.
    static let `default` = AppConfig(
        sessionHours: 5,
        refreshSeconds: 60,
        providers: knownProviders.map(\.config),
        notifications: NotificationSettings(),
        defaultMascot: .standard
    )

    /// The config to write on first launch: detected providers when any CLI is
    /// found, otherwise the static default.
    static func firstRun() -> AppConfig {
        let detected = autodetectedProviders()
        guard !detected.isEmpty else { return .default }
        return AppConfig(
            sessionHours: 5, refreshSeconds: 60, providers: detected,
            notifications: NotificationSettings(), defaultMascot: .standard
        )
    }
}
