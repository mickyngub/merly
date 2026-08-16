// PanelController.swift — owns the two NSPanels (full dock + collapsed rail),
// pinned to the right edge of the screen below the menu bar, and the slide
// animations between hidden / open / rail states.

import AppKit
import SwiftUI

/// Which screen the dock should show when it opens.
enum PanelScreen { case dock, mascot }

/// Which side of the screen the expanded dock flies in from.
enum DockSide { case leading, trailing }

/// Observable bridge so SwiftUI re-runs the entrance stagger on every open, and
/// so both windows re-lay out when the rail is dragged to a different edge.
@MainActor
final class PanelState: ObservableObject {
    @Published var openGeneration = 0
    /// Screen to jump to on the next open. Never reset — `open(screen:)`
    /// reassigns it on every open, so a stale value can't leak into a later one.
    @Published var initialScreen: PanelScreen = .dock
    /// The edge the rail is pinned to, mirrored out of the config so the rail's
    /// SwiftUI content can re-orient the moment it is dropped.
    @Published var railEdge: RailPlacement.Edge = .right
    /// Which side the dock opens on. It follows the rail: expanding a rail on the
    /// left of the screen into a panel on the right puts the panel nowhere near
    /// the thing that was clicked.
    @Published var dockSide: DockSide = .trailing
}

@MainActor
final class PanelController: NSObject {
    enum DockState { case hidden, open, rail }

    private(set) var state: DockState = .hidden

    static let panelWidth: CGFloat = 336
    /// How far the collapse tab bulges out past the panel's inner edge.
    static let handleOverhang: CGFloat = 16
    static let handleHeight: CGFloat = 54

    private let engine: UsageEngine
    private let panelState = PanelState()
    private var panel: NSPanel!
    private var rail: NSPanel!
    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// Where inside the rail a drag grabbed it, in screen points, captured on the
    /// first move. The window travels with the cursor, so the grab point is the
    /// only fixed thing to position against.
    private var railGrab: CGSize?

    /// Windows whose clicks must not dismiss the panel (the status item button).
    var ignoredWindows: [NSWindow] = []

    init(engine: UsageEngine) {
        self.engine = engine
        super.init()
        panel = Self.makePanel(width: Self.panelWidth + Self.handleOverhang)
        // Any size will do: every show sets the rail's frame from its placement
        // first, and that changes shape with the edge it is on.
        rail = Self.makePanel(width: 46)
        panelState.railEdge = engine.appConfig.railPlacement.edge
        panelState.dockSide = Self.dockSide(for: engine.appConfig.railPlacement)
        installContent()
        installMonitors()
    }

    /// Borderless panels refuse key status by default, which would make the
    /// add-provider form's text fields untypeable. .nonactivatingPanel still
    /// keeps the app itself from activating (Spotlight-style).
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private static func makePanel(width: CGFloat) -> NSPanel {
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        return p
    }

    private func installContent() {
        let dockRoot = PanelRootView(
            engine: engine,
            panelState: panelState,
            onDismiss: { [weak self] in self?.hide() }
        )
        panel.contentView = NSHostingView(rootView: dockRoot)

        let railRoot = RailRootView(
            engine: engine,
            panelState: panelState,
            onExpand: { [weak self] in self?.openFromRail() },
            onClose: { [weak self] in self?.hide() },
            onDragChanged: { [weak self] mouse in self?.railDragged(to: mouse) },
            onDragEnded: { [weak self] _ in self?.railDropped() }
        )
        rail.contentView = NSHostingView(rootView: railRoot)
    }

