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

    /// Mascot size in points. 15 rather than 19 so the mascot plus the gauge
    /// beneath it still fit the 19pt the icon alone used to take — the menu bar is
    /// the one place in the app where width is somebody else's budget too.
    private let iconPoints: CGFloat = 15
    /// Gauge bar under the mascot, and the hairline of space above it.
    private let gaugeHeight: CGFloat = 3
    private let gaugeGap: CGFloat = 1
    private var animTimer: Timer?
    private var animFrame = 0
    /// The reported provider's look and gauge, captured for the animation timer.
    private var current: (
        sprite: String?, style: MascotStyle, palette: MascotPalette, mood: Mood,
        gauge: (window: String, pct: Double, estimated: Bool)?, failure: ProviderFailure?
    )?

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
            // Icon only: mascot + gauge is one drawn image, and no text. A menu bar
            // item is glanced at, not read — the exact figure is a hover away in the
            // tooltip and a click away in the panel.
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
        // Not always the busiest: the user can pin one provider's limits here.
        let reported = engine.menuBarSnapshot
        let config = engine.appConfig

        // The menu bar always wears the *reported provider's* critter: the pick can
        // roam between accounts, so a bare percentage with no visible subject can't
        // be attributed to one. The app's own mascot lives beside the panel title
        // instead, where it isn't competing with a reading. Only an app with no
        // providers at all falls back to it here.
        let wearsProvider = reported != nil
        let mascot = config.defaultMascotConfig
        let sprite = wearsProvider
            ? reported?.resolvedSpriteForm
            : SpriteSheetStore.formSprite(base: mascot.resolvedSprite, form: reported?.game?.form ?? 0)
        let style = wearsProvider ? reported!.config.resolvedStyle : mascot.style
        let palette = wearsProvider ? reported!.config.resolvedPalette : mascot.resolvedPalette
        // A provider's own critter may look dead — that's information. The app's
        // mascot is the app itself, so one lapsed provider mustn't kill it.
        let mood = wearsProvider
            ? reported!.mood
            : (reported.map { $0.isUnavailable ? .happy : $0.mood } ?? .happy)

        if mood != current?.mood { emote = nil } // real data beats a flourish
        current = (sprite, style, palette, mood, reported?.bindingGauge, reported?.failure)
        button.toolTip = Self.tooltip(for: reported, pinned: config.menuBarProviderId != nil)
        renderFrame()
    }

    /// The figure the gauge can't spell out: who it belongs to, which window it
    /// measures, and whether it's an estimate. This is where the exact number lives
    /// now that the item is icon-only.
    private static func tooltip(for snapshot: ProviderSnapshot?, pinned: Bool) -> String {
        guard let snapshot else { return "Merlyn — no providers configured" }
        let who = "\(snapshot.config.name) · \(snapshot.config.account)"
        let how = pinned ? "" : " (busiest provider)"
        if let failure = snapshot.failure {
            return "\(who)\(how) — \(failure.headline.lowercased())"
        }
        guard let gauge = snapshot.bindingGauge else { return who + how }
        let window = gauge.window == "wk" ? "weekly limit" : "\(gauge.window) window"
        return "\(who)\(how) — \(gauge.estimated ? "≈" : "")\(Int(gauge.pct.rounded()))% of the \(window) used"
            + (gauge.estimated ? ", estimated" : "")
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
        let mascot: NSImage
        if let name = cur.sprite,
           let cg = SpriteSheetStore.recoloredFrame(
               name: name, row: row, col: animFrame, accentHex: cur.palette.B
           ) {
            mascot = NSImage(cgImage: cg, size: NSSize(width: iconPoints, height: iconPoints))
            mascot.isTemplate = false
        } else {
            mascot = Self.spriteImage(style: cur.style, palette: cur.palette,
                                      mood: Mood.fromRow(row), points: iconPoints - 2)
        }
        button.image = withGauge(mascot, gauge: cur.gauge, failure: cur.failure,
                                 accentHex: cur.palette.B)
    }

    /// Mascot with the gauge tucked underneath it — how close the reported provider
    /// is to being blocked, as a bar the width of the mascot, filled left to right
    /// with the same warn/danger escalation as every bar in the panel. Under rather
    /// than beside so the whole item stays one mascot wide.
    ///
    /// **A failure draws no gauge at all** — not an empty one, not a dash in the
    /// track. A gauge-shaped anything is read as a level, so a disconnected
    /// provider showed what looked like a measurement of nothing. It gets a badged
    /// exclamation on the mascot's shoulder instead: unmistakably a state, not a
    /// quantity.
    private func withGauge(
        _ mascot: NSImage, gauge: (window: String, pct: Double, estimated: Bool)?,
        failure: ProviderFailure?, accentHex: UInt32
    ) -> NSImage {
        // Copied out of self: the drawing handler runs again on every redraw, at
        // whatever scale and on whatever thread AppKit picks, so it must not reach
        // back into a main-actor object.
        let icon = iconPoints
        let barHeight = gaugeHeight
        let gap = gaugeGap
        let radius = barHeight / 2

        if let failure {
            let tint = Self.nsColor(hex: failure.isFault ? 0xE5484D : 0xE8A33D)
            let badge: CGFloat = 8
            // The badge hangs off the mascot's bottom-right, so the item grows by a
            // couple of points rather than gaining a whole second row.
            let size = NSSize(width: icon + 1.5, height: icon + 1.5)
            let image = NSImage(size: size, flipped: false) { _ in
                mascot.draw(in: NSRect(x: 0, y: 1.5, width: icon, height: icon))
                let box = NSRect(x: size.width - badge, y: 0, width: badge, height: badge)
                // Knock a transparent ring in the sprite behind the badge so it
                // reads as a badge rather than as part of the critter.
                let context = NSGraphicsContext.current
                context?.compositingOperation = .copy
                NSColor.clear.setFill()
                NSBezierPath(ovalIn: box.insetBy(dx: -1, dy: -1)).fill()
                context?.compositingOperation = .sourceOver
                tint.setFill()
                NSBezierPath(ovalIn: box).fill()
                // A 2×3.5pt stem over a 2pt dot: an exclamation mark, hand-drawn
                // because an 8pt SF Symbol glyph is mush at this size.
                NSColor.white.setFill()
                let cx = box.midX
                NSBezierPath(rect: NSRect(x: cx - 0.75, y: box.minY + 3.2, width: 1.5, height: 3)).fill()
                NSBezierPath(ovalIn: NSRect(x: cx - 0.75, y: box.minY + 1.4, width: 1.5, height: 1.5)).fill()
                return true
            }
            image.isTemplate = false
            return image
        }

        guard let gauge else { return mascot }
        let size = NSSize(width: icon, height: icon + gap + barHeight)
        let image = NSImage(size: size, flipped: false) { _ in
            // Origin is bottom-left: the bar sits at y = 0, the mascot above it.
            mascot.draw(in: NSRect(x: 0, y: barHeight + gap, width: icon, height: icon))
            let track = NSRect(x: 0, y: 0, width: icon, height: barHeight)
            Self.nsColor(hex: accentHex).withAlphaComponent(0.30).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

            let fraction = min(max(gauge.pct / 100, 0), 1)
            guard fraction > 0 else { return true }
            let colour = gauge.pct >= Theme.dangerPct ? Self.nsColor(hex: 0xE5484D)
                : gauge.pct >= Theme.warnPct ? Self.nsColor(hex: 0xE8A33D)
                : Self.nsColor(hex: accentHex)
            colour.setFill()
            // Never narrower than the bar is tall, so a live 1% still reads as a
            // fill rather than a rendering artefact.
            let fill = NSRect(x: 0, y: 0, width: max(barHeight, icon * fraction),
                              height: barHeight)
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            panel.toggle()
        }
    }

    /// Right-click menu. Rebuilt per click so the checkmarks reflect live config.
    ///
    /// The provider pick lives here as well as in Settings: this is the thing the
    /// icon is *about*, and looking for it anywhere but on the icon itself is a
    /// hunt. Settings keeps the same two controls for the same reason the pin is
    /// persisted — it's configuration, not a one-off.
    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let config = engine.appConfig

        if !config.providers.isEmpty {
            let header = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            let auto = NSMenuItem(title: "Busiest provider",
                                  action: #selector(pickMenuBarProvider(_:)), keyEquivalent: "")
            auto.target = self
            // nil representedObject *is* the auto pick — no sentinel string.
            auto.state = config.menuBarProviderId == nil ? .on : .off
            submenu.addItem(auto)
            submenu.addItem(.separator())

            for provider in config.providers {
                let item = NSMenuItem(title: "\(provider.name) · \(provider.account)",
                                      action: #selector(pickMenuBarProvider(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = provider.id
                item.state = config.menuBarProviderId == provider.id ? .on : .off
                submenu.addItem(item)
            }
            header.submenu = submenu
            menu.addItem(header)
            menu.addItem(.separator())
        }

        let mascot = NSMenuItem(title: "Edit Mascot…", action: #selector(editMascot), keyEquivalent: "m")
        mascot.target = self
        menu.addItem(mascot)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Merlyn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    /// Pin the clicked provider (nil `representedObject` = back to the busiest pick).
    @objc private func pickMenuBarProvider(_ sender: NSMenuItem) {
        engine.updateMenuBarProvider(sender.representedObject as? String)
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

    /// 0xRRGGBB → NSColor, for the gauge's palette accent and Theme's warn/danger.
    static func nsColor(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
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
