// PanelController.swift — owns the two NSPanels (full dock + collapsed rail),
// pinned to the right edge of the screen below the menu bar, and the slide
// animations between hidden / open / rail states.

import AppKit
import SwiftUI

/// Which screen the dock should show when it opens.
enum PanelScreen { case dock, mascot }

/// Observable bridge so SwiftUI re-runs the entrance stagger on every open.
@MainActor
final class PanelState: ObservableObject {
    @Published var openGeneration = 0
    /// Screen to jump to on the next open. Never reset — `open(screen:)`
    /// reassigns it on every open, so a stale value can't leak into a later one.
    @Published var initialScreen: PanelScreen = .dock
}

@MainActor
final class PanelController: NSObject {
    enum DockState { case hidden, open, rail }

    private(set) var state: DockState = .hidden

    static let panelWidth: CGFloat = 336
    /// How far the collapse tab bulges out past the panel's left edge.
    static let handleOverhang: CGFloat = 16
    static let handleHeight: CGFloat = 54
    static let railWidth: CGFloat = 46

    private let engine: UsageEngine
    private let panelState = PanelState()
    private var panel: NSPanel!
    private var rail: NSPanel!
    private var localMonitor: Any?
    private var globalMonitor: Any?

    /// Windows whose clicks must not dismiss the panel (the status item button).
    var ignoredWindows: [NSWindow] = []

    init(engine: UsageEngine) {
        self.engine = engine
        super.init()
        panel = Self.makePanel(width: Self.panelWidth + Self.handleOverhang)
        rail = Self.makePanel(width: Self.railWidth)
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

        let railRoot = RailRootView(engine: engine, onExpand: { [weak self] in self?.openFromRail() })
        rail.contentView = NSHostingView(rootView: railRoot)
    }

    // MARK: geometry

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }

    private func panelFrame(onScreen: Bool) -> NSRect {
        let v = screen.visibleFrame
        let width = Self.panelWidth + Self.handleOverhang
        let x = onScreen ? v.maxX - width : v.maxX - Self.handleOverhang + 6
        return NSRect(x: x, y: v.minY, width: width, height: v.height)
    }

    private func railFrame(onScreen: Bool) -> NSRect {
        let v = screen.visibleFrame
        let x = onScreen ? v.maxX - Self.railWidth : v.maxX - Self.railWidth + 20
        // Only as tall as the chevron + provider mascots, anchored under the menu
        // bar — not the full screen height.
        let height = min(RailView.contentHeight(providerCount: engine.snapshots.count), v.height)
        return NSRect(x: x, y: v.maxY - height, width: Self.railWidth, height: height)
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
        // rail fades + slides in slightly behind the panel's exit (0.12s delay)
        rail.setFrame(railFrame(onScreen: false), display: false)
        rail.alphaValue = 0
        rail.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.state == .rail else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
                self.rail.animator().alphaValue = 1
                self.rail.animator().setFrame(self.railFrame(onScreen: true), display: true)
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
        let shape = PanelShape(
            tabWidth: PanelController.handleOverhang,
            tabHeight: PanelController.handleHeight,
            cornerRadius: 16
        )
        DockView(engine: engine, openGeneration: panelState.openGeneration, initialScreen: panelState.initialScreen)
        .frame(width: PanelController.panelWidth)
        .frame(maxHeight: .infinity)
        // The tab lives in this inset, so the material and border below cover the
        // panel body and the tab in one pass.
        .padding(.leading, PanelController.handleOverhang)
        .background {
            ZStack {
                VisualEffect()
                theme.panelTint
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(theme.panelEdge, lineWidth: 0.5))
        .overlay(alignment: .leading) {
            HandleButton(action: onDismiss)
        }
        .environment(\.theme, theme)
    }
}

/// The dock's silhouette: a screen-edge-anchored rounded rectangle with the
/// collapse tab bulging out of its left edge.
///
/// Drawn as ONE shape on purpose. When the tab was its own view stacked on top,
/// it painted a second `panelTint` over the panel's left edge — a darker slab
/// across the first card — and stroked a border straight down the seam where the
/// two met. Sharing the panel's material and outline removes both.
struct PanelShape: Shape {
    let tabWidth: CGFloat
    let tabHeight: CGFloat
    let cornerRadius: CGFloat

    /// Fully rounds the tab's outer edge, so it reads as a pull-tab rather than a
    /// rectangle glued to the panel.
    private var tabRadius: CGFloat { min(tabWidth / 2, tabHeight / 2) }

    func path(in rect: CGRect) -> Path {
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
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.resolve(scheme)
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hovering ? theme.text : theme.text2)
                // Optical centring, not geometric. Dead-centre in the frame the
                // chevron reads as pushed toward the panel: the tab's outer edge
                // is a hard outline while its inner edge dissolves into the panel
                // body, so the eye sees more room on the right. `chevron.right`
                // also carries its ink left of its own box's centre. Nudging back
                // toward the outer edge puts it where it looks centred.
                .offset(x: -1.5)
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
        .help("Hide Merlyn — the menu bar icon brings it back")
    }
}

struct RailRootView: View {
    @ObservedObject var engine: UsageEngine
    let onExpand: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.resolve(scheme)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 14, bottomLeadingRadius: 14,
            bottomTrailingRadius: 0, topTrailingRadius: 0,
            style: .continuous
        )
        RailView(engine: engine, onExpand: onExpand)
            .background { ZStack { VisualEffect(); theme.panelTint } }
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.panelEdge, lineWidth: 0.5))
            .environment(\.theme, theme)
    }
}
