// AddProviderForm.swift — inline "add provider" form that expands in place of
// the dashed AddProviderCard. Writes straight to providers.json through the
// engine, so the new card appears without leaving the app.

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
    @State private var workTie: Bool
    @Environment(\.theme) private var theme

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
        _paletteName = State(initialValue: editing?.palette ?? kind.defaultPaletteName)
        _workTie = State(initialValue: editing?.style == .catTie)
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
                    spriteName: nil
                )
                Text(editing == nil ? "New provider" : "Edit provider")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer(minLength: 0)
                IconButton(systemName: "xmark", action: onDone)
            }

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
                if paletteName == old.defaultPaletteName { paletteName = new.defaultPaletteName }
                if new != .claude { workTie = false }
            }

            HStack(spacing: 8) {
                labeledField("Name", text: $name, prompt: kind.displayName)
                labeledField("Account", text: $account, prompt: "Personal")
            }

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

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Color")
                HStack(spacing: 7) {
                    ForEach(MascotPalette.presetOrder, id: \.self) { presetName in
                        paletteSwatch(presetName)
                    }
                    Spacer(minLength: 0)
                    if kind == .claude {
                        Toggle("Tie", isOn: $workTie)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.text2)
                            .help("Work-account look: tie + work sprite")
                    }
                }
            }

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
                    Text(editing == nil ? "Add provider" : "Save changes")
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

    // MARK: pieces

    private var previewStyle: MascotStyle {
        if kind == .claude, workTie { return .catTie }
        switch kind {
        case .claude: return .cat
        case .codex: return .robot
        case .kimi: return .round
        }
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

    private func paletteSwatch(_ presetName: String) -> some View {
        let selected = presetName == paletteName
        return Button {
            paletteName = presetName
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
        !name.trimmingCharacters(in: .whitespaces).isEmpty
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
        let claudeTie = kind == .claude && workTie
        var provider = ProviderConfig(
            id: editing?.id ?? newID(name: trimmedName, account: trimmedAccount),
            name: trimmedName,
            account: trimmedAccount,
            kind: kind,
            dir: dir.trimmingCharacters(in: .whitespaces),
            style: claudeTie ? .catTie : nil,
            palette: paletteName,
            sprite: claudeTie ? "clawd-work-sprite" : nil
        )
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
