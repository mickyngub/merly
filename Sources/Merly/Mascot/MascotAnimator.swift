// MascotAnimator.swift — one clock for every critter on screen, so a provider's
// mascot reads the same in the menu bar as it does on its card.

import AppKit
import Combine
import Foundation

/// The shared idle-animation clock.
///
/// Every mascot used to keep its own: the menu bar ran a `Timer` and each
/// `MascotView` ran a `.task` loop, both at 200ms but each started whenever its
/// owner appeared — and only the menu bar ever played the off-mood *emote* rows.
/// So one account's critter could wear a wink up top and a flat happy face on
/// its card at the same moment. Two animations for one provider reads as two
/// different critters, which is exactly what the mascot exists not to be.
///
/// This owns both halves instead. The idle **column** is global — one phase for
/// everything on screen — while the **emote** is tracked per key, so a provider
/// still flourishes off *its own* status (never borrowing the row it is already
/// wearing) and every surface drawing that key shows the same row on the same
/// tick. Untracked mascots (editor and picker previews, which are keyless) just
/// ride the column: a preview of a chosen mood shouldn't wander off it.
@MainActor
final class MascotAnimator: ObservableObject {
    static let shared = MascotAnimator()

    /// Key for the app's own mascot — the one beside the panel title, which is
    /// nobody's provider. Provider critters key on their config id.
    static let appKey = "__app__"

    /// Idle frame column, 0–3, advancing at ~5fps. Published so every mascot
    /// redraws on the same tick.
    @Published private(set) var frame = 0

    private struct Track {
        var moodRow: Int
        /// A lapsed login is frozen, not idling: it holds frame 0 and never emotes.
        var animates: Bool
        var emoteRow: Int?
        var ticksLeft: Int
    }

    private var tracks: [String: Track] = [:]
    private var timer: Timer?

    /// Reduce Motion is answered here rather than per-view, because a critter drawn
    /// in two places must hold still in both: the menu bar has no SwiftUI
    /// environment to read it from, so a view-level check would have the panel
    /// freezing a track the menu bar kept thawing.
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Rows a flourish may borrow — including wink (6) and curious (7), which
    /// exist for this and nothing else. Sleeping (4) and excited (5) are states,
    /// not flourishes. See docs/specs/sprite-sheet-spec.html.
    private static let emotePool = [0, 1, 2, 3, 6, 7]

    private init() {
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common so the critter keeps moving while a menu or drag holds the loop.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if self.reduceMotion {
                    self.frame = 0
                    for (key, var track) in self.tracks {
                        track.emoteRow = nil
                        self.tracks[key] = track
                    }
                }
            }
        }
    }

    /// Tell the clock what mood this key is in. Idempotent and cheap — call it on
    /// appearance and on every refresh. A changed mood drops the flourish in
    /// flight: real data beats a wink.
    func register(_ key: String, moodRow: Int, animates: Bool) {
        if var track = tracks[key] {
            guard track.moodRow != moodRow || track.animates != animates else { return }
            track.moodRow = moodRow
            track.animates = animates
            track.emoteRow = nil
            track.ticksLeft = Self.emoteDelay()
            tracks[key] = track
        } else {
            tracks[key] = Track(moodRow: moodRow, animates: animates,
                                emoteRow: nil, ticksLeft: Self.emoteDelay())
        }
    }

    /// The flourish row playing over this key's mood right now, if any. Callers
    /// fall back to their own mood row, so a mascot draws correctly on its very
    /// first frame — before it has registered — and a keyless preview never
    /// leaves the mood it was asked to show.
    func emote(for key: String?) -> Int? {
        key.flatMap { tracks[$0]?.emoteRow }
    }

    /// The column this key draws right now — the global phase, unless the key is
    /// frozen.
    func column(for key: String?) -> Int {
        let animates = key.flatMap { tracks[$0]?.animates } ?? true
        return animates ? frame : 0
    }

    /// One tick: advance the idle column, then age every track's flourish —
    /// ~0.8–1.6s of an off-mood row every ~5–12s.
    private func tick() {
        guard !reduceMotion else { return }
        frame = (frame + 1) % 4
        for (key, var track) in tracks {
            guard track.animates else { continue }
            track.ticksLeft -= 1
            if track.ticksLeft <= 0 {
                if track.emoteRow != nil {
                    track.emoteRow = nil
                    track.ticksLeft = Self.emoteDelay()
                } else {
                    track.emoteRow = Self.emotePool.filter { $0 != track.moodRow }.randomElement()
                    track.ticksLeft = Int.random(in: 4...8)
                }
            }
            tracks[key] = track
        }
    }

    /// Ticks between flourishes: 5–12s.
    private static func emoteDelay() -> Int { Int.random(in: 25...60) }

    deinit {
        // App-lifetime singleton in practice; invalidated for hygiene so a future
        // non-singleton use can't leak the run-loop timer.
        timer?.invalidate()
    }
}
