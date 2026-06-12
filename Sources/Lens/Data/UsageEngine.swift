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
    private var cooldowns: [String: Date] = [:]
    private let workQueue = DispatchQueue(label: "sh.micky.usagedock.engine", qos: .utility)

    init() {
        appConfig = ConfigStore.load()
        snapshots = appConfig.providers.map { .empty($0) }
    }

    func start() {
        refresh()
        let interval = max(appConfig.refreshSeconds, 15)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        // Pick up config edits (e.g. a provider added via providers.json).
        appConfig = ConfigStore.load()
        let config = appConfig
        let cooldownsIn = cooldowns

        workQueue.async {
            var ctx = ReaderContext(
                fileCache: FileBucketCache.load(),
                lastGood: LastGoodStore.load(),
                cooldownUntil: cooldownsIn
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
                self.snapshots = results
                self.lastRefresh = Date()
                self.isRefreshing = false
            }
        }
    }

    /// Busiest provider — drives the menu bar extra, like the prototype's peak pick.
    var peak: ProviderSnapshot? {
        snapshots.max { $0.sessionPct < $1.sessionPct }
    }

    var updatedText: String {
        guard let lastRefresh else { return "loading…" }
        let s = Int(Date().timeIntervalSince(lastRefresh))
        if s < 10 { return "updated just now" }
        if s < 90 { return "updated \(s)s ago" }
        return "updated \(s / 60)m ago"
    }
}
