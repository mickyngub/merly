// DockView.swift — the docked panel content: header, provider card list with
// staggered entrance, and the add-provider affordance. Also the collapsed rail.

import AppKit
import SwiftUI

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
    @State private var screen: DockScreen = .list(QAFlags.editMode ? .editing : .browsing)
    @State private var drag: DragReorder?
    /// One card plus the list's spacing — how far a reorder drag travels per slot.
    /// Measured rather than assumed: the card's height moves with its content.
    @State private var rowStep: CGFloat = 0
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
                VStack(spacing: Self.listSpacing) {
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
                .onPreferenceChange(RowHeightKey.self) { height in
                    if height > 0 { rowStep = height + Self.listSpacing }
                }
            }
        }
        .onChange(of: openGeneration) { _, _ in
            screen = initialScreen == .mascot ? .mascot : .list(QAFlags.editMode ? .editing : .browsing)
        }
        // Leaving edit mode (or the list entirely) tears the held card's gesture
        // out from under it, so drop the drag rather than let it strand a card.
        .onChange(of: isEditing) { _, _ in drag = nil }
    }

    /// Vertical gap between cards, shared with the drag's row arithmetic.
    private static let listSpacing: CGFloat = 9

    @ViewBuilder
    private var providerList: some View {
        ForEach(Array(engine.snapshots.enumerated()), id: \.element.id) { index, snapshot in
            if listMode == .editingProvider(snapshot.id) {
                AddProviderForm(engine: engine, editing: snapshot.config) {
                    withAnimation(Theme.snappy(0.4)) { screen = .list(.browsing) }
                }
                .entrance(index: index, generation: openGeneration)
            } else {
                let held = drag?.id == snapshot.id
                ProviderCardView(
                    snapshot: snapshot,
                    editing: isEditing,
                    dragging: held,
                    onEdit: { withAnimation(Theme.snappy(0.4)) { screen = .list(.editingProvider(snapshot.id)) } },
                    onDelete: { withAnimation(Theme.snappy(0.4)) { engine.removeProvider(snapshot.id) } }
                )
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: RowHeightKey.self, value: geo.size.height)
                    }
                )
                .offset(y: held ? drag?.offset ?? 0 : 0)
                // The held card rides above its neighbours as they slide past it.
                .zIndex(held ? 1 : 0)
                .gesture(reorderGesture(snapshot), including: isEditing ? .all : .subviews)
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

    /// Drag-to-reorder, hand-rolled rather than `onDrag`/`onDrop`.
    ///
    /// The AppKit drag session behind `onDrag` ends wherever the pointer happens to
    /// be, and a drop outside the panel fires no delegate at all — so the card it
    /// had faded to 0.4 stayed faded until edit mode was toggled. A gesture always
    /// terminates in `onEnded`, so the held card can't be stranded, and it gets to
    /// follow the cursor instead of trailing a translucent system drag image.
    private func reorderGesture(_ snapshot: ProviderSnapshot) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard isEditing else { return }
                var state = drag ?? DragReorder(id: snapshot.id)
                guard state.id == snapshot.id else { return }
                state.offset = value.translation.height - state.consumed

                if rowStep > 0,
                   let index = engine.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
                    // 0.6 of a row, not half: right after a swap the card sits 0.4
                    // of a row past its new slot, and an exact-half threshold would
                    // swap it straight back on the next frame, forever.
                    if state.offset > rowStep * 0.6, index + 1 < engine.snapshots.count {
                        move(snapshot.id, toIndexOf: engine.snapshots[index + 1].id)
                        state.consumed += rowStep
                    } else if state.offset < -rowStep * 0.6, index > 0 {
                        move(snapshot.id, toIndexOf: engine.snapshots[index - 1].id)
                        state.consumed -= rowStep
                    }
                    state.offset = value.translation.height - state.consumed
                }
                // The card must track the cursor exactly, so its offset stays out
                // of the reorder's animation transaction.
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { drag = state }
            }
            .onEnded { _ in
                withAnimation(Theme.snappy(0.3)) { drag = nil }
            }
    }

    private func move(_ id: String, toIndexOf targetId: String) {
        withAnimation(Theme.snappy(0.28)) { engine.moveProvider(id, toIndexOf: targetId) }
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
        .pointerCursor()
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

/// The card being dragged in edit mode: which one, how far it's been pulled from
/// the slot it currently occupies, and how much of the cursor's travel has already
/// been spent on rows that swapped underneath it.
struct DragReorder: Equatable {
    let id: String
    var offset: CGFloat = 0
    var consumed: CGFloat = 0
}

/// Tallest card in the list — the reorder drag's step size.
private struct RowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
        .pointerCursor()
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
        .pointerCursor()
        .help("Add a provider right here — saved to providers.json")
    }
}

struct RailView: View {
    @ObservedObject var engine: UsageEngine
    /// Which screen edge the rail is clinging to — it decides the stacking axis,
    /// which way the expand chevron points, and which corners are rounded.
    let edge: RailPlacement.Edge
    let onExpand: () -> Void
    /// The X: dismisses the rail outright, the same "get this off my screen" the
    /// expanded panel's chevron tab means.
    let onClose: () -> Void
    /// Screen-point mouse position, reported live while the rail is dragged. The
    /// window moves out from under the cursor as it goes, so a translation
    /// measured in view space would compound with its own effect — the controller
    /// works in absolute coordinates instead.
    var onDragChanged: (CGPoint) -> Void = { _ in }
    var onDragEnded: (CGPoint) -> Void = { _ in }

