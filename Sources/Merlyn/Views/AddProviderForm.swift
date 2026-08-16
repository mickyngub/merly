// AddProviderForm.swift — inline form that expands in place of the dashed
// AddProviderCard (adding) or a provider card (editing). Writes straight to
// providers.json through the engine, so the card appears/updates without
// leaving the app.
//
// Add and edit deliberately show different fields. Adding is "pick a kind, point
// at a config folder": kind tabs + folder picker. Editing an existing provider
// can't change its kind or folder (those define what it tracks), so it drops
// both and instead exposes the full mascot picker — sprite art + drawn style,
// next to color — the same controls the menu bar mascot editor uses.

import AppKit
import SwiftUI

struct AddProviderForm: View {
    @ObservedObject var engine: UsageEngine
    /// When set, the form edits this provider in place instead of adding a new one.
    let editing: ProviderConfig?
    /// Called on cancel and after a successful add/save.
    let onDone: () -> Void

    @State private var kind: ProviderKind
    @State private var name: String
    @State private var account: String
    @State private var dir: String
    @State private var dirEdited: Bool
    /// Whether `dir` exists on disk, refreshed by onChange — a cached flag rather
    /// than a live computed property so the view never stats the filesystem per
    /// render (repo rule: file I/O stays out of views; the engine does the check).
    @State private var dirExists = false
    @State private var colorSlot: Int
    /// Resolved sprite selection for the edit-mode mascot picker; "" is the drawn critter.
    @State private var sprite: String
    /// Drawn-critter style for the edit-mode mascot picker (ignored while a sprite is chosen).
    @State private var style: MascotStyle
    @Environment(\.theme) private var theme

    private var isEditing: Bool { editing != nil }

