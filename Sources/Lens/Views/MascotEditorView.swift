// MascotEditorView.swift — the panel's mascot screen, reached from the topnav
// brush. Edits only the "Menu Bar" default mascot (the menu bar critter): sprite
// sheet (any family) or drawn critter, plus palette and drawn style. Per-provider
// mascots are edited inside each provider's Edit form, not here. Every change
// writes straight through the engine into providers.json.

import SwiftUI

struct MascotEditorView: View {
    @ObservedObject var engine: UsageEngine
    let onDone: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.text2)
                Text("Menu Bar Mascot")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer(minLength: 0)
                IconButton(systemName: "xmark", action: onDone)
            }

            DefaultMascotRow(engine: engine)
        }
        .padding(14)
        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 1)
        )
    }
}

/// The menu bar mascot. Not tied to a provider, so it may use any sprite family.
private struct DefaultMascotRow: View {
    @ObservedObject var engine: UsageEngine

    private var mascot: DefaultMascot { engine.appConfig.defaultMascotConfig }

    /// Drawn opt-out (`""`) plus every provider's sprites.
    private var sheets: [(id: String, label: String)] {
        [("", "Drawn")] + ProviderKind.allCases.flatMap(\.spriteFamily)
    }

    var body: some View {
        MascotControls(
            title: "Menu Bar",
            subtitle: "Default mascot",
            style: mascot.style,
            palette: mascot.resolvedPalette,
            paletteName: mascot.palette,
            sprite: mascot.sprite,
            sheets: sheets,
            setSprite: { var m = mascot; m.sprite = $0; engine.updateDefaultMascot(m) },
            setPalette: { var m = mascot; m.palette = $0; engine.updateDefaultMascot(m) },
            setStyle: { var m = mascot; m.style = $0; engine.updateDefaultMascot(m) }
        )
    }
}

/// Shared mascot controls: a live preview, sprite-sheet thumbnails, palette
/// swatches, and (for the drawn critter) a style picker. Pure presentation —
/// the owner supplies the current selection and the write-back closures.
private struct MascotControls: View {
    let title: String
    let subtitle: String?
    let style: MascotStyle
    let palette: MascotPalette
    let paletteName: String
    /// Resolved selection; "" means the drawn critter.
    let sprite: String
    let sheets: [(id: String, label: String)]
    let setSprite: (String) -> Void
    let setPalette: (String) -> Void
    let setStyle: (MascotStyle) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                MascotView(
                    style: style,
                    palette: palette,
                    mood: .happy,
                    px: 32,
                    bob: false,
                    hopsOnHover: true,
                    spriteName: sprite.isEmpty ? nil : sprite
                )
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.text)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.text3)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                ForEach(sheets, id: \.id) { sheet in
                    spriteThumb(sheet.id, label: sheet.label)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                ForEach(MascotPalette.presetOrder, id: \.self) { name in
                    paletteSwatch(name)
                }
                Spacer(minLength: 0)
            }

            if sprite.isEmpty {
                Picker("Style", selection: Binding(
                    get: { style },
                    set: { setStyle($0) }
                )) {
                    Text("Cat").tag(MascotStyle.cat)
                    Text("Tie").tag(MascotStyle.catTie)
                    Text("Robot").tag(MascotStyle.robot)
                    Text("Round").tag(MascotStyle.round)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: pieces

    private func spriteThumb(_ id: String, label: String) -> some View {
        let selected = sprite == id
        return VStack(spacing: 3) {
            Button { setSprite(id) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(theme.chip)
                    MascotView(
                        style: id.isEmpty ? style : .cat,
                        palette: palette,
                        mood: .happy,
                        px: 28,
                        bob: false,
                        hopsOnHover: false,
                        spriteName: id.isEmpty ? nil : id
                    )
                }
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? palette.accent : .clear, lineWidth: 2)
                )
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.system(size: 8.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.text2 : theme.text3)
        }
    }

    private func paletteSwatch(_ name: String) -> some View {
        let selected = name == paletteName
        return Button { setPalette(name) } label: {
            Circle()
                .fill(MascotPalette.preset(name).accent)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle().strokeBorder(selected ? theme.text : .clear, lineWidth: 1.5)
                        .padding(-2.5)
                )
        }
        .buttonStyle(.plain)
        .help(name)
    }
}
