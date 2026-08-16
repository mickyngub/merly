// main.swift — Merlyn entry point. Menu-bar-only app (no Dock icon);
// `merlyn --print` runs the readers once and prints a plain-text snapshot,
// which is handy for verifying data parsing without launching the UI.

import AppKit

/// The QA launch flags, parsed once. See CONTRIBUTING.md for what each drives;
/// none of them exist for end users.
enum QAFlags {
    /// `--expand` pre-opens every provider card (visual QA without scripted clicks).
    static let expandCards = CommandLine.arguments.contains("--expand")
    /// `--edit` opens the list already in reorder/delete mode — the grips, the edit
    /// and delete buttons, and the drag are otherwise a click away from every
    /// screenshot.
    static let editMode = CommandLine.arguments.contains("--edit")
    /// `--notify-test` posts one alert at launch and logs what macOS reports back.
    /// The alert path can fail entirely outside the app (no permission record, an
    /// alert style of None), and silence looks the same as "nothing crossed a
    /// limit" — this is the one way to tell them apart without waiting for real
    /// usage. Bundled app only; the dev binary has no bundle id to deliver to.
    static let notifyTest = CommandLine.arguments.contains("--notify-test")
    /// Delay before routing an already-open panel to a QA screen: the SwiftUI
    /// host must be mounted so its `openGeneration` onChange fires. Timing-based
    /// because these are QA-only paths — a dropped route on a pathologically slow
    /// first render costs a re-run, not a user.
    static let mascotRouteDelay: TimeInterval = 0.6
    static let railRouteDelay: TimeInterval = 1.0
}

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
        enableLoginItemOnFirstLaunch()
        LoginLauncher.cleanupStaleScripts()
        if CommandLine.arguments.contains("--light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        engine.start()
        if CommandLine.arguments.contains("--mascot") {
            // Defer so the SwiftUI host is mounted and its openGeneration
            // onChange can route to the mascot screen (same timing as --rail).
            panelController.open()
            DispatchQueue.main.asyncAfter(deadline: .now() + QAFlags.mascotRouteDelay) { [weak self] in
                self?.panelController.open(screen: .mascot)
            }
        } else if CommandLine.arguments.contains("--open") {
            panelController.open()
        }
        if CommandLine.arguments.contains("--rail") {
            panelController.open()
            DispatchQueue.main.asyncAfter(deadline: .now() + QAFlags.railRouteDelay) { [weak self] in
                self?.panelController.collapseToRail()
            }
        }
        if QAFlags.notifyTest { runNotificationSelfTest() }
    }

    /// Post one alert and report what the system says about it.
    ///
    /// Drives its own authorization request rather than reading the one
    /// `NotificationManager.init` fired: the answer arrives on a callback that can
    /// take as long as the user takes to dismiss a prompt, and a request still in
    /// flight is indistinguishable from one that quietly succeeded. This reports
    /// the outcome whenever it lands.
    private func runNotificationSelfTest() {
        NSLog("Merlyn notify-test: supported = \(MacNotifications.isSupported)")
        MacNotifications.requestAuthorization { granted, error in
            NSLog("Merlyn notify-test: requestAuthorization → granted=\(granted) error=\(error.map { "\($0)" } ?? "none")")
            Task { @MainActor in
                MacNotifications.permission { state in
                    NSLog("Merlyn notify-test: permission = \(state)")
                    MacNotifications.postTest()
                    // Re-read after posting: the first post is what makes macOS
                    // register the app, so the state can change underneath us.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        MacNotifications.permission { after in
                            NSLog("Merlyn notify-test: permission after posting = \(after)")
                        }
                    }
                }
            }
        }
    }

    /// The first launch of the bundled app registers the login item so Merlyn
    /// opens at sign-in without the user hunting for the toggle. Guarded by a
    /// one-shot flag: if the user later turns it off in Settings, we never
    /// re-force it. No-ops for the unbundled dev binary (`isSupported == false`),
    /// so the flag is only ever set once the real .app has run.
    private func enableLoginItemOnFirstLaunch() {
        guard LoginItem.isSupported else { return }
        let key = "didAutoEnableLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        LoginItem.set(true)
        UserDefaults.standard.set(true, forKey: key)
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
    print("Merlyn — \(app.providers.count) providers\n")
    for provider in app.providers {
        let snap = reader(for: provider.kind).read(config: provider, app: app, ctx: &ctx, now: now)
        let reset = snap.sessionResetAt.map {
            UsageFormatting.duration(until: $0, now: now)
        } ?? "—"
        let kindNote = snap.failure.map { "no data — \($0.headline.lowercased())" }
            ?? (snap.isStale ? "reported (stale)" : snap.isEstimated ? "estimated" : "reported")
        let shinyMark = provider.isShiny ? " ✨shiny" : ""
        let planMark = snap.plan.map { " — \($0)" } ?? ""
        let creditMark = snap.resetCredits.map {
            " — \($0.available) reset\($0.available == 1 ? "" : "s")"
                + ($0.isUsableNow ? " (\($0.applicable) usable now)" : " (none applicable)")
        } ?? ""
        print("● \(provider.name) · \(provider.account)\(planMark)\(shinyMark)\(creditMark)  (\(provider.dir))")
        print("   session: \(Int(snap.sessionPct.rounded()))% used [\(snap.mood.tagWord)] · resets in \(reset) · \(kindNote)\(snap.isActive ? " · ACTIVE" : "")")
        for metric in snap.weekly {
            print("   \(metric.label): \(Int(metric.pct.rounded()))% used · \(metric.resetText)")
        }
        // Ring lanes outermost-first, and the menu bar's gauge lanes — both derived,
        // so printing them is how they're checked without a screenshot. The lane
        // *count* matters as much as the figures: a provider with one limit must
        // print one bar, never a padded pair.
        let lanes = snap.ringWindows(maxLanes: 3)
            .map { "\($0.label) \(Int($0.pct.rounded()))%" }
            .joined(separator: " → ")
        if !lanes.isEmpty { print("   ring (rim → centre): \(lanes)") }
        let bars = snap.iconGauges
            .map { "\($0.estimated ? "≈" : "")\($0.window) \(Int($0.pct.rounded()))%" }
            .joined(separator: " / ")
        if !bars.isEmpty { print("   menu bar (top → bottom): \(bars)") }
        if let g = snap.game {
            let mb = Double(g.lifetimeBytes) / 1_048_576
            print("   game: Lv \(g.level) (\(Int((g.xpInLevel * 100).rounded()))% to next) · form \(g.form) · 🔥\(g.streakDays) · \(String(format: "%.0f", mb)) MB lifetime")
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
