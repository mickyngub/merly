// DockView.swift — the docked panel content: header, provider card list with
// staggered entrance, and the add-provider affordance. Also the collapsed rail.

import SwiftUI
import UniformTypeIdentifiers

/// Which screen the dock body shows. One value, so two screens can never be on
/// at once — the old five independent booleans had to be zeroed in four places,
/// and one missed reset stacked two screens.
enum DockScreen: Equatable {
    /// The provider list, with its inline mode.
    case list(ListMode)
    case settings
    case mascot

    enum ListMode: Equatable {
        case browsing
        /// Reorder/delete mode (the slider button in the header).
        case editing
        /// The inline add form is open in place of the dashed add card.
        case adding
        /// The inline edit form replaces this provider's card.
        case editingProvider(String)
    }
}

struct DockView: View {
    @ObservedObject var engine: UsageEngine
    /// Bumped every time the panel opens, retriggering the entrance stagger.
    let openGeneration: Int
    /// Screen to show on open — `.mascot` jumps straight to the mascot editor.
    let initialScreen: PanelScreen

    @State private var refreshSpin = 0.0
    @State private var screen: DockScreen = .list(.browsing)
    @State private var draggingId: String?
    @Environment(\.theme) private var theme

    /// The list's inline mode, or nil when another screen is up.
    private var listMode: DockScreen.ListMode? {
        if case .list(let mode) = screen { return mode }
        return nil
    }

