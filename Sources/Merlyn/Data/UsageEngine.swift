// UsageEngine.swift — owns provider config, runs readers off the main thread,
// publishes snapshots to the UI and status item.

import Foundation
import Combine

@MainActor
final class UsageEngine: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    private(set) var appConfig: AppConfig
    private var timer: Timer?
    /// The cadence the live timer was armed with, so a providers.json edit to
    /// refreshSeconds takes effect on the next refresh instead of after a restart.
    private var timerInterval: TimeInterval = 0
    private var cooldowns: [String: Date] = [:]
    /// Set when refresh() is called mid-pass, so config edits (e.g. a provider
    /// just added) aren't lost to the in-flight pass's stale config.
    private var pendingRefresh = false
    /// Whether the queued mid-pass refresh was user-initiated, so a forced click
    /// during an in-flight pass isn't downgraded to a background poll.
    private var pendingForce = false
    private let workQueue = DispatchQueue(label: "sh.micky.merlyn.engine", qos: .utility)

    init() {
        appConfig = ConfigStore.load()
        snapshots = appConfig.providers.map { .empty($0) }
    }

    func start() {
        refresh()
        scheduleTimer()
    }

    /// (Re)arms the poll timer at the configured cadence, flooring it so a typo'd
    /// refreshSeconds can't hammer the APIs.
    private func scheduleTimer() {
        timer?.invalidate()
        timerInterval = max(appConfig.refreshSeconds, 15)
        timer = Timer.scheduledTimer(withTimeInterval: timerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    /// `force` (a user-initiated refresh) makes readers bypass the per-provider
    /// 429 cooldown and re-attempt the live fetch. The background timer never
    /// forces, so an endpoint that's rate-limiting us still gets backed off.
    func refresh(force: Bool = false) {
        guard !isRefreshing else {
            pendingRefresh = true
            pendingForce = pendingForce || force
            return
        }
        isRefreshing = true
        // Pick up config edits (e.g. a provider added via providers.json).
        appConfig = ConfigStore.load()
        // …including a changed poll cadence, which the armed timer captured.
        if timer != nil, max(appConfig.refreshSeconds, 15) != timerInterval {
            scheduleTimer()
        }
        let config = appConfig
        let cooldownsIn = cooldowns

        workQueue.async {
            var ctx = ReaderContext(
                fileCache: FileBucketCache.load(),
                lastGood: LastGoodStore.load(),
                cooldownUntil: cooldownsIn,
                force: force
            )
            let now = Date()
            let results = config.providers.map { provider in
                reader(for: provider.kind).read(config: provider, app: config, ctx: &ctx, now: now)
            }
            ctx.fileCache.save()
            LastGoodStore.save(ctx.lastGood)
            let cooldownsOut = ctx.cooldownUntil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cooldowns = cooldownsOut
                self.snapshots = self.inConfigOrder(results)
                self.lastRefresh = Date()
                self.isRefreshing = false
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    let queuedForce = self.pendingForce
                    self.pendingForce = false
                    self.refresh(force: queuedForce)
                }
            }
        }
    }

    /// Lays a finished pass out in the config's *current* order.
    ///
    /// A pass carries the provider list it started with, and the user can reorder
    /// or delete during the seconds it runs — dropping the results in verbatim
    /// replayed that stale list, so a card dragged to a new slot sprang back to its
    /// old one the moment the pass landed. Anything the config lists but the pass
    /// never read (a provider added mid-pass) keeps the snapshot it already has,
    /// rather than blinking out until the queued refresh catches up.
    private func inConfigOrder(_ results: [ProviderSnapshot]) -> [ProviderSnapshot] {
        let fresh = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return appConfig.providers.compactMap { fresh[$0.id] ?? current[$0.id] }
    }

    /// Append a provider to providers.json and kick a refresh. An empty snapshot
    /// shows the card immediately; the refresh pass fills in real numbers.
    /// Mutates the in-memory config like every other mutator — refresh() reloads
    /// from disk anyway, so re-reading here could only resurrect stale disk state.
    func addProvider(_ provider: ProviderConfig) {
        var config = appConfig
        config.providers.append(provider)
        ConfigStore.save(config)
        appConfig = config
        snapshots.append(.empty(provider))
        refresh()
    }

    /// Replace a provider's config in place (same id), keeping its list position.
    /// Refreshes since the folder/kind may now point at different data.
    func updateProvider(_ provider: ProviderConfig) {
        var config = appConfig
        guard let idx = config.providers.firstIndex(where: { $0.id == provider.id }) else { return }
        config.providers[idx] = provider
        ConfigStore.save(config)
        appConfig = config
        if let sIdx = snapshots.firstIndex(where: { $0.id == provider.id }) {
            snapshots[sIdx].config = provider
        }
        refresh()
    }

    /// Drop a provider from providers.json and the live list. No refresh needed —
    /// the remaining snapshots are still current.
    func removeProvider(_ id: String) {
        var config = appConfig
        config.providers.removeAll { $0.id == id }
        apply(config)
    }

    /// Move the provider `id` to where `targetId` currently sits. Called live as a
    /// dragged card passes over another, so the reorder animates under the cursor.
    func moveProvider(_ id: String, toIndexOf targetId: String) {
        var config = appConfig
        guard let from = config.providers.firstIndex(where: { $0.id == id }),
              let to = config.providers.firstIndex(where: { $0.id == targetId }),
              from != to else { return }
        config.providers.move(fromOffsets: IndexSet(integer: from),
                              toOffset: to > from ? to + 1 : to)
        apply(config)
    }

    /// True when a config folder is already claimed by an existing provider.
    /// Drives the add-form's duplicate guard (folders are the unique key).
    /// `excluding` skips one provider id so the edit form doesn't flag itself.
    func isDirInUse(_ dir: String, excluding id: String? = nil) -> Bool {
        let norm = Self.normalizedDir(dir)
        return appConfig.providers.contains { $0.id != id && Self.normalizedDir($0.dir) == norm }
    }

    /// Whether `dir` points at an existing folder. On the engine so views never
    /// touch the filesystem directly (repo rule); a single stat, called from the
    /// add form's onChange rather than per render.
    nonisolated func directoryExists(_ dir: String) -> Bool {
        var isDir: ObjCBool = false
        let path = (dir as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Slug from name+account (falling back to the kind), de-duped against the
    /// live provider ids with a numeric suffix — "Claude Work " → "claude-work".
    func uniqueProviderID(name: String, account: String, kind: ProviderKind) -> String {
        let existing = Set(appConfig.providers.map(\.id))
        var base = "\(name) \(account)".slugified
        if base.isEmpty { base = kind.rawValue }
        var id = base
        var n = 2
        while existing.contains(id) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    /// Persist tweaked alert settings. Lives in AppConfig so the next refresh
    /// (which reloads from disk) keeps them.
    func updateNotificationSettings(_ settings: NotificationSettings) {
        var config = appConfig
        config.notificationSettings = settings
        ConfigStore.save(config)
        appConfig = config
    }

    /// Persist where the rail was dropped. No republish: the panel controller
    /// owns the rail's geometry and has already moved it — this only makes the
    /// placement survive a restart.
    func updateRailPlacement(_ placement: RailPlacement) {
        guard placement != appConfig.railPlacement else { return }
        var config = appConfig
        config.railPlacement = placement
        ConfigStore.save(config)
        appConfig = config
    }

    /// Persist the menu bar's default mascot. Republishes so the status item
    /// (which observes `$snapshots`) re-renders the new look immediately.
    func updateDefaultMascot(_ mascot: DefaultMascot) {
        var config = appConfig
        config.defaultMascotConfig = mascot
        ConfigStore.save(config)
        appConfig = config
        republish()
    }

    /// Tilde-expanded, trailing-slash-stripped path for stable folder comparison.
    static func normalizedDir(_ dir: String) -> String {
        let expanded = (dir as NSString).expandingTildeInPath
        return expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
    }

    /// Persist a new provider set and re-derive snapshots in the new order,
    /// reusing the live readings keyed by id so removed/reordered cards don't
    /// flash empty.
    private func apply(_ config: AppConfig) {
        ConfigStore.save(config)
        appConfig = config
        let byId = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        snapshots = config.providers.compactMap { byId[$0.id] }
    }

    /// The provider the menu bar reports on: the pinned one while it still exists,
    /// otherwise whichever is closest to a limit. Falling back rather than showing
    /// nothing matters — a pinned id survives in providers.json after the provider
    /// is deleted, and an empty menu bar would look like the app had died.
    var menuBarSnapshot: ProviderSnapshot? {
        if let id = appConfig.menuBarProviderId,
           let pinned = snapshots.first(where: { $0.id == id }) {
            return pinned
        }
        return snapshots.max { $0.pressurePct < $1.pressurePct }
    }

    /// Pin (or unpin, with nil) the provider the menu bar gauge reports.
    /// Republishes so the status item re-renders immediately instead of at the
    /// next refresh tick.
    func updateMenuBarProvider(_ id: String?) {
        var config = appConfig
        config.menuBarProviderId = id
        ConfigStore.save(config)
        appConfig = config
        republish()
    }

    /// Re-emits `snapshots` unchanged. Observers of the `$snapshots` publisher
    /// (the status item, the rail) re-render on it — needed when what changed
    /// lives *outside* the snapshot values, like the default mascot or the menu
    /// bar pin. The self-assignment is the re-emit; it is not a typo.
    private func republish() {
        snapshots = snapshots
    }

    var updatedText: String {
        guard let lastRefresh else { return "loading…" }
        let s = Int(Date().timeIntervalSince(lastRefresh))
        if s < 10 { return "updated just now" }
        if s < 90 { return "updated \(s)s ago" }
        return "updated \(s / 60)m ago"
    }
}

private extension String {
    /// "Claude Work " → "claude-work"; anything non-alphanumeric becomes a dash.
    var slugified: String {
        lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
    }
}
