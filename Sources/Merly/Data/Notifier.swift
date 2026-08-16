// Notifier.swift — usage alerts, the macOS notification plumbing behind them,
// and the launch-at-login toggle.
//
// NotificationManager watches the engine's snapshots and posts a macOS
// notification when a provider first crosses the user's threshold, and again
// when one of its limit windows rolls over and frees up. MacNotifications is the
// thin layer over UNUserNotificationCenter; LoginItem wraps SMAppService.
//
// Both no-op safely when the process has no bundle identifier (a raw `swift run`
// binary): UNUserNotificationCenter.current() traps without a bundle, and
// SMAppService only applies to a real .app.

import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications

/// True only when running as a packaged .app (scripts/bundle.sh). The dev binary
/// has no bundle id, so the system APIs below would trap or no-op.
private var isBundledApp: Bool { Bundle.main.bundleIdentifier != nil }

/// The macOS notification plumbing, kept in one place so both the alert loop and
/// the Settings screen go through the same calls.
///
/// **Delivering a notification is not the same as showing one.** Every posted
/// notification lands in Notification Center, but macOS only draws a *banner* for
/// an app it holds an authorization record for — and it keys that record to the
/// app's code-signing identity. An ad-hoc signature is a fresh identity on every
/// build, so the grant can never stick: the app never appears in System Settings →
/// Notifications and every alert arrives silently. That is why `scripts/bundle.sh`
/// signs with a stable identity; see docs/specs/distribution.md.
enum MacNotifications {
    enum Permission: Equatable {
        /// Not the packaged .app, so the system APIs are unavailable — refused is
        /// a different thing, and the UI must not conflate them.
        case unsupported
        /// Never asked, or asked and the grant didn't stick (the ad-hoc case).
        case notDetermined
        case denied
        /// Authorized, but the alert style is "None" — delivered, never bannered.
        case bannersOff
        case granted

        /// Whether an alert posted right now would actually appear on screen.
        var showsBanners: Bool { self == .granted }
    }

    /// Only the packaged .app can talk to UNUserNotificationCenter at all.
    static var isSupported: Bool { isBundledApp }

    /// Ask once.
    ///
    /// Failures are logged: a silent `granted == false` is the exact symptom of the
    /// unsigned-identity problem above, and without this line there is nothing
    /// anywhere to read it off. `then` receives every outcome, so the self-test can
    /// report the success case too — which otherwise looks identical to a callback
    /// that simply hasn't come back yet.
    static func requestAuthorization(then: (@Sendable (Bool, Error?) -> Void)? = nil) {
        guard isBundledApp else {
            then?(false, nil)
            return
        }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    NSLog("Merly notifications: authorization failed — \(error.localizedDescription)")
                } else if !granted {
                    NSLog("Merly notifications: authorization not granted. Alerts will be delivered silently — check System Settings › Notifications › Merly.")
                }
                then?(granted, error)
            }
    }

    /// Current permission, resolved off the system's own record rather than
    /// remembered from the request — the user can change it in System Settings at
    /// any time, and an app that caches the answer shows a stale one forever.
    static func permission(_ then: @escaping @Sendable @MainActor (Permission) -> Void) {
        guard isBundledApp else {
            Task { @MainActor in then(.unsupported) }
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            let alerts = settings.alertSetting
            Task { @MainActor in
                switch status {
                case .denied: then(.denied)
                case .notDetermined: then(.notDetermined)
                default: then(alerts == .disabled ? .bannersOff : .granted)
                }
            }
        }
    }

    /// Post one notification. Reusing an identifier replaces the pending copy, so
    /// a provider that re-crosses its threshold updates its alert instead of
    /// stacking a second one.
    static func post(id: String, title: String, body: String) {
        guard isBundledApp else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            // Dropped errors here are how a broken alert path stays invisible:
            // the app carries on believing it notified the user.
            if let error {
                NSLog("Merly notifications: posting \(id) failed — \(error.localizedDescription)")
            }
        }
    }

    /// The Settings screen's "Send a test" — proves the whole path end to end
    /// (authorization, banner style, Do Not Disturb) in one click, which is the
    /// only way to tell "no alerts because nothing crossed a limit" apart from
    /// "no alerts because macOS is swallowing them".
    static func postTest() {
        post(
            id: "merly-test-\(Int(Date().timeIntervalSince1970))",
            title: "Merly",
            body: "Test alert — usage notifications are getting through."
        )
    }

    /// Open System Settings straight to the Notifications pane. Merly only
    /// appears in that list once macOS has an authorization record for it, so a
    /// missing row there is itself the diagnosis.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Live permission state for the Settings screen. A tiny observable of its own so