    private var isEditing: Bool { listMode == .editing }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    switch screen {
                    case .mascot:
                        MascotEditorView(engine: engine) {
                            withAnimation(Theme.snappy(0.4)) { screen = .list(.browsing) }
                        }
                        .entrance(index: 0, generation: openGeneration)
                    case .settings:
                        SettingsView(engine: engine) {
                            withAnimation(Theme.snappy(0.4)) { screen = .list(.browsing) }
                        }
                        .entrance(index: 0, generation: openGeneration)
                    case .list:
                        providerList
                    }
                }
                .padding(EdgeInsets(top: 2, leading: 10, bottom: 12, trailing: 10))
                // Reset the drag state when a card is dropped in a gap (no card
                // delegate fires), so the faded card snaps back to full opacity.
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    draggingId = nil
                    return false
                }
            }
        }
        .onChange(of: openGeneration) { _, _ in
            screen = initialScreen == .mascot ? .mascot : .list(.browsing)
        }
    }

    @ViewBuilder
    private var providerList: some View {
        ForEach(Array(engine.snapshots.enumerated()), id: \.element.id) { index, snapshot in
            if listMode == .editingProvider(snapshot.id) {
                AddProviderForm(engine: engine, editing: snapshot.config) {
                    withAnimation(Theme.snappy(0.4)) { screen = .list(.browsing) }
                }
                .entrance(index: index, generation: openGeneration)
            } else {
                ProviderCardView(
                    snapshot: snapshot,
                    editing: isEditing,
                    onEdit: { withAnimation(Theme.snappy(0.4)) { screen = .list(.editingProvider(snapshot.id)) } },
                    onDelete: { withAnimation(Theme.snappy(0.4)) { engine.removeProvider(snapshot.id) } }
                )
                .opacity(draggingId == snapshot.id ? 0.4 : 1)
                .reorderable(active: isEditing, id: snapshot.id, draggingId: $draggingId) { dragged, target in
                    withAnimation(Theme.snappy(0.3)) { engine.moveProvider(dragged, toIndexOf: target) }
                }
                .entrance(index: index, generation: openGeneration)
            }
        }
        if !isEditing {
            Group {
                if listMode == .adding {
                    AddProviderForm(engine: engine) {
                        withAnimation(Theme.snappy(0.4)) { screen = .list(.browsing) }
                    }
                } else {
                    AddProviderCard {
                        withAnimation(Theme.snappy(0.4)) { screen = .list(.adding) }
                    }
                }
            }
            .entrance(index: engine.snapshots.count, generation: openGeneration)
        }
    }

    /// The app's own mascot beside the title — its home, now that the menu bar
    /// wears the reported provider's critter instead. Its mood tracks the busiest
    /// provider's pressure, but never `.dead`: this one is Merlyn itself, and one
    /// lapsed provider mustn't make the app look broken. Tapping it opens the
    /// editor, which is otherwise only reachable from the right-click menu.
    private var titleMascot: some View {
        let mascot = engine.appConfig.defaultMascotConfig
        let peak = engine.snapshots.max { $0.pressurePct < $1.pressurePct }
        // A Button rather than a bare tap gesture so keyboard and VoiceOver users
        // can reach the editor too.
        return Button {
            withAnimation(Theme.snappy(0.4)) { screen = .mascot }
        } label: {
            MascotView(
                style: mascot.style,
                palette: mascot.resolvedPalette,
                mood: peak.map { $0.isUnavailable ? .happy : $0.mood } ?? .happy,
                px: 26,
                spriteName: mascot.resolvedSprite,
                animationKey: MascotAnimator.appKey
            )
            .frame(width: 26, height: 26)
            .overlay(alignment: .topLeading) {
                if mascot.isShiny {
                    ShinySparkle().help("Shiny! A rare mascot color.")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit the Merlyn mascot")
        .help("Merlyn — click to edit the mascot")
    }

    private var header: some View {
        HStack(spacing: 10) {
            if screen != .mascot {
                titleMascot
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Merlyn")
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
            if listMode != nil, !engine.snapshots.isEmpty {
                IconButton(systemName: isEditing ? "checkmark" : "slider.horizontal.3") {
                    withAnimation(Theme.snappy(0.3)) {
                        screen = .list(isEditing ? .browsing : .editing)
                    }
                }
                .help(isEditing ? "Done editing" : "Edit providers")
            }
            IconButton(systemName: screen == .settings ? "checkmark" : "gearshape") {
                withAnimation(Theme.snappy(0.3)) {
                    screen = screen == .settings ? .list(.browsing) : .settings
                }
            }
            .help(screen == .settings ? "Done" : "Settings")
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
    /// One gauge lane under each mascot, the space above the first, and the gap
    /// between lanes — the menu bar item's proportions scaled up to the rail's
    /// larger mascot.
    static let gaugeHeight: CGFloat = 4
    static let gaugeGap: CGFloat = 4
    static let laneGap: CGFloat = 2
    /// Lanes reserved per provider: the 5h window and the weekly cap (see
    /// `ProviderSnapshot.iconGauges`).
    static let laneCount = 2
    /// Padding above the chevron and below the last mascot. Kept >= the panel's
    /// corner radius so a hover-scaled bottom mascot never clips on the corner.
    static let vPadding: CGFloat = 16

    /// One provider's slot: mascot plus both gauge lanes under it. Both rows are
    /// reserved even for a provider that draws one bar or none, so a single-limit
    /// provider — or one dropping out entirely — doesn't reflow the rail or shift
    /// the mascots' rhythm.
    static var itemHeight: CGFloat {
        mascotPx + gaugeGap + CGFloat(laneCount) * gaugeHeight
            + CGFloat(laneCount - 1) * laneGap
    }

    /// Natural height for `count` providers — the rail panel is sized to this so
    /// it stops at the last mascot instead of filling the screen.
    static func contentHeight(providerCount count: Int) -> CGFloat {
        let items = count + 1 // chevron + one mascot per provider
        let itemsHeight = chevronHeight + CGFloat(count) * itemHeight
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
                item(snapshot)
            }
        }
        .padding(.vertical, Self.vPadding)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .onHover { hovering = $0 }
        // The whole rail is one click target, so it presents as one button.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open the Merlyn usage panel")
        .accessibilityAction { onExpand() }
        .help("Open usage")
    }

    /// One rail entry: the mascot with its gauge lanes tucked underneath, the same
    /// reading the menu bar carries — but for every provider at once.
    ///
    /// Collapsed used to be mascots only, which shows the *mood* but not the
    /// number, so "how close am I to being blocked" still meant expanding the
    /// panel. The mood face and the bar answer different questions and the rail is
    /// where you want the second one without opening anything.
    private func item(_ snapshot: ProviderSnapshot) -> some View {
        VStack(spacing: Self.gaugeGap) {
            MascotView(
                style: snapshot.config.resolvedStyle,
                palette: snapshot.config.resolvedPalette,
                mood: snapshot.mood,
                px: Self.mascotPx,
                bob: false,
                hopsOnHover: false,
                spriteName: snapshot.config.resolvedSprite,
                animationKey: snapshot.id
            )
            .frame(width: Self.mascotPx, height: Self.mascotPx)
            .overlay(alignment: .bottomTrailing) {
                if let failure = snapshot.failure {
                    RailFailureBadge(failure: failure).offset(x: 3, y: 1)
                }
            }
            gauge(snapshot)
        }
        // Deliberately the *rail's* hover, not this item's: the whole rail is one
        // click target ("expand me"), so every critter leans in together. Per-item
        // hover would suggest the mascots are individually clickable — they aren't.
        .scaleEffect(hovering ? 1.08 : 1)
        .animation(.easeOut(duration: 0.2), value: hovering)
        .help(snapshot.gaugeTooltip())
    }

    /// The 5h window and the weekly cap as two bars the mascot's width, nearest lane
    /// first, each filled left to right with the same warn/danger escalation as every
    /// bar in the panel. Both slots are always laid out — a provider with one limit
    /// leaves the outer one empty rather than sliding its bar up, so a lane means the
    /// same window down the whole rail.
    ///
    /// **A failure draws no bar at all** — not an empty track, not a dash in it.
    /// Anything gauge-shaped is read as a level, so a disconnected provider would
    /// show what looks like a measurement of nothing; it gets a badge on its
    /// shoulder instead, which is unmistakably a state and not a quantity. Same
    /// reasoning as the menu bar item.
    private func gauge(_ snapshot: ProviderSnapshot) -> some View {
        let lanes = snapshot.iconGauges
        return VStack(spacing: Self.laneGap) {
            ForEach(0..<Self.laneCount, id: \.self) { index in
                if index < lanes.count {
                    lane(lanes[index])
                } else {
                    Color.clear.frame(width: Self.mascotPx, height: Self.gaugeHeight)
                }
            }
        }
    }

    private func lane(_ reading: IconGauge) -> some View {
        // The colour of the limit being reported, not of this account: the same
        // window wears the same hue on the card, in the menu bar, and here.
        let laneColor = Color(hex: reading.colorHex)
        let fraction = min(max(reading.pct / 100, 0), 1)
        return Capsule()
            // A tint of that limit's own colour rather than a neutral track,
            // matching the menu bar and the ring lanes: bar and mascot read as
            // one object that way.
            .fill(laneColor.opacity(0.30))
            .frame(width: Self.mascotPx, height: Self.gaugeHeight)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Theme.limitColor(pct: reading.pct, lane: laneColor))
                    // Never narrower than the bar is tall, so a live 1% still
                    // reads as a fill and not a rendering artefact.
                    .frame(width: max(Self.gaugeHeight, Self.mascotPx * fraction))
                    .opacity(fraction > 0 ? 1 : 0)
            }
            .animation(Theme.snappy(0.55), value: fraction)
    }
}

/// A failing provider's shoulder badge — what the rail shows in place of the gauge
/// it must not draw. One glyph for every failure kind, hand-picked over
/// `failure.symbol` because those (`person.badge.key`, `bolt.slash.fill`) are mush
/// at 12pt; the tint separates a broken account from a bad minute, and the tooltip
/// names it exactly.
private struct RailFailureBadge: View {
    let failure: ProviderFailure

    var body: some View {
        let tint = failure.isFault ? Theme.danger : Theme.warn
        return Image(systemName: "exclamationmark")
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 12, height: 12)
            .background(tint, in: Circle())
            // Lifts the badge off the sprite it overlaps, the same trick the ring
            // lanes use — without it the dot merges into a dark critter.
            .shadow(color: .black.opacity(0.45), radius: 1.5)
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
