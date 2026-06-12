// StatusItemController.swift — the menu bar extra: the busiest provider's pixel
// mascot plus its session percentage. Left-click toggles the dock panel,
// right-click shows the app menu.

import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let engine: UsageEngine
    private let panel: PanelController
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    /// Menu-bar icon size in points (no title now, so the mascot can breathe).
    private let iconPoints: CGFloat = 19
    private var animTimer: Timer?
    private var animFrame = 0
    /// The current peak provider's look, captured for the animation timer.
    private var current: (sprite: String?, style: MascotStyle, palette: MascotPalette, mood: Mood)?

    init(engine: UsageEngine, panel: PanelController) {
        self.engine = engine
        self.panel = panel
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            if let window = button.window {
                panel.ignoredWindows.append(window)
            }
        }

        engine.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshots in self?.update(with: snapshots) }
            .store(in: &cancellables)
        update(with: engine.snapshots)
        startAnimation()
    }

    private func update(with snapshots: [ProviderSnapshot]) {
        guard let button = statusItem.button else { return }
        guard let peak = snapshots.max(by: { $0.pressurePct < $1.pressurePct }) else {
            current = nil
            button.image = nil
            button.title = "—"
            return
        }
        button.title = ""
        current = (peak.config.resolvedSprite, peak.config.resolvedStyle,
                   peak.config.resolvedPalette, peak.mood)
        let pct = Int(peak.pressurePct.rounded())
        button.toolTip = "\(peak.config.name) \(peak.config.account) — \(pct)% of closest limit used"
        renderFrame()
    }

    /// Cycle the peak mascot's 4 idle frames in the menu bar (~5 fps), matching the panel.
    private func startAnimation() {
        animTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.animFrame = (self.animFrame + 1) % 4
                self.renderFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    private func renderFrame() {
        guard let button = statusItem.button, let cur = current else { return }
        if let name = cur.sprite,
           let sheet = SpriteSheetStore.sheet(named: name),
           let cg = sheet.frame(row: cur.mood.spriteRow, col: animFrame) {
            let img = NSImage(cgImage: cg, size: NSSize(width: iconPoints, height: iconPoints))
            img.isTemplate = false
            button.image = img
        } else {
            button.image = Self.spriteImage(style: cur.style, palette: cur.palette,
                                            mood: cur.mood, points: iconPoints - 2)
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            panel.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let edit = NSMenuItem(title: "Edit Providers…", action: #selector(editProviders), keyEquivalent: ",")
        edit.target = self
        menu.addItem(edit)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Usage Dock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor in
            // detach so left-click goes back to toggling the panel
            self.statusItem.menu = nil
        }
    }

    @objc private func refreshNow() { engine.refresh() }

    @objc private func editProviders() { NSWorkspace.shared.open(AppPaths.configFile) }

    /// Renders the 16x16 sprite resolution-independently for the menu bar.
    static func spriteImage(style: MascotStyle, palette: MascotPalette, mood: Mood, points: CGFloat) -> NSImage {
        let grid = SpriteBuilder.build(style: style, mood: mood, blink: false)
        let image = NSImage(size: NSSize(width: points, height: points), flipped: true) { rect in
            let cell = rect.width / 16
            for y in 0..<16 {
                for x in 0..<16 {
                    guard let color = Self.nsColor(palette: palette, ch: grid[x, y]) else { continue }
                    color.setFill()
                    NSRect(
                        x: rect.minX + CGFloat(x) * cell,
                        y: rect.minY + CGFloat(y) * cell,
                        width: cell + 0.01, height: cell + 0.01
                    ).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func nsColor(palette: MascotPalette, ch: Character) -> NSColor? {
        let hex: UInt32? = switch ch {
        case "B": palette.B
        case "D": palette.D
        case "L": palette.L
        case "O": palette.O
        case "E": palette.E
        case "W": palette.W
        case "M": palette.M
        case "C": palette.C
        case "S": palette.S
        case "A": palette.A
        default: nil
        }
        guard let hex else { return nil }
        return NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