/// the view can re-check on appear (and after a test) without the alert loop or
/// the engine having to carry UI state.
@MainActor
final class NotificationPermissionProbe: ObservableObject {
    @Published private(set) var permission: MacNotifications.Permission = .unsupported

    init() { refresh() }

    func refresh() {
        MacNotifications.permission { [weak self] state in self?.permission = state }
    }
}

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    /// A window is only worth announcing a reset for if it was at least half
    /// spent — a fresh window that was never under pressure is not news.
    private static let freedFloor: Double = 50
    /// Below this counts as "freed" for a window with no reset timestamp to go on.
    private static let freedCeiling: Double = 10
    /// How far a window's reset stamp must jump forward to count as a rollover.
    /// Well past any poll-interval drift, and far short of the shortest real
    /// window (5h), so a *rolling* window whose stamp creeps forward each pass
    /// can't be mistaken for one that rolled over.
    private static let rolloverJump: TimeInterval = 600

    /// One observed limit window, kept between passes so a rollover is detectable.
    private struct WindowReading {
        var pct: Double
        var resetAt: Date?
    }

    private let engine: UsageEngine
    private var cancellables = Set<AnyCancellable>()

    /// Ids currently sitting above the threshold and already alerted — cleared
    /// when they drop back under, so each fresh crossing alerts once.
    private var alertedHigh: Set<String> = []
    /// Last reading per provider, keyed by window label.
    private var lastWindows: [String: [String: WindowReading]] = [:]
    /// Providers whose first real reading has been seen. The first pass seeds
    /// state silently: an account already over the line when Merly launches is
    /// the state of the world, not an event, and firing on it would mean an alert
    /// every single login.
    private var seeded: Set<String> = []
    /// The refresh this manager has already judged, so one completed pass produces
    /// at most one round of alerts. `$snapshots` also fires for republishes that
    /// carry no new readings (a mascot edit, a menu bar re-pin) — those must not
    /// look like a fresh observation.
    private var lastJudgedRefresh: Date?

    init(engine: UsageEngine) {
        self.engine = engine
        super.init()
        guard MacNotifications.isSupported else { return }
        UNUserNotificationCenter.current().delegate = self
        MacNotifications.requestAuthorization()
        engine.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshots in self?.evaluate(snapshots) }
            .store(in: &cancellables)
    }

    private func evaluate(_ snapshots: [ProviderSnapshot]) {
        // Only judge a pass that carried fresh readings. Before the first refresh
        // completes the engine publishes placeholder snapshots at 0%, which would
        // otherwise seed every provider as "was idle" and fire a bogus crossing
        // the moment real numbers landed.
        guard let refresh = engine.lastRefresh, refresh != lastJudgedRefresh else { return }
        lastJudgedRefresh = refresh

        let settings = engine.appConfig.notificationSettings
        for snap in snapshots {
            // A provider with no usable reading has no story to tell: its numbers
            // are absent, not low. Keep the state it had rather than overwriting
            // it, so the reading before an outage is still there to compare
            // against when it comes back.
            //
            // Stale readings *are* judged. They are the last real API numbers,
            // just not fresh — and on a rate-limited account they are most of
            // what there is, so skipping them would mean skipping the alerts.
            // They cannot fake a rollover either: a repeated reading repeats its
            // reset stamp, and only a genuinely new window moves it.
            guard !snap.isUnavailable else { continue }

            let id = snap.id
            let current = windows(of: snap)
            defer {
                lastWindows[id] = current
                seeded.insert(id)
            }
            guard settings.enabled, seeded.contains(id) else { continue }

            crossingAlert(snap, settings: settings)
            if settings.notifyOnReset {
                resetAlert(snap, current: current, previous: lastWindows[id] ?? [:])
            }
        }
    }

    /// Every limit window this snapshot reports, keyed by label.
    ///
    /// Estimated readings contribute the session window only: their weekly bars are
    /// "vs your busiest week" ratios that climb toward 100% by construction, so a
    /// rollover in one means nothing.
    private func windows(of snap: ProviderSnapshot) -> [String: WindowReading] {
        var out = [snap.primaryWindowName: WindowReading(pct: snap.sessionPct, resetAt: snap.sessionResetAt)]
        guard !snap.isEstimated else { return out }
        for metric in snap.weekly {
            out[metric.label] = WindowReading(pct: metric.pct, resetAt: metric.resetAt)
        }
        return out
    }

    /// Threshold crossing, re-armed once pressure dips back below the line.
    private func crossingAlert(_ snap: ProviderSnapshot, settings: NotificationSettings) {
        let pressure = snap.pressurePct
        guard pressure >= settings.thresholdPct else {
            alertedHigh.remove(snap.id)
            return
        }
        guard !alertedHigh.contains(snap.id) else { return }
        alertedHigh.insert(snap.id)
        MacNotifications.post(
            id: "high-\(snap.id)",
            title: "\(snap.config.name) · \(snap.config.account)",
            body: "Used \(Int(pressure.rounded()))% of its closest limit."
        )
    }

    /// A window that rolled over and freed real room, announced once per pass per
    /// provider — every reported window, not just the session, because a weekly cap
    /// coming back is the one people actually wait on.
    private func resetAlert(
        _ snap: ProviderSnapshot,
        current: [String: WindowReading],
        previous: [String: WindowReading]
    ) {
        let freed = current
            .filter { label, now in
                guard let before = previous[label], before.pct >= Self.freedFloor else { return false }
                if let wasAt = before.resetAt, let nowAt = now.resetAt {
                    // The window's next-reset stamp jumped a whole window forward
                    // and there is room again — a rollover. Usage merely ageing out
                    // of a rolling window nudges the stamp by a poll interval at
                    // most, so it can't reach this bar.
                    return nowAt.timeIntervalSince(wasAt) >= Self.rolloverJump && now.pct < before.pct
                }
                // No stamps to compare (an estimate, or a provider that reports
                // none): fall back to the shape of a reset, a busy window that is
                // suddenly near-empty.
                return now.pct <= Self.freedCeiling
            }
            .keys
            .sorted()
        guard !freed.isEmpty else { return }

        let windowList = ListFormatter.localizedString(byJoining: freed)
        MacNotifications.post(
            id: "reset-\(snap.id)",
            title: "\(snap.config.name) · \(snap.config.account) reset",
            body: "\(windowList) limit is fresh again — \(Int(snap.pressurePct.rounded()))% of its closest limit used."
        )
    }

    /// Show banners even while the app is frontmost (it rarely is, but the
    /// add/edit form can make the panel key).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Launch-at-login via SMAppService (macOS 13+). No-ops for the unbundled dev
/// binary, where the service registration has nothing to point at.
enum LoginItem {
    /// Only the packaged .app can register a login item.
    static var isSupported: Bool { isBundledApp }

    static var isEnabled: Bool {
        isBundledApp && SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) {
        guard isBundledApp else { return }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Merly login item: \(error.localizedDescription)")
        }
    }
}
