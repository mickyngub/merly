// DockView.swift — the docked panel content: header, provider card list with
// staggered entrance, and the add-provider affordance. Also the collapsed rail.

import SwiftUI
import UniformTypeIdentifiers

struct DockView: View {
    @ObservedObject var engine: UsageEngine
    /// Bumped every time the panel opens, retriggering the entrance stagger.
    let openGeneration: Int
    /// Screen to show on open — `.mascot` jumps straight to the mascot editor.
    let initialScreen: PanelScreen

    @State private var refreshSpin = 0.0
    @State private var addingProvider = false
    @State private var editing = false
    @State private var showingSettings = false
    @State private var showingMascot = false
    @State private var editingProviderId: String?
    @State private var draggingId: String?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    if showingMascot {
                        MascotEditorView(engine: engine) {
                            withAnimation(Theme.snappy(0.4)) { showingMascot = false }
                        }
                        .entrance(index: 0, generation: openGeneration)
                    } else if showingSettings {
                        SettingsView(engine: engine) {
                            withAnimation(Theme.snappy(0.4)) { showingSettings = false }
                        }
                        .entrance(index: 0, generation: openGeneration)
                    } else {
                        providerList
                    }
                }
                // Leading matches the header's 16 so cards line up under the title,
                // and keeps them clear of the collapse tab on the panel's edge.
                .padding(EdgeInsets(top: 2, leading: 16, bottom: 12, trailing: 16))
                // Reset the drag state when a card is dropped in a gap (no card
                // delegate fires), so the faded card snaps back to full opacity.
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    draggingId = nil
                    return false
                }
            }
        }
        .onChange(of: openGeneration) { _, _ in
            addingProvider = false
            editing = false
            showingSettings = false
            editingProviderId = nil
            showingMascot = initialScreen == .mascot
        }
    }

    @ViewBuilder
    private var providerList: some View {
        ForEach(Array(engine.snapshots.enumerated()), id: \.element.id) { index, snapshot in
            if editingProviderId == snapshot.id {
                AddProviderForm(engine: engine, editing: snapshot.config) {
                    withAnimation(Theme.snappy(0.4)) { editingProviderId = nil }
                }
                .entrance(index: index, generation: openGeneration)
            } else {
                ProviderCardView(
                    snapshot: snapshot,
                    editing: editing,
                    onEdit: { withAnimation(Theme.snappy(0.4)) { editingProviderId = snapshot.id } },
                    onDelete: { withAnimation(Theme.snappy(0.4)) { engine.removeProvider(snapshot.id) } }
                )
                .opacity(draggingId == snapshot.id ? 0.4 : 1)
                .reorderable(active: editing, id: snapshot.id, draggingId: $draggingId) { dragged, target in
                    withAnimation(Theme.snappy(0.3)) { engine.moveProvider(dragged, toIndexOf: target) }
                }
                .entrance(index: index, generation: openGeneration)
            }
        }
        if !editing {
            Group {
                if addingProvider {
                    AddProviderForm(engine: engine) {
                        withAnimation(Theme.snappy(0.4)) { addingProvider = false }
                    }
                } else {
                    AddProviderCard {
                        withAnimation(Theme.snappy(0.4)) { addingProvider = true }
                    }
                }
            }
            .entrance(index: engine.snapshots.count, generation: openGeneration)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(theme.text)
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text("\(engine.snapshots.count) providers · \(engine.updatedText)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.text2)
                }
            }
            Spacer()
            if !showingSettings, !showingMascot, !engine.snapshots.isEmpty {
                IconButton(systemName: editing ? "checkmark" : "slider.horizontal.3") {
                    withAnimation(Theme.snappy(0.3)) {
                        editing.toggle()
                        if editing { addingProvider = false; editingProviderId = nil }
                    }
                }
                .help(editing ? "Done editing" : "Edit providers")
            }
            IconButton(systemName: showingSettings ? "checkmark" : "gearshape") {
                withAnimation(Theme.snappy(0.3)) {
                    showingSettings.toggle()
                    if showingSettings { editing = false; addingProvider = false; editingProviderId = nil; showingMascot = false }
                }
            }
            .help(showingSettings ? "Done" : "Settings")
            IconButton(systemName: "arrow.clockwise") {
                withAnimation(.easeInOut(duration: 0.6)) { refreshSpin += 360 }
                // A deliberate click forces past the 429 cooldown so it always
                // re-attempts, rather than silently returning the stale cache.
                engine.refresh(force: true)
            }
            .rotationEffect(.degrees(refreshSpin))
        }
        .padding(EdgeInsets(top: 15, leading: 16, bottom: 11, trailing: 12))
    }
}

