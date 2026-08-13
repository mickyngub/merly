// Persistence.swift — where Merlyn's state lives on disk (Application
// Support/Merlyn) and the stores that read/write it. All writes are atomic so
// a crash mid-write can never leave a truncated file, and every failure is
// logged: a silently-lost user edit is worse than a noisy one.

import Foundation

enum AppPaths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Merlyn", isDirectory: true)
    }
    static var configFile: URL { supportDir.appendingPathComponent("providers.json") }
    static var cacheFile: URL { supportDir.appendingPathComponent("usage-cache.json") }
}

/// Writes `data` to `url` atomically, creating its folder on demand.
/// Returns false (and logs) on failure so callers can react; most can't do
/// better than the log, but the config store surfaces it.
@discardableResult
func persist(_ data: Data, to url: URL, what: String) -> Bool {
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
    } catch {
        NSLog("Merlyn: failed to save \(what): \(error.localizedDescription)")
        return false
    }
}

enum ConfigStore {
    /// `url` is parameterized for tests only; the app always uses the default.
    static func load(from url: URL = AppPaths.configFile) -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Genuinely no config yet — write the first-run default.
            let config = AppConfig.firstRun()
            save(config, to: url)
            return config
        }
        do {
            let data = try Data(contentsOf: url)
            var config = try JSONDecoder().decode(AppConfig.self, from: data)
            if migrate(&config) { save(config, to: url) }
            return config
        } catch {
            // The file exists but can't be read or decoded — most likely a typo in
            // a hand edit (providers.json is documented as user-editable). Never
            // overwrite it with defaults: move it aside so the user's providers,
            // mascot slots, and limit overrides survive to be fixed, and run on
            // the default config in the meantime.
            NSLog("Merlyn: providers.json is unreadable (\(error.localizedDescription))")
            quarantine(url)
            return AppConfig.firstRun()
        }
    }

    /// Moves a broken providers.json aside as `providers.json.broken-<timestamp>`
    /// so the next save can't clobber the user's hand-edited content. If even the
    /// move fails, leaves the file untouched — `save` writes are atomic, so the
    /// worst case is running on defaults until the file is fixed.
    private static func quarantine(_ url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = url.appendingPathExtension("broken-\(stamp)")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            NSLog("Merlyn: moved the broken config to \(target.lastPathComponent) — fix and rename it back to recover")
        } catch {
            NSLog("Merlyn: could not quarantine the broken config: \(error.localizedDescription)")
        }
    }

    /// Normalize retired identifiers so old configs keep resolving. The "Work"
    /// Claude sprite was a recolored Clawd; now that any sprite follows the
    /// palette, it collapses to "clawd-sprite" (its steel palette still tints it
    /// blue). Returns true when something changed, so the caller can persist.
    private static func migrate(_ config: inout AppConfig) -> Bool {
        var changed = false
        for i in config.providers.indices where config.providers[i].sprite == "clawd-work-sprite" {
            config.providers[i].sprite = "clawd-sprite"
            changed = true
        }
        if config.defaultMascot?.sprite == "clawd-work-sprite" {
            config.defaultMascot?.sprite = "clawd-sprite"
            changed = true
        }
        // Assign each mascot a default deck slot by position the first time we see
        // a config without one (menu bar = 0; providers spread 1..N). The slot is
        // editable afterward; the deck's hues stay fated. See `Fate`.
        for i in config.providers.indices where config.providers[i].colorSlot == nil {
            config.providers[i].colorSlot = (i + 1) % Fate.deckSize
            changed = true
        }
        if config.defaultMascot != nil, config.defaultMascot?.colorSlot == nil {
            config.defaultMascot?.colorSlot = 0
            changed = true
        }
        return changed
    }

    /// Persists the config. Returns false (already logged) when the write fails,
    /// so UI callers can tell the user their edit didn't stick.
    @discardableResult
    static func save(_ config: AppConfig, to url: URL = AppPaths.configFile) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(config)
            return persist(data, to: url, what: "providers.json")
        } catch {
            NSLog("Merlyn: failed to encode providers.json: \(error.localizedDescription)")
            return false
        }
    }
}

enum LastGoodStore {
    static var file: URL { AppPaths.supportDir.appendingPathComponent("last-good.json") }

    static func load() -> [String: RealReading] {
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONDecoder().decode([String: RealReading].self, from: data)
        else { return [:] }
        return dict
    }

    static func save(_ dict: [String: RealReading]) {
        do {
            let data = try JSONEncoder().encode(dict)
            persist(data, to: file, what: "last-good.json")
        } catch {
            NSLog("Merlyn: failed to encode last-good.json: \(error.localizedDescription)")
        }
    }
}
