import XCTest
@testable import Merly

final class TokenWindowEstimatorTests: XCTestCase {
    /// An hour epoch aligned so the whole test day sits inside one 5h block.
    private let base = 1_700_000_000 - 1_700_000_000 % 86_400

    private func evaluate(
        _ buckets: HourBuckets, now: Date,
        sessionLimit: Int? = nil, weeklyLimit: Int? = nil
    ) -> TokenWindowEstimator.SessionResult {
        TokenWindowEstimator.evaluate(
            buckets: buckets, now: now, sessionHours: 5,
            sessionLimitOverride: sessionLimit, weeklyLimitOverride: weeklyLimit
        )
    }

    func testEmptyBucketsYieldZero() {
        let result = evaluate([:], now: Date())
        XCTAssertEqual(result.pct, 0)
        XCTAssertNil(result.resetAt)
        XCTAssertTrue(result.weekly.isEmpty)
    }

    func testCurrentBlockAgainstConfiguredLimit() {
        // 600 tokens in the block containing `now`, with a fixed 1000 limit → 60%.
        let buckets: HourBuckets = [base: ["all": 600]]
        let now = Date(timeIntervalSince1970: Double(base + 3600))
        let result = evaluate(buckets, now: now, sessionLimit: 1000)
        XCTAssertEqual(result.pct, 60, accuracy: 0.001)
        // The block resets 5h after its floor-to-hour start.
        XCTAssertEqual(result.resetAt, Date(timeIntervalSince1970: Double(base + 5 * 3600)))
    }

    func testAutoCalibratesToBusiestBlock() {
        // A historical block of 2000 sets the denominator; the current block
        // holds 500 → 25%.
        let past = base - 14 * 86_400
        let buckets: HourBuckets = [
            past: ["all": 2000],
            base: ["all": 500],
        ]
        let now = Date(timeIntervalSince1970: Double(base + 3600))
        let result = evaluate(buckets, now: now)
        XCTAssertEqual(result.pct, 25, accuracy: 0.001)
    }

    func testExpiredBlockReportsNoSession() {
        // All activity was 10h before `now` — the 5h block is over.
        let buckets: HourBuckets = [base: ["all": 500]]
        let now = Date(timeIntervalSince1970: Double(base + 10 * 3600))
        let result = evaluate(buckets, now: now)
        XCTAssertEqual(result.pct, 0)
        XCTAssertNil(result.resetAt)
    }

    func testWeeklyRowsCapAndCaption() {
        // Four families + "all" → "All models" plus the first N-1 alphabetically.
        var families: [String: Int] = ["all": 400]
        for family in ["fable", "haiku", "opus", "sonnet"] { families[family] = 100 }
        let buckets: HourBuckets = [base: families]
        let now = Date(timeIntervalSince1970: Double(base + 3600))
        let result = evaluate(buckets, now: now)
        XCTAssertEqual(result.weekly.count, TokenWindowEstimator.maxWeeklyRows)
        XCTAssertEqual(result.weekly.first?.label, "All models")
        // Without an override the caption must say the denominator is relative.
        XCTAssertTrue(result.weekly.allSatisfy { $0.resetText.contains("busiest week") })
    }

    func testWeeklyOverrideChangesCaption() {
        let buckets: HourBuckets = [base: ["all": 500]]
        let now = Date(timeIntervalSince1970: Double(base + 3600))
        let result = evaluate(buckets, now: now, weeklyLimit: 1000)
        XCTAssertEqual(result.weekly.first?.pct ?? 0, 50, accuracy: 0.001)
        XCTAssertFalse(result.weekly.first?.resetText.contains("busiest week") ?? true)
    }

    func testModelFamilyMapping() {
        XCTAssertEqual(TokenWindowEstimator.modelFamily("claude-fable-5"), "fable")
        XCTAssertEqual(TokenWindowEstimator.modelFamily("claude-sonnet-5"), "sonnet")
        XCTAssertEqual(TokenWindowEstimator.modelFamily("claude-opus-5"), "opus")
        XCTAssertEqual(TokenWindowEstimator.modelFamily("claude-haiku-4-5"), "haiku")
        XCTAssertEqual(TokenWindowEstimator.modelFamily("gpt-5.3"), "other")
    }

    func testFileBucketCacheReusesUnchangedEntries() {
        var cache = FileBucketCache()
        let url = URL(fileURLWithPath: "/tmp/fixture.jsonl")
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        var parses = 0
        let parse: (URL) -> HourBuckets = { _ in parses += 1; return [0: ["all": 1]] }

        _ = cache.buckets(for: url, mtime: mtime, size: 10, parse: parse)
        _ = cache.buckets(for: url, mtime: mtime, size: 10, parse: parse)
        XCTAssertEqual(parses, 1, "unchanged (mtime, size) must hit the cache")

        _ = cache.buckets(for: url, mtime: mtime, size: 11, parse: parse)
        XCTAssertEqual(parses, 2, "a size change must re-parse")
    }
}

final class GameStatsTests: XCTestCase {
    func testLevelCurve() {
        XCTAssertEqual(GameStats.level(forBytes: 0), 1)
        XCTAssertEqual(GameStats.level(forBytes: Int(GameStats.baseBytes)), 2)
        // The curve is geometric: bytesToReach is its own inverse via level(forBytes:).
        for level in [5, 12, 20] {
            let bytes = Int(GameStats.bytesToReach(level: level).rounded(.up))
            XCTAssertEqual(GameStats.level(forBytes: bytes), level)
        }
    }

    func testFormThresholds() {
        XCTAssertEqual(GameStats.form(forLevel: 1), 0)
        XCTAssertEqual(GameStats.form(forLevel: 12), 1)
        XCTAssertEqual(GameStats.form(forLevel: 24), 2)
    }

    func testStreakWithGraceDay() {
        let today = 20_000
        XCTAssertEqual(GameStats.streak(activeDays: [today, today - 1, today - 2], today: today), 3)
        // Missing today but active yesterday → the streak survives on grace.
        XCTAssertEqual(GameStats.streak(activeDays: [today - 1, today - 2], today: today), 2)
        // A full missed day breaks it.
        XCTAssertEqual(GameStats.streak(activeDays: [today - 2, today - 3], today: today), 0)
    }
}
