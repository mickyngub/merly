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
    /// Screen to jump to on the next open (reset to `.dock` by the dock once shown).
    @Published var initialScreen: PanelScreen = .dock
}

@MainActor
final class PanelController: NSObject {
    enum DockState { case hidden, open, rail }

    private(set) var state: DockState = .hidden

    static let panelWidth: CGFloat = 336
    static let handleOverhang: CGFloat = 13
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
            onCollapse: { [weak self] in self?.collapseToRail() }
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

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .open else { return }
                self.hide()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, self.state == .open,
               let window = event.window,
               window != self.panel, window != self.rail,
               !(window is NSSavePanel), // the form's folder picker
               !self.ignoredWindows.contains(window) {
                self.hide()
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
    let onCollapse: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.resolve(scheme)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 16, bottomLeadingRadius: 16,
            bottomTrailingRadius: 0, topTrailingRadius: 0,
            style: .continuous
        )
        DockView(engine: engine, openGeneration: panelState.openGeneration, initialScreen: panelState.initialScreen)
        .frame(width: PanelController.panelWidth)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                VisualEffect()
                theme.panelTint
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.panelEdge, lineWidth: 0.5))
        .padding(.leading, PanelController.handleOverhang)
        .overlay(alignment: .leading) {
            HandleButton(action: onCollapse)
        }
        .environment(\.theme, theme)
    }
}

struct HandleButton: View {
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.resolve(scheme)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 9, bottomLeadingRadius: 9,
            bottomTrailingRadius: 4, topTrailingRadius: 4,
            style: .continuous
        )
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(hovering ? theme.text : theme.text2)
                .frame(width: 26, height: 54)
                .background { ZStack { VisualEffect(); theme.panelTint } }
                .clipShape(shape)
                .overlay(shape.strokeBorder(theme.panelEdge, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Collapse to rail")
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