/// Makes a card draggable and a drop target while edit mode is on. As a dragged
/// card passes over another, `onMove` reorders live under the cursor.
private struct Reorderable: ViewModifier {
    let active: Bool
    let id: String
    @Binding var draggingId: String?
    let onMove: (_ dragged: String, _ target: String) -> Void

    func body(content: Content) -> some View {
        if active {
            content
                .onDrag {
                    draggingId = id
                    return NSItemProvider(object: id as NSString)
                }
                .onDrop(
                    of: [.text],
                    delegate: ReorderDropDelegate(targetId: id, draggingId: $draggingId, onMove: onMove)
                )
        } else {
            content
        }
    }
}

private struct ReorderDropDelegate: DropDelegate {
    let targetId: String
    @Binding var draggingId: String?
    let onMove: (_ dragged: String, _ target: String) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = draggingId, dragged != targetId else { return }
        onMove(dragged, targetId)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }
}

private extension View {
    func reorderable(
        active: Bool,
        id: String,
        draggingId: Binding<String?>,
        onMove: @escaping (_ dragged: String, _ target: String) -> Void
    ) -> some View {
        modifier(Reorderable(active: active, id: id, draggingId: draggingId, onMove: onMove))
    }
}

struct IconButton: View {
    let systemName: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? theme.text : theme.text2)
                .frame(width: 28, height: 28)
                .background(hovering ? theme.chip : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct AddProviderCard: View {
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.text2.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .background(theme.chip, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add a provider")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(hovering ? theme.text : theme.text2)
                    Text("Pick a kind, point at a config folder")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text3)
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
            .background(hovering ? theme.chip : .clear, in: RoundedRectangle(cornerRadius: 15))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        hovering ? theme.text3 : theme.cardBorder,
                        style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add a provider right here — saved to providers.json")
    }
}

struct RailView: View {
    @ObservedObject var engine: UsageEngine
    let onExpand: () -> Void

    @State private var hovering = false
    @Environment(\.theme) private var theme

    static let mascotPx: CGFloat = 28
    static let spacing: CGFloat = 13
    static let chevronHeight: CGFloat = 16
    /// Padding above the chevron and below the last mascot. Kept >= the panel's
    /// corner radius so a hover-scaled bottom mascot never clips on the corner.
    static let vPadding: CGFloat = 16

    /// Natural height for `count` providers — the rail panel is sized to this so
    /// it stops at the last mascot instead of filling the screen.
    static func contentHeight(providerCount count: Int) -> CGFloat {
        let items = count + 1 // chevron + one mascot per provider
        let itemsHeight = chevronHeight + CGFloat(count) * mascotPx
        let gaps = CGFloat(max(items - 1, 0)) * spacing
        return vPadding * 2 + itemsHeight + gaps
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text2)
                .frame(height: Self.chevronHeight)
            ForEach(engine.snapshots) { snapshot in
                MascotView(
                    style: snapshot.config.resolvedStyle,
                    palette: snapshot.config.resolvedPalette,
                    mood: snapshot.mood,
                    px: Self.mascotPx,
                    bob: false,
                    hopsOnHover: false,
                    spriteName: snapshot.config.resolvedSprite
                )
                .frame(width: Self.mascotPx, height: Self.mascotPx)
                .scaleEffect(hovering ? 1.08 : 1)
                .animation(.easeOut(duration: 0.2), value: hovering)
            }
        }
        .padding(.vertical, Self.vPadding)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .onHover { hovering = $0 }
        .help("Open usage")
    }
}

/// Staggered slide-up entrance (translate-only — resting state is always visible,
/// a lesson learned in the prototype).
private struct EntranceEffect: ViewModifier {
    let index: Int
    let generation: Int

    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: settled || reduceMotion ? 0 : 10)
            .onAppear { animateIn() }
            .onChange(of: generation) { _, _ in
                settled = false
                animateIn()
            }
    }

    private func animateIn() {
        withAnimation(Theme.snappy(0.5).delay(Double(index) * 0.06)) {
            settled = true
        }
    }
}

extension View {
    func entrance(index: Int, generation: Int) -> some View {
        modifier(EntranceEffect(index: index, generation: generation))
    }
}
