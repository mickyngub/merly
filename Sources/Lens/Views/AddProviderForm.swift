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
    @State private var paletteName: String
    /// Tracks a manual color pick so auto-suggestion stops overriding it when the kind changes.
    @State private var paletteEdited: Bool
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
        // Adding a provider defaults to a color no existing provider uses, so a
        // second account of the same kind (e.g. Claude Personal + Work) is
        // visually distinct out of the box. Editing keeps the saved color.
        _paletteName = State(initialValue:
            editing?.palette ?? Self.suggestedPalette(kind: kind, existing: engine.appConfig.providers))
        _paletteEdited = State(initialValue: editing != nil)
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
                    palette: MascotPalette.preset(paletteName),
                    mood: .happy,
                    px: 36,
                    bob: false,
                    hopsOnHover: false,
                    spriteName: previewSprite
                )
                Text(isEditing ? "Edit provider" : "New provider")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.text)
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
                    if !paletteEdited {
                        paletteName = Self.suggestedPalette(kind: new, existing: engine.appConfig.providers)
                    }
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
                            canSave ? MascotPalette.preset(paletteName).accent : theme.track,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
        }
        .padding(12)
        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 1)
        )
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
                ForEach(MascotPalette.presetOrder, id: \.self) { presetName in
                    paletteSwatch(presetName)
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
        if isEditing { return style }
        switch kind {
        case .claude: return .cat
        case .codex: return .robot
        case .kimi: return .round
        }
    }

    /// The header preview mirrors the chosen sprite while editing; adding previews
    /// the kind's default sprite, tinted by the chosen color (what a new provider gets).
    private var previewSprite: String? {
        if isEditing { return sprite.isEmpty ? nil : sprite }
        return kind.spriteFamily.first?.id
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
        let selected = sprite == id
        let palette = MascotPalette.preset(paletteName)
        return VStack(spacing: 3) {
            Button { sprite = id } label: {
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

    /// A color no existing provider already uses, so a new provider is distinct
    /// by default. Prefers the kind's signature color when it's still free.
    private static func suggestedPalette(kind: ProviderKind, existing: [ProviderConfig]) -> String {
        let used = Set(existing.map { $0.palette ?? $0.kind.defaultPaletteName })
        if !used.contains(kind.defaultPaletteName) { return kind.defaultPaletteName }
        return MascotPalette.presetOrder.first { !used.contains($0) } ?? kind.defaultPaletteName
    }

    private func paletteSwatch(_ presetName: String) -> some View {
        let selected = presetName == paletteName
        return Button {
            paletteName = presetName
            paletteEdited = true
        } label: {
            Circle()
                .fill(MascotPalette.preset(presetName).accent)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle().strokeBorder(
                        selected ? theme.text : .clear,
                        lineWidth: 1.5
                    )
                    .padding(-2.5)
                )
        }
        .buttonStyle(.plain)
        .help(presetName)
    }

    // MARK: actions

    private var dirExists: Bool {
        var isDir: ObjCBool = false
        let path = (dir as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

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
                palette: paletteName,
                sprite: sprite
            )
        } else {
            // New providers use their kind's default sprite (nil → resolved),
            // tinted by the chosen color.
            provider = ProviderConfig(
                id: newID(name: trimmedName, account: trimmedAccount),
                name: trimmedName,
                account: trimmedAccount,
                kind: kind,
                dir: dir.trimmingCharacters(in: .whitespaces),
                style: nil,
                palette: paletteName,
                sprite: nil
            )
        }
        // Preserve any manual token-limit overrides set outside the form.
        provider.sessionTokenLimit = editing?.sessionTokenLimit
        provider.weeklyTokenLimit = editing?.weeklyTokenLimit
        if editing == nil {
            engine.addProvider(provider)
        } else {
            engine.updateProvider(provider)
        }
        onDone()
    }

    /// Slug from name+account, de-duped against existing ids with a numeric suffix.
    private func newID(name: String, account: String) -> String {
        let existing = Set(ConfigStore.load().providers.map(\.id))
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
