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

    /// Vertical budget for the whole drawn item.
    ///
    /// `NSStatusBar.system.thickness` reports **22 on every Mac**, notch or not — as
    /// does the button's own `bounds.height`. Both measured. But the menu bar this
    /// machine actually has is 33pt, the button is centred in it, and AppKit draws an
    /// over-thickness image without clipping *or* scaling it — also measured, at 24pt.
    ///
    /// So `thickness` is a floor, not a ceiling. Sizing off the **screen's** menu bar
    /// and keeping 4pt of air at each end takes the room the machine actually has (25pt
    /// here, which is what let the mascot go back to its original 15pt *and* the label
    /// up to 6pt), while never dropping below the 22pt contract on a standard display —
    /// where the bar is 24pt and there is genuinely no room to take.
    private var heightBudget: CGFloat {
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        let menuBar = screen.map { $0.frame.height - $0.visibleFrame.maxY } ?? 0
        return min(max(NSStatusBar.system.thickness, menuBar - 8), 28)
    }

    /// Rows the layout *budgets* for — the 5h window and the weekly cap. The mascot is
    /// sized against this maximum rather than against the lanes actually drawn, so a
    /// one-limit provider yields a shorter item but never a differently-sized critter.
    private static let budgetedRows = 2

    /// Mascot size in points: whatever the budget has left once the rows are paid for.
    /// Floored so a surprising budget can't shrink the critter to nothing.
    private var iconPoints: CGFloat {
        let rows = CGFloat(Self.budgetedRows)
        return max(10, heightBudget - (rows * rowHeight + (rows - 1) * rowGap + mascotToRows))
    }

    /// One label+bar row: the label's **cap height** plus a hairline, derived from the
    /// font so the two can't drift. Deliberately *not* the font's line box — "5h" and
    /// "w" have no descenders and no accents, so the ascent and descent a face reserves
    /// for arbitrary text is dead space here, ~2pt per row, which is 4pt of mascot.
    ///
    /// Rows then abut with no gap: the bar is thinner than its row, so 2pt of air still
    /// separates the two bars.
    private var rowHeight: CGFloat {
        max(barHeight + 1.5, ((Self.labelFont.capHeight + 0.8) * 4).rounded() / 4)
    }
    private let rowGap: CGFloat = 0
    private let mascotToRows: CGFloat = 0
    /// The bar in a row, and the air between the label and it. The bar does *not*
    /// shrink with the type — it's the reading, and it already has the least weight of
    /// anything in the item.
    private let barHeight: CGFloat = 2.5
    private let barWidth: CGFloat = 15
    private let labelToBar: CGFloat = 2
    /// Tracking. Small type sets too tight by default — the metrics assume a size where
    /// the sidebearings are already several pixels — and "5h" ran into one glyph.
    private let labelKern: CGFloat = 0.15
    /// The row label at 6pt (cap height 4.2). Sized up from 5pt once the real menu bar
    /// turned out to be 33pt rather than the 22pt `thickness` claims: 5pt was under the
    /// floor for reading arbitrary text and only worked because "5h" and "w" are two
    /// fixed, pre-learned strings recognised by silhouette. 6pt is legible outright.
    ///
    /// Rounded rather than the default design because at this size the rounded face's
    /// open counters survive where the default's close up. **Bold, not heavy** — heavy
    /// closed the bowl of the "5" into a blob, costing more legibility than the extra
    /// stem weight bought.
    private static let labelFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 6, weight: .bold)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: 6) ?? base
    }()
    /// The reported provider's look and gauges, captured for the animation clock.
    private var current: (
        sprite: String?, style: MascotStyle, palette: MascotPalette, mood: Mood,
        /// Identity on the shared clock — the provider's config id, so this critter
        /// idles and flourishes in step with its own card in the panel.
        key: String,
        /// The 5h window and the weekly cap, in that order — see `iconGauges`. Each
        /// lane carries the card's colour for that limit, not this account's mascot
        /// hue, so a window is the same hue here as in the panel.
        gauges: [IconGauge],
        failure: ProviderFailure?
    )?

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

        // Same clock the panel's mascots read, so the critter up here and the one
        // on its card are on the same frame and the same flourish.
        MascotAnimator.shared.$frame
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.renderFrame() } }
            .store(in: &cancellables)
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
        let sprite: String?
        let style: MascotStyle
        let palette: MascotPalette
        let mood: Mood
        if let reported {
            sprite = reported.resolvedSpriteForm
            style = reported.config.resolvedStyle
            palette = reported.config.resolvedPalette
            mood = reported.mood
        } else {
            let mascot = config.defaultMascotConfig
            sprite = SpriteSheetStore.formSprite(base: mascot.resolvedSprite, form: 0)
            style = mascot.style
            palette = mascot.resolvedPalette
            // A provider's own critter may look dead — that's information. The
            // app's mascot is the app itself, so it stays happy with no provider.
            mood = .happy
        }

        // Keyed on the provider so the panel card for the same account shares this
        // critter's flourishes; the app's mascot has its own key for when there is
        // no provider to wear.
        let key = reported?.id ?? MascotAnimator.appKey
        MascotAnimator.shared.register(key, moodRow: mood.spriteRow, animates: mood != .dead)
        current = (sprite, style, palette, mood, key,
                   reported?.iconGauges ?? [], reported?.failure)
        let tooltip = Self.tooltip(for: reported, pinned: config.menuBarProviderId != nil)
        button.toolTip = tooltip
        // The tooltip already narrates the whole reading; give VoiceOver the same.
        button.setAccessibilityLabel(tooltip)
        renderFrame()
    }

    /// The figure the gauge can't spell out. The wording lives on the snapshot
    /// (`gaugeTooltip`) because the collapsed rail draws the same bar and must say
    /// the same thing; only the "which provider" clause is the menu bar's own.
    private static func tooltip(for snapshot: ProviderSnapshot?, pinned: Bool) -> String {
        guard let snapshot else { return "Merlyn — no providers configured" }
        return snapshot.gaugeTooltip(qualifier: pinned ? "" : " (busiest provider)")
    }

    /// Draw the item at the shared clock's current frame: the mood row, or the
    /// brief off-mood flourish playing over it (see `MascotAnimator`).
    private func renderFrame() {
        guard let button = statusItem.button, let cur = current else { return }
        let animator = MascotAnimator.shared
        let row = animator.emote(for: cur.key) ?? cur.mood.spriteRow
        let mascot: NSImage
        if let name = cur.sprite,
           let cg = SpriteSheetStore.recoloredFrame(
               name: name, row: row, col: animator.column(for: cur.key), accentHex: cur.palette.B
           ) {
            mascot = NSImage(cgImage: cg, size: NSSize(width: iconPoints, height: iconPoints))
            mascot.isTemplate = false
        } else {
            mascot = Self.spriteImage(style: cur.style, palette: cur.palette,
                                      mood: Mood.fromRow(row), points: iconPoints - 2)
        }
        button.image = withGauge(mascot, gauges: cur.gauges, failure: cur.failure)
    }

    /// Mascot on top, with **one named row per limit stacked underneath** — `5h` then
    /// `w`, each a small label with its gauge bar running off to the right.
    ///
    /// Three things had to hold at once and this is the only arrangement that does.
    /// The lane must be **named**, because colour alone distinguishes two bars from
    /// each other without identifying either — "which one is the week" was a hover
    /// away. The rows must sit **under** the mascot, because that keeps the item about
    /// as wide as the critter; putting a label and bar side by side per row and
    /// stacking those beside the mascot ran to ~49pt. And the reading must stay a
    /// **bar**, not a number, because a bar answers "how close am I" without being
    /// read.
    ///
    /// What pays for it is the mascot: 10pt, down from 15. Two glyph-height rows plus
    /// their gaps take 11.5 of the menu bar's measured 22pt and there is nowhere else
    /// to find it.
    ///
    /// The label is drawn in `labelColor` and the track in `tertiaryLabelColor` —
    /// AppKit's own adaptive inks, the only ones guaranteed to read on both a light
    /// and a dark menu bar. Colour is spent where it means something: the fill, in the
    /// limit's own hue, matching that limit's lane on the card.
    ///
    /// Top-to-bottom is shortest window first, matching the card's shortest-innermost
    /// ring. A provider with one limit draws one row; the mascot never changes size,
    /// so switching the pinned provider doesn't resize the critter.
    ///
    /// **A failure draws no row at all** — no label, no bar, no track. A gauge-shaped
    /// anything is read as a level, so a disconnected provider showed what looked like
    /// a measurement of nothing. It gets a badged exclamation on the mascot's shoulder
    /// instead: unmistakably a state, not a quantity.
    private func withGauge(
        _ mascot: NSImage, gauges: [IconGauge], failure: ProviderFailure?
    ) -> NSImage {
        // Copied out of self: the drawing handler runs again on every redraw, at
        // whatever scale and on whatever thread AppKit picks, so it must not reach
        // back into a main-actor object.
        let icon = iconPoints
        let rowH = rowHeight
        let rowSpace = rowGap
        let gap = mascotToRows
        let barH = barHeight
        let barW = barWidth
        let labelGap = labelToBar

        if let failure {
            let tint = Self.nsColor(hex: failure.isFault ? Theme.dangerHex : Theme.warnHex)
            // Sized off the mascot rather than fixed at 8pt: the critter shrank to
            // 10pt to make room for the label rows, and a fixed badge would have taken
            // four fifths of its width.
            let badge = (icon * 0.62).rounded()
            let k = badge / 8 // the hand-drawn glyph below was struck for an 8pt badge
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
                // A stem over a dot: an exclamation mark, hand-drawn because an SF
                // Symbol glyph is mush at this size. Struck for an 8pt badge and
                // scaled by `k` so it stays centred at any badge size.
                NSColor.white.setFill()
                let cx = box.midX
                NSBezierPath(rect: NSRect(x: cx - 0.75 * k, y: box.minY + 3.2 * k,
                                          width: 1.5 * k, height: 3 * k)).fill()
                NSBezierPath(ovalIn: NSRect(x: cx - 0.75 * k, y: box.minY + 1.4 * k,
                                            width: 1.5 * k, height: 1.5 * k)).fill()
                return true
            }
            image.isTemplate = false
            return image
        }

        guard !gauges.isEmpty else { return mascot }
        let font = Self.labelFont
        let kern = labelKern
        func attributed(_ label: String) -> NSAttributedString {
            NSAttributedString(string: label, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .kern: kern,
            ])
        }
        // One label column wide enough for the widest label, so every bar starts at
        // the same x — two bars you can't line up can't be compared at a glance.
        let labels = gauges.map { attributed($0.label) }
        let labelWidths = labels.map { ($0.size().width - kern).rounded(.up) } // trailing kern isn't ink
        let labelW = labelWidths.max() ?? 0
        let rows = CGFloat(gauges.count)
        let block = rows * rowH + (rows - 1) * rowSpace
        let size = NSSize(width: max(icon, labelW + labelGap + barW), height: icon + gap + block)
        let image = NSImage(size: size, flipped: false) { _ in
            // Origin is bottom-left: the row block sits at y = 0, the mascot above it,
            // centred over the rows so it reads as their subject.
            mascot.draw(in: NSRect(x: (size.width - icon) / 2, y: block + gap,
                                   width: icon, height: icon))
            for (index, lane) in gauges.enumerated() {
                // Index 0 is the shortest window and draws topmost.
                let bottom = block - CGFloat(index + 1) * rowH - CGFloat(index) * rowSpace
                let row = NSRect(x: 0, y: bottom, width: size.width, height: rowH)

                // Labels are **right**-aligned in their column, not left. Left-aligned,
                // the one-glyph "w" floated a couple of points clear of its own bar
                // while "5h" touched its own — the label read as belonging to the
                // column rather than to the bar beside it.
                //
                // Vertically, centred on cap height rather than on the line box: the
                // line box's ascent and descent are reserved for accents and
                // descenders these two strings don't have, so box-centring sat the
                // glyph visibly high of the bar it labels.
                let baseline = row.midY - font.capHeight / 2 + font.descender
                labels[index].draw(at: NSPoint(x: labelW - labelWidths[index], y: baseline))

                let barX = labelW + labelGap
                let barY = row.midY - barH / 2
                let radius = barH / 2
                // An adaptive neutral, not a tint of the lane: the backdrop here is
                // the user's wallpaper, and a pale lane colour at low alpha vanishes
                // against a light menu bar. Colour is spent on the fill, where it
                // carries which limit this is.
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: barW, height: barH),
                             xRadius: radius, yRadius: radius).fill()

                let fraction = min(max(lane.pct / 100, 0), 1)
                guard fraction > 0 else { continue }
                // Same escalation as `Theme.limitColor`, hand-rolled because the fill
                // is an NSColor: the limit's own colour, red only once it's about to
                // block. No amber band — that made a 70% week amber here and lime on
                // the card.
                let fillHex = lane.pct >= Theme.dangerPct ? Theme.dangerHex : lane.colorHex
                Self.nsColor(hex: fillHex).setFill()
                // Never narrower than the bar is tall, so a live 1% still reads as a
                // fill rather than a rendering artefact.
                NSBezierPath(roundedRect: NSRect(x: barX, y: barY,
                                                 width: max(barH, barW * fraction), height: barH),
                             xRadius: radius, yRadius: radius).fill()
            }
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
        palette.hex(for: ch).map(nsColor(hex:))
    }
}
