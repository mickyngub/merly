// Notifier.swift — usage alerts and the launch-at-login toggle.
//
// NotificationManager watches the engine's snapshots and posts a macOS
// notification when a provider first crosses the user's threshold, or when a
// previously-busy session resets and frees up. LoginItem wraps SMAppService.
//
// Both no-op safely when the process has no bundle identifier (a raw `swift run`
// binary): UNUserNotificationCenter.current() traps without a bundle, and
// SMAppService only applies to a real .app.

import Combine
import Foundation
import ServiceManagement
import UserNotifications

/// True only when running as a packaged .app (scripts/bundle.sh). The dev binary
/// has no bundle id, so the system APIs below would trap or no-op.
private var isBundledApp: Bool { Bundle.main.bundleIdentifier != nil }

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let engine: UsageEngine
    private var cancellables = Set<AnyCancellable>()

    /// Ids currently sitting above the threshold and already alerted — cleared
    /// when they drop back under, so each fresh crossing alerts once.
    private var alertedHigh: Set<String> = []
    /// Last session % seen per provider, to spot a high→low reset.
    private var lastSessionPct: [String: Double] = [:]

    /// Suppress alerts during the first few seconds so an already-high provider
    /// at launch seeds state silently instead of firing on every app start.
    private let startedAt = Date()
    private var armed = false

    init(engine: UsageEngine) {
        self.engine = engine
        super.init()
        guard isBundledApp else { return }
        UNUserNotificationCenter.current().delegate = self
        requestAuthorization()
        engine.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshots in self?.evaluate(snapshots) }
            .store(in: &cancellables)
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error { NSLog("Lens notifications: \(error.localizedDescription)") }
            }
    }

    private func evaluate(_ snapshots: [ProviderSnapshot]) {
        let settings = engine.appConfig.notificationSettings
        if !armed, Date().timeIntervalSince(startedAt) > 6 { armed = true }

        for snap in snapshots {
            let id = snap.id
            let pressure = snap.pressurePct
            let session = snap.sessionPct
            let prevSession = lastSessionPct[id]

            // Threshold crossing (re-arms once it dips back below).
            if settings.enabled {
                if pressure >= settings.thresholdPct {
                    if !alertedHigh.contains(id) {
                        alertedHigh.insert(id)
                        if armed {
                            post(
                                id: "high-\(id)",
                                title: "\(snap.config.name) · \(snap.config.account)",
                                body: "Used \(Int(pressure.rounded()))% of its closest limit."
                            )
                        }
                    }
                } else {
                    alertedHigh.remove(id)
                }

                // Reset freed: was meaningfully busy, now back near zero.
                if settings.notifyOnReset, armed,
                   let prev = prevSession, prev >= 50, session <= 10 {
                    post(
                        id: "reset-\(id)",
                        title: "\(snap.config.name) · \(snap.config.account) reset",
                        body: "Session window is fresh again — \(Int(session.rounded()))% used."
                    )
                }
            }

            lastSessionPct[id] = session
        }
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
            NSLog("Lens login item: \(error.localizedDescription)")
        }
    }
}