    // MARK: geometry

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }

    /// The screen the rail belongs to: whichever one it is currently sitting on, so
    /// a rail dragged onto a second display snaps to *that* display's edges. Falls
    /// back to the main screen before it has ever been placed.
    private var railScreen: NSScreen {
        let centre = CGPoint(x: rail.frame.midX, y: rail.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) } ?? screen
    }

    private var placement: RailPlacement { engine.appConfig.railPlacement }

    /// A rail on a side edge hands the dock that side. A rail along the top or
    /// bottom has no side of its own, so the dock takes whichever half of the
    /// screen the rail was dropped in.
    private static func dockSide(for placement: RailPlacement) -> DockSide {
        switch placement.edge {
        case .left: return .leading
        case .right: return .trailing
        case .top, .bottom: return placement.offset < 0.5 ? .leading : .trailing
        }
    }

    private func panelFrame(onScreen: Bool) -> NSRect {
        let v = screen.visibleFrame
        let width = Self.panelWidth + Self.handleOverhang
        let x: CGFloat
        switch panelState.dockSide {
        case .trailing:
            // Off-screen leaves the tab's tip showing, which is what the panel
            // slides back out from.
            x = onScreen ? v.maxX - width : v.maxX - Self.handleOverhang + 6
        case .leading:
            x = onScreen ? v.minX : v.minX - width + Self.handleOverhang - 6
        }
        return NSRect(x: x, y: v.minY, width: width, height: v.height)
    }

    /// The rail's rect for a placement: pinned to its edge, only as long as its
    /// controls and mascots need, and sitting `offset` of the way along.
    ///
    /// `onScreen: false` is the same rect shoved 20pt past the edge — where the
    /// rail fades in from and out to.
    private func railFrame(_ placement: RailPlacement, onScreen: Bool) -> NSRect {
        let v = railScreen.visibleFrame
        let vertical = placement.edge.isVertical
        let breadth = RailView.breadth(vertical: vertical)
        let length = min(
            RailView.contentLength(providerCount: engine.snapshots.count, vertical: vertical),
            vertical ? v.height : v.width
        )
        let slide: CGFloat = onScreen ? 0 : 20
        let fraction = min(max(placement.offset, 0), 1)

        switch placement.edge {
        case .right, .left:
            // offset 0 is flush under the menu bar, 1 is flush with the bottom.
            let y = v.maxY - length - (v.height - length) * fraction
            let x = placement.edge == .right ? v.maxX - breadth + slide : v.minX - slide
            return NSRect(x: x, y: y, width: breadth, height: length)
        case .top, .bottom:
            let x = v.minX + (v.width - length) * fraction
            let y = placement.edge == .top ? v.maxY - breadth + slide : v.minY - slide
            return NSRect(x: x, y: y, width: length, height: breadth)
        }
    }

    // MARK: dragging the rail

    /// Follow the cursor. Absolute screen coordinates rather than the gesture's own
    /// translation: the window is moving as the drag reports, so a view-relative
    /// measurement would chase itself.
    private func railDragged(to mouse: CGPoint) {
        guard state == .rail else { return }
        let frame = rail.frame
        let grab = railGrab ?? CGSize(width: mouse.x - frame.minX, height: mouse.y - frame.minY)
        railGrab = grab
        rail.setFrameOrigin(CGPoint(x: mouse.x - grab.width, y: mouse.y - grab.height))
    }

    /// Snap to the nearest edge and remember it.
    ///
    /// The rail keeps its old shape for the whole drag and only re-orients here.
    /// Flipping a column into a row mid-drag resizes the window under the cursor,
    /// which throws the grab point off and reads as the rail squirming away.
    private func railDropped() {
        railGrab = nil
        guard state == .rail else { return }
        let snapped = nearestPlacement(for: rail.frame)
        engine.updateRailPlacement(snapped)
        panelState.railEdge = snapped.edge
        panelState.dockSide = Self.dockSide(for: snapped)
        slide(rail, to: railFrame(snapped, onScreen: true), duration: 0.28)
    }

    /// Which edge the rail was dropped nearest, and how far along it.
    private func nearestPlacement(for frame: NSRect) -> RailPlacement {
        let v = railScreen.visibleFrame
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        // Measured centre-to-edge, so the winner is the edge the rail is leaning
        // toward rather than the one its nearest corner happens to touch.
        let distances: [(RailPlacement.Edge, CGFloat)] = [
            (.left, centre.x - v.minX),
            (.right, v.maxX - centre.x),
            (.bottom, centre.y - v.minY),
            (.top, v.maxY - centre.y),
        ]
        let edge = distances.min { $0.1 < $1.1 }?.0 ?? .right

        // The offset has to be measured against the length the rail will have
        // *after* it re-orients, not the one it is being dragged at.
        let vertical = edge.isVertical
        let length = min(
            RailView.contentLength(providerCount: engine.snapshots.count, vertical: vertical),
            vertical ? v.height : v.width
        )
        let travel = (vertical ? v.height : v.width) - length
        guard travel > 0 else { return RailPlacement(edge: edge, offset: 0) }
        let along = vertical ? (v.maxY - frame.maxY) / travel : (frame.minX - v.minX) / travel
        return RailPlacement(edge: edge, offset: Double(min(max(along, 0), 1)))
    }

    // MARK: state transitions

    func toggle() {
        switch state {
        case .open: hide()
        case .hidden, .rail: open()
        }
    }

    func open(screen: PanelScreen = .dock) {
        panelState.initialScreen = screen
        // Already visible — just re-trigger the entrance so it routes to `screen`.
        if state == .open {
            panelState.openGeneration += 1
            engine.refresh()
            return
        }
        let fromRail = state == .rail
        state = .open
        if fromRail { hideRail() }
        panelState.openGeneration += 1
        engine.refresh()

        panel.setFrame(panelFrame(onScreen: false), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        slide(panel, to: panelFrame(onScreen: true), duration: 0.46)
    }

    func hide() {
        guard state != .hidden else { return }
        let wasRail = state == .rail
        state = .hidden
        if wasRail {
            hideRail()
        } else {
            slide(panel, to: panelFrame(onScreen: false), duration: 0.4) { [weak self] in
                guard let self, self.state == .hidden else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    func collapseToRail() {
        guard state == .open else { return }
        state = .rail
        slide(panel, to: panelFrame(onScreen: false), duration: 0.4) { [weak self] in
            guard let self, self.state == .rail else { return }
            self.panel.orderOut(nil)
        }
        // The rail comes back where it was last dropped, not where it was last
        // drawn — a drag that ended in a snap is the placement, and re-reading it
        // here is what makes that stick across a collapse.
        let placement = self.placement
        panelState.railEdge = placement.edge
        // rail fades + slides in slightly behind the panel's exit (0.12s delay)
        rail.setFrame(railFrame(placement, onScreen: false), display: false)
        rail.alphaValue = 0
        rail.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.state == .rail else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
                self.rail.animator().alphaValue = 1
                self.rail.animator().setFrame(self.railFrame(placement, onScreen: true), display: true)
            }
        }
    }

    private func openFromRail() {
        guard state == .rail else { return }
        open()
    }

    private func hideRail() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            rail.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.rail.orderOut(nil) }
        })
    }

    private func slide(_ window: NSWindow, to frame: NSRect, duration: Double, then: (@MainActor @Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: {
            guard let then else { return }
            Task { @MainActor in then() }
        })
    }

    // MARK: outside-click dismissal

    /// Clicking away collapses to the rail rather than hiding outright: going back
    /// to work is the common reason to click off the panel, and the rail keeps the
    /// mascots and their gauges on screen. Fully dismissing is the chevron's job —
    /// the one gesture that means "get this off my screen".
    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .open else { return }
                self.collapseToRail()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, self.state == .open,
               let window = event.window,
               window != self.panel, window != self.rail,
               !(window is NSSavePanel), // the form's folder picker
               !self.ignoredWindows.contains(window) {
                self.collapseToRail()
            }
            return event
        }
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}

