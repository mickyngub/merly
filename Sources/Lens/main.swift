// main.swift — Usage Dock entry point. Menu-bar-only app (no Dock icon);
// `usagedock --print` runs the readers once and prints a plain-text snapshot,
// which is handy for verifying data parsing without launching the UI.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: UsageEngine!
    private var panelController: PanelController!
    private var statusItemController: StatusItemController!
    private var notificationManager: NotificationManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = UsageEngine()
        panelController = PanelController(engine: engine)
        statusItemController = StatusItemController(engine: engine, panel: panelController)
        notificationManager = NotificationManager(engine: engine)
        if CommandLine.arguments.contains("--light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        engine.start()
        if CommandLine.arguments.contains("--mascot") {
            // Defer so the SwiftUI host is mounted and its openGeneration
            // onChange can route to the mascot screen (same timing as --rail).
            panelController.open()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.panelController.open(screen: .mascot)
            }
        } else if CommandLine.arguments.contains("--open") {
            panelController.open()
        }
        if CommandLine.arguments.contains("--rail") {
            panelController.open()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.panelController.collapseToRail()
            }
        }
    }
}

func printSnapshots() {
    let app = ConfigStore.load()
    var ctx = ReaderContext(
        fileCache: FileBucketCache.load(),
        lastGood: LastGoodStore.load(),
        cooldownUntil: [:]
    )
    let now = Date()
    print("Usage Dock — \(app.providers.count) providers\n")
    for provider in app.providers {
        let snap = reader(for: provider.kind).read(config: provider, app: app, ctx: &ctx, now: now)
        let reset = snap.sessionResetAt.map {
            ProviderCardView.duration(until: $0, now: now)
        } ?? "—"
        let kindNote = snap.isStale ? "reported (stale)" : snap.isEstimated ? "estimated" : "reported"
        print("● \(provider.name) · \(provider.account)  (\(provider.dir))")
        print("   session: \(Int(snap.sessionPct.rounded()))% used [\(snap.mood.tagWord)] · resets in \(reset) · \(kindNote)\(snap.isActive ? " · ACTIVE" : "")")
        for metric in snap.weekly {
            print("   \(metric.label): \(Int(metric.pct.rounded()))% used · \(metric.resetText)")
        }
        if let note = snap.note { print("   note: \(note)") }
        print("")
    }
    ctx.fileCache.save()
    LastGoodStore.save(ctx.lastGood)
}

if CommandLine.arguments.contains("--print") {
    printSnapshots()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
