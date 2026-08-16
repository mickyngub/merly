// SettingsView.swift — the panel's settings screen: usage-alert configuration
// and launch-at-login. Reachable from the gear in the dock header. Edits write
// straight through the engine (alerts persist into providers.json; the login
// item toggles SMAppService).

import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: UsageEngine
    let onDone: () -> Void

    /// Captured once at init, not re-synced from the engine: this screen is the
    /// only writer while it's open (each change writes straight through). An
    /// external providers.json edit made while Settings is showing is clobbered
    /// by the next toggle here — accepted; the screen lives for seconds.
    @State private var settings: NotificationSettings
    @State private var launchAtLogin: Bool
    /// "" is the auto pick — Picker needs a non-optional tag, and nil in the
    /// config is what "whichever is busiest" means.
    @State private var menuBarProvider: String
    /// What macOS itself will do with an alert right now. Alerts silently going
    /// nowhere is the failure this screen exists to make visible — the app can
    /// post them perfectly and still have no banner drawn.
    @StateObject private var permission = NotificationPermissionProbe()
    @Environment(\.theme) private var theme

    private let accent = Theme.accent

    init(engine: UsageEngine, onDone: @escaping () -> Void) {
        self.engine = engine
        self.onDone = onDone
        _settings = State(initialValue: engine.appConfig.notificationSettings)
        _launchAtLogin = State(initialValue: LoginItem.isEnabled)
        _menuBarProvider = State(initialValue: engine.appConfig.menuBarProviderId ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.text2)
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer(minLength: 0)
                IconButton(systemName: "xmark", action: onDone)
            }

            section("Menu bar") {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Text("Show limits for")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(theme.text)
                        Spacer(minLength: 8)
                        Picker("", selection: $menuBarProvider) {
                            Text("Busiest provider").tag("")
                            ForEach(engine.appConfig.providers) { provider in
                                Text("\(provider.name) · \(provider.account)").tag(provider.id)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 165)
                    }
                    Text("The menu bar wears this provider's mascot, with a gauge under it for whichever limit — 5h or weekly — is closest to blocking it. Hover for the figure.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.text3)
                }
            }

            section("Alerts") {
                toggleRow(
                    "Usage alerts",
                    caption: "Notify when a provider gets close to a limit",
                    isOn: $settings.enabled
                )

                if settings.enabled {
                    Divider().overlay(theme.hairline)

                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("Alert threshold")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(theme.text)
                            Spacer()
                            Text("\(Int(settings.thresholdPct))%")
                                .font(.system(size: 12.5, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(accent)
                        }
                        Slider(value: $settings.thresholdPct, in: 50...95, step: 5)
                            .tint(accent)
                        Text("Fires once when the closest limit first crosses this.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.text3)
                    }

                    Divider().overlay(theme.hairline)

                    toggleRow(
                        "Reset alerts",
                        caption: "Notify when a busy limit rolls over and frees up",
                        isOn: $settings.notifyOnReset
                    )

                    Divider().overlay(theme.hairline)

                    deliveryRow
                }
            }

            section("General") {
                toggleRow(
                    "Launch at login",
                    caption: "Open Merly automatically when you sign in",
                    isOn: $launchAtLogin
                )
                if !LoginItem.isSupported {
                    Text("Available in the bundled app (build with scripts/bundle.sh).")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(hex: 0xB5710E))
                }
            }
        }
        .padding(14)
        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 1)
        )
        .onChange(of: settings) { _, new in engine.updateNotificationSettings(new) }
        .onChange(of: menuBarProvider) { _, id in
            engine.updateMenuBarProvider(id.isEmpty ? nil : id)
        }
        .onChange(of: launchAtLogin) { _, on in
            LoginItem.set(on)
            launchAtLogin = LoginItem.isEnabled // reflect actual result
        }
    }

    // MARK: delivery

    /// Whether macOS will actually *show* what Merly posts, and a way to prove it.
    ///
    /// Posting a notification and having one appear are separate things: macOS
    /// keys its permission record to the app's code signature, so an alert can be
    /// delivered flawlessly and still never draw a banner. Without this row the
    /// only symptom is silence, which reads identically to "nothing crossed a
    /// limit" — see docs/specs/distribution.md.
    private var deliveryRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: delivery.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(delivery.tint)
                Text(delivery.headline)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(delivery.isHealthy ? theme.text2 : delivery.tint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let detail = delivery.detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if MacNotifications.isSupported {
                HStack(spacing: 7) {
                    chipButton("Send a test", filled: delivery.isHealthy) {
                        MacNotifications.postTest()
                        // The test itself can flip the state: the very first post
                        // is what makes macOS register the app.
                        permission.refresh()
                    }
                    if !delivery.isHealthy {
                        chipButton("Open Notification Settings", filled: false) {
                            MacNotifications.openSystemSettings()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear { permission.refresh() }
    }

    /// The permission state rendered for a human: what is wrong, and what to do.
    private var delivery: (symbol: String, tint: Color, headline: String, detail: String?, isHealthy: Bool) {
        switch permission.permission {
        case .granted:
            // Deliberately unhued: the healthy state is the absence of a problem,
            // and the theme keeps colour for readings, not for reassurance.
            return ("checkmark.circle.fill", theme.text3, "macOS is showing Merly's alerts.", nil, true)
        case .unsupported:
            return ("hammer.fill", Color(hex: 0xB5710E), "Alerts need the bundled app.",
                    "Build it with scripts/bundle.sh — the dev binary has no bundle identifier, so macOS has nothing to deliver to.", false)
        case .denied:
            return ("bell.slash.fill", Theme.danger, "Notifications are turned off for Merly.",
                    "Turn them back on in System Settings › Notifications › Merly.", false)
        case .bannersOff:
            return ("bell.badge.slash.fill", Color(hex: 0xB5710E), "Merly's alert style is None.",
                    "Alerts are delivered but never drawn. Set Merly to Banners or Alerts in System Settings › Notifications.", false)
        case .notDetermined:
            return ("exclamationmark.triangle.fill", Color(hex: 0xB5710E), "macOS has no permission on record for Merly.",
                    "Alerts will be delivered silently. Send a test to trigger the prompt — if Merly still isn't listed in System Settings › Notifications, the build is ad-hoc signed and the grant can't stick (docs/specs/distribution.md).", false)
        }
    }

    // MARK: pieces

    private func chipButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: filled ? .semibold : .medium))
                .foregroundStyle(filled ? Color.white : theme.text2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(filled ? accent : theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.text3)
            content()
        }
    }

    private func toggleRow(_ title: String, caption: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.text)
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.text3)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(accent)
        }
    }
}