    init(engine: UsageEngine, editing: ProviderConfig? = nil, onDone: @escaping () -> Void) {
        self.engine = engine
        self.editing = editing
        self.onDone = onDone
        let kind = editing?.kind ?? .claude
        _kind = State(initialValue: kind)
        _name = State(initialValue: editing?.name ?? kind.displayName)
        _account = State(initialValue: editing?.account ?? "")
        _dir = State(initialValue: editing?.dir ?? kind.defaultDir)
        _dirEdited = State(initialValue: editing != nil)
        // Adding a provider defaults to the next deck slot (append position), so a
        // second account of the same kind (e.g. Claude Personal + Work) is
        // visually distinct out of the box. Editing keeps the provider's slot.
        _colorSlot = State(initialValue:
            editing?.resolvedColorSlot ?? ((engine.appConfig.providers.count + 1) % Fate.deckSize))
        _style = State(initialValue: editing?.resolvedStyle ?? .cat)
        // Mirror the menu bar editor: an explicit "" means drawn, nil falls back
        // to the kind's default art, any other value is a chosen sprite sheet.
        _sprite = State(initialValue: editing.map { $0.sprite ?? $0.resolvedSprite ?? "" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                MascotView(
                    style: previewStyle,
                    palette: previewPalette,
                    mood: .happy,
                    px: 36,
                    bob: false,
                    hopsOnHover: false,
                    spriteName: previewSprite
                )
                Text(isEditing ? "Edit provider" : "New provider")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                if editing?.isShiny == true {
                    Label("Shiny", systemImage: "sparkles")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color(hex: 0xB8860B))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: 0xFFD23D, alpha: 0.18), in: Capsule())
                        .help("This mascot caught a rare shiny color.")
                }
                Spacer(minLength: 0)
                IconButton(systemName: "xmark", action: onDone)
            }

            if !isEditing {
                Picker("Kind", selection: $kind) {
                    ForEach(ProviderKind.allCases, id: \.self) { kind in
                        Text(kind.displayName)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: kind) { old, new in
                    if name == old.displayName || name.isEmpty { name = new.displayName }
                    if !dirEdited { dir = new.defaultDir }
                }
            }

            HStack(spacing: 8) {
                labeledField("Name", text: $name, prompt: kind.displayName)
                labeledField("Account", text: $account, prompt: "Personal")
            }

            if isEditing {
                mascotSection
            } else {
                configFolderSection
            }

            colorSection

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: onDone) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.text2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.chip, in: Capsule())
                }
                .buttonStyle(.plain)
                Button(action: save) {
                    Text(isEditing ? "Save changes" : "Add provider")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            canSave ? previewPalette.accent : theme.track,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 1)
        )
        // Opts back in to the focus rings PanelRootView switches off for the rest
        // of the panel — this is the one screen with text fields, where the ring
        // is the only indication of where typing will land.
        .focusEffectDisabled(false)
        .onChange(of: dir, initial: true) { _, newDir in
            dirExists = engine.directoryExists(newDir)
        }
    }

    // MARK: sections

    /// Sprite art + drawn style, scoped to the provider's own kind so a Claude
    /// provider can't be dressed as Codex/Kimi. Edit-mode only.
    private var mascotSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            fieldLabel("Mascot")
            HStack(spacing: 7) {
                ForEach(spriteSheets, id: \.id) { sheet in
                    spriteThumb(sheet.id, label: sheet.label)
                }
                Spacer(minLength: 0)
            }
            if sprite.isEmpty {
                Picker("Style", selection: $style) {
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

    private var configFolderSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("Config folder")
            HStack(spacing: 6) {
                textField($dir.onUserEdit { dirEdited = true }, prompt: kind.defaultDir)
                Button(action: pickFolder) {
                    Image(systemName: "folder")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.text2)
                        .frame(width: 28, height: 26)
                        .background(theme.chip, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Choose the CLI's config folder")
            }
            if dirInUse {
                Text("That folder is already tracked by another provider")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(hex: 0xD9544E))
            } else if !dir.isEmpty, !dirExists {
                Text("Folder not found — pick a valid config folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(hex: 0xD9544E))
            }
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("Color")
            HStack(spacing: 7) {
                ForEach(0 ..< Fate.deckSize, id: \.self) { slot in
                    paletteSwatch(slot)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: pieces

    /// A "Drawn" opt-out (`""`) plus this provider kind's own sprite sheets.
    private var spriteSheets: [(id: String, label: String)] {
        [("", "Drawn")] + kind.spriteFamily
    }

    private var previewStyle: MascotStyle {
        isEditing ? style : kind.defaultStyle
    }

    /// The header preview mirrors the chosen sprite while editing; adding previews
    /// the kind's default sprite, tinted by the chosen color (what a new provider gets).
    private var previewSprite: String? {
        if isEditing { return sprite.isEmpty ? nil : sprite }
        return kind.spriteFamily.first?.id
    }

    /// The mascot preview's palette: the picked deck hue, gleaming if the provider
    /// being edited is a fated shiny.
    private var previewPalette: MascotPalette {
        Fate.palette(slot: colorSlot, shiny: editing?.isShiny ?? false)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(theme.text3)
    }

    private func labeledField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(title)
            textField(text, prompt: prompt)
        }
    }

    private func textField(_ text: Binding<String>, prompt: String) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(theme.text3))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(theme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .background(theme.chip, in: RoundedRectangle(cornerRadius: 7))
    }

    private func spriteThumb(_ id: String, label: String) -> some View {
        SpriteThumbButton(
            id: id, label: label, selected: sprite == id,
            palette: previewPalette, drawnStyle: style
        ) { sprite = id }
    }

    private func paletteSwatch(_ slot: Int) -> some View {
        PaletteSwatchButton(slot: slot, selected: slot == colorSlot) { colorSlot = slot }
    }

    // MARK: actions

    private var dirInUse: Bool {
        let trimmed = dir.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && engine.isDirInUse(trimmed, excluding: editing?.id)
    }

    private var canSave: Bool {
        let nameOK = !name.trimmingCharacters(in: .whitespaces).isEmpty
        // Editing keeps the original kind/folder, so only the name must be valid.
        guard !isEditing else { return nameOK }
        return nameOK
            && !dir.trimmingCharacters(in: .whitespaces).isEmpty
            && !dirInUse
            && dirExists
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true // CLI config dirs are dotfolders
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Use Folder"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        dir = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        dirEdited = true
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedAccount = account.trimmingCharacters(in: .whitespaces)
        var provider: ProviderConfig
        if let editing {
            // Kind and folder are fixed once a provider exists; the mascot picker
            // owns style/sprite directly here.
            provider = ProviderConfig(
                id: editing.id,
                name: trimmedName,
                account: trimmedAccount,
                kind: editing.kind,
                dir: editing.dir,
                style: style,
                colorSlot: colorSlot,
                sprite: sprite
            )
        } else {
            // New providers use their kind's default sprite (nil → resolved),
            // tinted by the chosen deck color.
            provider = ProviderConfig(
                id: engine.uniqueProviderID(name: trimmedName, account: trimmedAccount, kind: kind),
                name: trimmedName,
                account: trimmedAccount,
                kind: kind,
                dir: dir.trimmingCharacters(in: .whitespaces),
                style: nil,
                colorSlot: colorSlot,
                sprite: nil
            )
        }
        // Preserve manual token-limit overrides the form doesn't expose (rebuilding
        // from fields would reset them). Color/shiny are fated, not stored.
        provider.sessionTokenLimit = editing?.sessionTokenLimit
        provider.weeklyTokenLimit = editing?.weeklyTokenLimit
        if editing == nil {
            engine.addProvider(provider)
        } else {
            engine.updateProvider(provider)
        }
        onDone()
    }
}

private extension Binding<String> {
    /// Marks user-initiated edits without firing on programmatic assignment.
    func onUserEdit(_ action: @escaping () -> Void) -> Binding<String> {
        Binding(
            get: { wrappedValue },
            set: { newValue in
                if newValue != wrappedValue { action() }
                wrappedValue = newValue
            }
        )
    }
}