// MARK: - window root views

/// Behind-window blur (the frosted glass the prototype fakes with backdrop-filter).
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

struct PanelRootView: View {
    @ObservedObject var engine: UsageEngine
    @ObservedObject var panelState: PanelState
    /// The chevron tab: dismisses the panel outright, rail included.
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.resolve(scheme)
        // The tab always faces into the screen, so it swaps edges with the panel.
        let onLeading = panelState.dockSide == .trailing
        let shape = PanelShape(
            tabWidth: PanelController.handleOverhang,
            tabHeight: PanelController.handleHeight,
            cornerRadius: 16,
            tabOnLeading: onLeading
        )
        DockView(engine: engine, openGeneration: panelState.openGeneration, initialScreen: panelState.initialScreen)
        .frame(width: PanelController.panelWidth)
        .frame(maxHeight: .infinity)
        // The tab lives in this inset, so the material and border below cover the
        // panel body and the tab in one pass.
        .padding(onLeading ? .leading : .trailing, PanelController.handleOverhang)
        .background {
            ZStack {
                VisualEffect()
                theme.panelTint
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(theme.panelEdge, lineWidth: 0.5))
        .overlay(alignment: onLeading ? .leading : .trailing) {
            HandleButton(pointingLeading: !onLeading, action: onDismiss)
        }
        // Kill focus rings across the whole panel in one place rather than per
        // button. SwiftUI focuses the first control in a window as it appears —
        // here the header mascot — and rings it in blue, which reads as "selected"
        // on chrome nobody selected. Every control in the panel already answers
        // to hover, so none of them needs a second, louder state.
        //
        // The add/edit form opts back in: in a text field the ring is not
        // decoration, it is the only thing saying where typing will land.
        .focusEffectDisabled()
        .environment(\.theme, theme)
    }
}

/// The dock's silhouette: a screen-edge-anchored rounded rectangle with the
/// collapse tab bulging out of the edge that faces into the screen.
///
/// Drawn as ONE shape on purpose. When the tab was its own view stacked on top,
/// it painted a second `panelTint` over the panel's inner edge — a darker slab
/// across the first card — and stroked a border straight down the seam where the
/// two met. Sharing the panel's material and outline removes both.
struct PanelShape: Shape {
    let tabWidth: CGFloat
    let tabHeight: CGFloat
    let cornerRadius: CGFloat
    /// Which side the tab bulges out of. A dock on the right of the screen puts it
    /// on the left and vice versa — mirrored rather than re-derived, so the two
    /// sides can't drift apart.
    var tabOnLeading: Bool = true

