// SettingsView.swift — the panel's settings screen: usage-alert configuration
// and launch-at-login. Reachable from the gear in the dock header. Edits write
// straight through the engine (alerts persist into providers.json; the login
// item toggles SMAppService).

import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: UsageEngine
    let onDone: () -> Void

    @State private var settings: NotificationSettings
    @State private var launchAtLogin: Bool
    @Environment(\.theme) private var theme

    private let accent = Color(hex: 0x4C8DFF)

    init(engine: UsageEngine, onDone: @escaping () -> Void) {
        self.engine = engine
        self.onDone = onDone
        _settings = State(initialValue: engine.appConfig.notificationSettings)
        _launchAtLogin = State(initialValue: LoginItem.isEnabled)
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
                        caption: "Notify when a busy session resets and frees up",
                        isOn: $settings.notifyOnReset
                    )
                }
            }

            section("General") {
                toggleRow(
                    "Launch at login",
                    caption: "Open Merlyn automatically when you sign in",
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
        .onChange(of: launchAtLogin) { _, on in
            LoginItem.set(on)
            launchAtLogin = LoginItem.isEnabled // reflect actual result
        }
    }

    // MARK: pieces

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
