// GameStats.swift — derived, *stateless* idle-game stats for a provider's mascot.
//
// Everything here is a pure function of the provider's on-disk log metadata
// (total bytes + active calendar days), recomputed each refresh. Nothing is
// persisted: lifetime usage *is* the save file — the CLI logs only ever grow,
// so the level is monotonic without us storing a thing. The only honest cost is
// that pruning the logs can de-level a pet; that's the accepted trade for "no
// stored state" (a single high-water int per provider would fix it if ever
// wanted). See `computeGameStats` in Readers.swift for the metadata sweep.

import Foundation

struct GameStats: Equatable {
    var lifetimeBytes: Int
    var level: Int          // >= 1
    var xpInLevel: Double   // 0...1 toward the next level (drives the XP bar)
    var bytesToNext: Int    // remaining bytes to the next level (caption)
    var streakDays: Int     // consecutive active days ending today / yesterday
    var form: Int           // evolution stage: 0 base, 1 evo2, 2 evo3

    // MARK: - Tunables
    //
    // Calibrated against measured log volumes (Codex 3.1G, Claude 1.1G, Kimi
    // 84M → ~Lv 19 / 16 / 11). Byte volumes span orders of magnitude across
    // providers, so the curve is *geometric*, not linear — a linear curve would
    // peg the heavy providers at max and strand the light one forever.

    /// Bytes to reach level 2 (B0). Each subsequent level needs `growth`× more.
    static let baseBytes = 1_048_576.0      // 1 MiB
    static let growth = 1.6                  // +60% per level
    /// Level at which each evolution form unlocks: ≥12 → evo2, ≥24 → evo3.
    static let formThresholds = [12, 24]

    /// Bytes required to *reach* `level`. Level 1 is the floor (0 bytes).
    static func bytesToReach(level: Int) -> Double {
        level <= 1 ? 0 : baseBytes * pow(growth, Double(level - 2))
    }

    static func level(forBytes bytes: Int) -> Int {
        guard Double(bytes) >= baseBytes else { return 1 }
        return Int((log(Double(bytes) / baseBytes) / log(growth)).rounded(.down)) + 2
    }

    static func form(forLevel level: Int) -> Int {
        formThresholds.reduce(0) { $0 + (level >= $1 ? 1 : 0) }
    }

    /// Consecutive active days ending at `today`, with a one-day grace so the
    /// streak doesn't visibly break until a whole day is missed.
    static func streak(activeDays days: Set<Int>, today: Int) -> Int {
        let start: Int
        if days.contains(today) { start = today }
        else if days.contains(today - 1) { start = today - 1 }   // grace
        else { return 0 }
        var day = start, count = 0
        while days.contains(day) { count += 1; day -= 1 }
        return count
    }

    /// The user's local-calendar day index for a date (days since the epoch in
    /// the current time zone) — so a "🔥 N-day streak" counts the days the user
    /// actually lived, not UTC days.
    static func dayIndex(_ date: Date) -> Int {
        let shifted = date.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: date))
        return Int((shifted / 86_400).rounded(.down))
    }

    /// Assemble the full block from a lifetime byte total and the set of active
    /// local-day indices.
    static func make(lifetimeBytes bytes: Int, activeDays: Set<Int>, today: Int) -> GameStats {
        let lvl = level(forBytes: bytes)
        let lo = bytesToReach(level: lvl)
        let hi = bytesToReach(level: lvl + 1)
        let xp = hi > lo ? min(1, max(0, (Double(bytes) - lo) / (hi - lo))) : 0
        return GameStats(
            lifetimeBytes: bytes,
            level: lvl,
            xpInLevel: xp,
            bytesToNext: max(0, Int(hi.rounded()) - bytes),
            streakDays: streak(activeDays: activeDays, today: today),
            form: form(forLevel: lvl)
        )
    }
}
