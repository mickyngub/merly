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

    /// Short off-mood expression borrowed from another sheet row, so the menu
    /// bar critter uses the whole 4×4 range instead of idling on one row.
    private var emote: (row: Int, ticksLeft: Int)?
    private var ticksUntilEmote = Int.random(in: 25...60)

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
        // The menu bar shows the user's editable default mascot; only its mood
        // tracks the busiest provider's pressure (happy when there are none).
        let mascot = engine.appConfig.defaultMascotConfig
        let peak = snapshots.max(by: { $0.pressurePct < $1.pressurePct })
        let mood = peak?.mood ?? .happy
        button.title = ""
        if mood != current?.mood { emote = nil } // real data beats a flourish
        current = (mascot.resolvedSprite, mascot.style, mascot.resolvedPalette, mood)
        if let peak {
            let pct = Int(peak.pressurePct.rounded())
            button.toolTip = "\(peak.config.name) \(peak.config.account) — \(pct)% of closest limit used"
        } else {
            button.toolTip = "Usage Dock"
        }
        renderFrame()
    }

    /// Animate the peak mascot at ~5 fps, matching the panel.
    private func startAnimation() {
        animTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    /// One animation tick: advance the idle frame, and every ~5–12s play a
    /// brief (0.8–1.6s) expression from one of the other mood rows.
    private func tick() {
        animFrame = (animFrame + 1) % 4
        if var e = emote {
            e.ticksLeft -= 1
            if e.ticksLeft <= 0 {
                emote = nil
                ticksUntilEmote = Int.random(in: 25...60)
            } else {
                emote = e
            }
        } else {
            ticksUntilEmote -= 1
            if ticksUntilEmote <= 0, let cur = current,
               let row = [0, 1, 2, 3, 6, 7].filter({ $0 != cur.mood.spriteRow }).randomElement() {
                emote = (row, Int.random(in: 4...8))
            }
        }
        renderFrame()
    }

    private func renderFrame() {
        guard let button = statusItem.button, let cur = current else { return }
        let row = emote?.row ?? cur.mood.spriteRow
        if let name = cur.sprite,
           let cg = SpriteSheetStore.recoloredFrame(
               name: name, row: row, col: animFrame, accentHex: cur.palette.B
           ) {
            let img = NSImage(cgImage: cg, size: NSSize(width: iconPoints, height: iconPoints))
            img.isTemplate = false
            button.image = img
        } else {
            button.image = Self.spriteImage(style: cur.style, palette: cur.palette,
                                            mood: Mood.fromRow(row), points: iconPoints - 2)
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

        let mascot = NSMenuItem(title: "Edit Mascot…", action: #selector(editMascot), keyEquivalent: "m")
        mascot.target = self
        menu.addItem(mascot)

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

    /// Open the dock straight to the mascot editor.
    @objc private func editMascot() { panel.open(screen: .mascot) }

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