    @State private var hovering = false
    /// Set once a press has travelled far enough to be a drag rather than a click,
    /// so one gesture can serve both without SwiftUI having to arbitrate between a
    /// tap and a drag recogniser (which it resolves inconsistently once a Button
    /// is nested inside the same view).
    @State private var dragging = false
    @Environment(\.theme) private var theme

    static let mascotPx: CGFloat = 28
    static let spacing: CGFloat = 13
    /// The chevron and the close button are square, so the same number is their
    /// extent whichever way the rail runs.
    static let controlSize: CGFloat = 16
    /// One gauge lane under each mascot, the space above the first, and the gap
    /// between lanes — the menu bar item's proportions scaled up to the rail's
    /// larger mascot.
    static let gaugeHeight: CGFloat = 4
    static let gaugeGap: CGFloat = 4
    static let laneGap: CGFloat = 2
    /// Lanes reserved per provider: the 5h window and the weekly cap (see
    /// `ProviderSnapshot.iconGauges`).
    static let laneCount = 2
    /// Padding before the first control and after the last mascot. Kept >= the
    /// panel's corner radius so a hover-scaled end mascot never clips on a corner.
    static let vPadding: CGFloat = 16
    /// Clearance either side of a mascot across the rail's short dimension.
    static let crossPadding: CGFloat = 9

    /// One provider's slot: mascot plus both gauge lanes under it. Both rows are
    /// reserved even for a provider that draws one bar or none, so a single-limit
    /// provider — or one dropping out entirely — doesn't reflow the rail or shift
    /// the mascots' rhythm.
    ///
    /// Always stacked the same way round, whichever edge the rail is on: the bars
    /// mean "this critter's levels", and that only reads if they stay under it. So
    /// this is the item's length in a vertical rail and its breadth in a
    /// horizontal one.
    static var itemBlock: CGFloat {
        mascotPx + gaugeGap + CGFloat(laneCount) * gaugeHeight
            + CGFloat(laneCount - 1) * laneGap
    }

    /// The rail's short dimension — 46pt as a column, wider as a row, because a
    /// row has to fit the gauge lanes across its thickness rather than along it.
    static func breadth(vertical: Bool) -> CGFloat {
        (vertical ? mascotPx : itemBlock) + crossPadding * 2
    }

    /// Natural length for `count` providers — the rail panel is sized to this so
    /// it stops at the last mascot instead of running the whole screen edge.
    static func contentLength(providerCount count: Int, vertical: Bool) -> CGFloat {
        let items = count + 2 // close + chevron + one mascot per provider
        let perItem = vertical ? itemBlock : mascotPx
        let controls = controlSize * 2
        let gaps = CGFloat(max(items - 1, 0)) * spacing
        return vPadding * 2 + controls + CGFloat(count) * perItem + gaps
    }

    /// Points toward where the panel will expand — always away from the edge the
    /// rail is pinned to, so the glyph reads as "pull this open".
    private var expandGlyph: String {
        switch edge {
        case .right: return "chevron.left"
        case .left: return "chevron.right"
        case .top: return "chevron.down"
        case .bottom: return "chevron.up"
        }
    }

    var body: some View {
        let vertical = edge.isVertical
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: Self.spacing))
            : AnyLayout(HStackLayout(spacing: Self.spacing))
        return layout {
            RailIconButton(systemName: "xmark", help: "Close Merlyn — the menu bar icon brings it back", action: onClose)
            Image(systemName: expandGlyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text2)
                .frame(width: Self.controlSize, height: Self.controlSize)
            ForEach(engine.snapshots) { snapshot in
                item(snapshot)
            }
        }
        .padding(vertical ? .vertical : .horizontal, Self.vPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(moveOrOpen)
        .onHover { hovering = $0 }
        .pointerCursor()
        // Outside the close button the whole rail is one click target, so it
        // presents as one button.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open the Merlyn usage panel")
        .accessibilityAction { onExpand() }
        .accessibilityAction(named: "Close") { onClose() }
        .help("Open usage — or drag to another edge")
    }

    /// One gesture for both "click me open" and "drag me to another edge".
    ///
    /// `minimumDistance: 0` so the press is tracked from the first pixel — a drag
    /// recogniser with a real minimum only starts reporting *after* the pointer has
    /// already moved, which makes the rail jump that distance the moment it catches
    /// up. The click/drag decision is made here instead, on distance travelled.
    private var moveOrOpen: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let travelled = hypot(value.translation.width, value.translation.height)
                guard dragging || travelled > 5 else { return }
                dragging = true
                onDragChanged(NSEvent.mouseLocation)
            }
            .onEnded { _ in
                guard dragging else { return onExpand() }
                dragging = false
                onDragEnded(NSEvent.mouseLocation)
            }
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

/// A control in the rail's header. Sized to `controlSize` like the chevron beside
/// it, but a real Button: a nested Button wins the press against the rail's own
/// drag gesture, which is what keeps "close" from being read as "start moving me".
private struct RailIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(hovering ? theme.text : theme.text3)
                .frame(width: RailView.controlSize, height: RailView.controlSize)
                .background(hovering ? theme.chip : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
        .help(help)
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
