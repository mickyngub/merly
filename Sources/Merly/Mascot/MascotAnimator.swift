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
final class MascotAnimator {
    static let shared = MascotAnimator()

    /// Key for the app's own mascot — the one beside the panel title, which is
    /// nobody's provider. Provider critters key on their config id.
    static let appKey = "__app__"

    /// Idle frame column, 0–3. It rests on 0 and runs one loop per burst.
    private(set) var frame = 0

    /// Fires once the column and every flourish have moved, so a subscriber that
    /// reads them back sees the new state. `@Published` fires before the write,
    /// which would leave each critter resting one frame short of the loop's end.
    let ticks = PassthroughSubject<Void, Never>()

    private struct Track {
        var moodRow: Int
        /// A lapsed login is frozen, not idling: it holds frame 0 and never emotes.
        var animates: Bool
        var emoteRow: Int?
        var burstsLeft: Int
    }

    private var tracks: [String: Track] = [:]
    private var timer: Timer?
    private var bursting = false

    /// The critters sit still, then wiggle: one loop of the idle cycle, then rest.
    /// A frame is not cheap up in the menu bar — AppKit re-snapshots the whole item
    /// for every image change, about 28ms of CPU each — so a clock that never
    /// rested cost 10–14% of a core for as long as the screen was on. One loop in
    /// four seconds is a fifth of the frames.
    private static let frameInterval = 0.2
    private static let rest = 3.2

    /// The places a critter can be seen. The clock runs only while one of them is
    /// showing and the screens are awake: a tick nobody can see is that cost for
    /// nothing.
    enum Audience: Hashable { case menuBar, dock, rail }

    private var audiences: Set<Audience> = [.menuBar]
    private var screensAwake = true
    private var sessionActive = true

    /// Reduce Motion is answered here rather than per-view, because a critter drawn
    /// in two places must hold still in both: the menu bar has no SwiftUI
    /// environment to read it from, so a view-level check would have the panel
    /// freezing a track the menu bar kept thawing. Low Power Mode holds them still
    /// the same way: the user has asked the machine to spend less.
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// Rows a flourish may borrow — including wink (6) and curious (7), which
    /// exist for this and nothing else. Sleeping (4) and excited (5) are states,
    /// not flourishes. See docs/specs/sprite-sheet-spec.html.
    private static let emotePool = [0, 1, 2, 3, 6, 7]

    private init() {
        syncClock()

        let workspace = NSWorkspace.shared.notificationCenter
        let power: [(name: Notification.Name, screens: Bool, on: Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true, false),
            (NSWorkspace.screensDidWakeNotification, true, true),
            (NSWorkspace.sessionDidResignActiveNotification, false, false),
            (NSWorkspace.sessionDidBecomeActiveNotification, false, true),
        ]
        for change in power {
            let (screens, on) = (change.screens, change.on)
            workspace.addObserver(forName: change.name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if screens { self?.screensAwake = on } else { self?.sessionActive = on }
                    self?.syncClock()
                }
            }
        }

        workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.syncClock()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.syncClock()
            }
        }
    }

    func setWatching(_ audience: Audience, _ watching: Bool) {
        if watching { audiences.insert(audience) } else { audiences.remove(audience) }
        syncClock()
    }

    private func syncClock() {
        guard screensAwake, sessionActive, !audiences.isEmpty, !reduceMotion, !lowPower else {
            timer?.invalidate()
            timer = nil
            settle()
            return
        }
        guard timer == nil else { return }
        startRest()
    }

    private func schedule(every interval: TimeInterval, tolerance: TimeInterval, repeats: Bool) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] _ in
            MainActor.assumeIsolated { self?.fired() }
        }
        timer.tolerance = tolerance
        // .common so the critter keeps moving while a menu or drag holds the loop.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fired() {
        if bursting { tick() } else { startBurst() }
    }

    private func startRest() {
        bursting = false
        schedule(every: Self.rest, tolerance: 0.3, repeats: false)
    }

    /// Every few bursts a track spends its loop on an off-mood row instead.
    private func startBurst() {
        var emoting = false
        for (key, var track) in tracks where track.animates {
            track.burstsLeft -= 1
            if track.burstsLeft <= 0 {
                track.emoteRow = Self.emotePool.filter { $0 != track.moodRow }.randomElement()
                track.burstsLeft = Self.emoteGap()
                emoting = true
            }
            tracks[key] = track
        }
        bursting = true
        schedule(every: Self.frameInterval, tolerance: 0.02, repeats: true)
        if emoting { ticks.send() }
    }

    private func tick() {
        frame = (frame + 1) % 4
        if frame == 0 {
            clearEmotes()
            startRest()
        }
        ticks.send()
    }

    /// Back to the resting pose, wherever the loop was.
    private func settle() {
        let moved = frame != 0
        frame = 0
        if clearEmotes() || moved { ticks.send() }
    }

    @discardableResult
    private func clearEmotes() -> Bool {
        var cleared = false
        for (key, var track) in tracks where track.emoteRow != nil {
            track.emoteRow = nil
            tracks[key] = track
            cleared = true
        }
        return cleared
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
            track.burstsLeft = Self.emoteGap()
            tracks[key] = track
        } else {
            tracks[key] = Track(moodRow: moodRow, animates: animates,
                                emoteRow: nil, burstsLeft: Self.emoteGap())
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

    /// Bursts between flourishes: one every 8–12s.
    private static func emoteGap() -> Int { Int.random(in: 2...3) }

    deinit {
        // App-lifetime singleton in practice; invalidated for hygiene so a future
        // non-singleton use can't leak the run-loop timer.
        timer?.invalidate()
    }
}