    /// Fully rounds the tab's outer edge, so it reads as a pull-tab rather than a
    /// rectangle glued to the panel.
    private var tabRadius: CGFloat { min(tabWidth / 2, tabHeight / 2) }

    func path(in rect: CGRect) -> Path {
        let path = leadingTabPath(in: rect)
        guard !tabOnLeading else { return path }
        // Mirror the whole silhouette rather than write a second path: two hand-laid
        // arc sequences that have to stay each other's reflection is how the two
        // sides end up subtly different.
        return path.applying(
            CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -rect.width - rect.minX * 2, y: 0)
        )
    }

    private func leadingTabPath(in rect: CGRect) -> Path {
        let edge = rect.minX + tabWidth        // the panel body's left edge
        let tabTop = rect.midY - tabHeight / 2
        let tabBottom = rect.midY + tabHeight / 2

        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Top edge → top-leading corner → down the body's left edge to the tab.
        path.addArc(tangent1End: CGPoint(x: edge, y: rect.minY),
                    tangent2End: CGPoint(x: edge, y: tabTop), radius: cornerRadius)
        path.addLine(to: CGPoint(x: edge, y: tabTop))
        // Out along the tab's top, around its rounded outer edge, and back in.
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: tabTop),
                    tangent2End: CGPoint(x: rect.minX, y: tabBottom), radius: tabRadius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: tabBottom),
                    tangent2End: CGPoint(x: edge, y: tabBottom), radius: tabRadius)
        path.addLine(to: CGPoint(x: edge, y: tabBottom))
        // Down to the bottom-leading corner and out along the bottom edge.
        path.addArc(tangent1End: CGPoint(x: edge, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: cornerRadius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The chevron inside the panel's dismiss tab. The tab itself is part of
/// `PanelShape`, so this is only the glyph plus a slightly wider hit area.
struct HandleButton: View {
    /// Which way the glyph points — always off-screen, the direction the panel
    /// leaves in, which flips with the side the dock is docked to.
    var pointingLeading = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.resolve(scheme)
        Button(action: action) {
            Image(systemName: pointingLeading ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hovering ? theme.text : theme.text2)
                // Optical centring, not geometric. Dead-centre in the frame the
                // chevron reads as pushed toward the panel: the tab's outer edge
                // is a hard outline while its inner edge dissolves into the panel
                // body, so the eye sees more room on the outward side. The glyph
                // also carries its ink off its own box's centre. Nudging back
                // toward the outer edge puts it where it looks centred.
                .offset(x: pointingLeading ? 1.5 : -1.5)
                .frame(width: PanelController.handleOverhang,
                       height: PanelController.handleHeight)
                // Grabbable a little past the tab's edges without moving the
                // glyph: grown symmetrically, so the target stays centred on the
                // chevron rather than trailing off to one side of it.
                .contentShape(Rectangle().inset(by: -7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
        .help("Hide Merly — the menu bar icon brings it back")
    }
}

struct RailRootView: View {
    @ObservedObject var engine: UsageEngine
    @ObservedObject var panelState: PanelState
    let onExpand: () -> Void
    let onClose: () -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.resolve(scheme)
        let shape = railShape(panelState.railEdge)
        RailView(
            engine: engine,
            edge: panelState.railEdge,
            onExpand: onExpand,
            onClose: onClose,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded
        )
        .background { ZStack { VisualEffect(); theme.panelTint } }
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.panelEdge, lineWidth: 0.5))
        // No focus rings anywhere in the rail. The close button is the first
        // focusable control in the window, so SwiftUI hands it initial focus and
        // draws a blue ring around it every single time the rail appears — which
        // reads as "this is selected" on a strip whose whole job is to be glanced
        // at. Safe to disable wholesale here: the rail holds no text input, so
        // there is no keyboard state a ring would be telling you about.
        .focusEffectDisabled()
        .environment(\.theme, theme)
    }

    /// Rounded on the two corners that face into the screen, square on the pair
    /// flush against the edge — the rail should look pressed against it, not
    /// floating a rounded rectangle near it.
    private func railShape(_ edge: RailPlacement.Edge) -> UnevenRoundedRectangle {
        let r: CGFloat = 14
        switch edge {
        case .right:
            return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r,
                                          bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        case .left:
            return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                          bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
        case .top:
            return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: r,
                                          bottomTrailingRadius: r, topTrailingRadius: 0, style: .continuous)
        case .bottom:
            return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0, topTrailingRadius: r, style: .continuous)
        }
    }
}
