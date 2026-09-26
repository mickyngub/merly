import XCTest
@testable import Merly

final class UsagePricingTests: XCTestCase {
    func testCacheComponentsArePricedSeparately() throws {
        let value = UsagePricing.estimateUSD(
            kind: .claude,
            model: "claude-opus-5-5",
            input: 1_000_000,
            output: 1_000_000,
            cacheRead: 1_000_000,
            cacheWrite: 1_000_000,
            cacheWrite1h: 500_000
        )

        XCTAssertEqual(try XCTUnwrap(value), 30.7, accuracy: 0.000_001)
    }

    func testVersionSuffixNormalizesButUnknownModelsRemainUnpriced() throws {
        let known = UsagePricing.estimateUSD(
            kind: .claude,
            model: "CLAUDE-OPUS-5-5-20260927 [1M]",
            input: 1_000_000,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0
        )
        let unknown = UsagePricing.estimateUSD(
            kind: .claude,
            model: "claude-opus-5-4",
            input: 1,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0
        )
        let nonterminalDate = UsagePricing.estimateUSD(
            kind: .claude,
            model: "claude-opus-5-5-20260927-preview",
            input: 1,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0
        )
        let hyphenatedDate = UsagePricing.estimateUSD(
            kind: .codex,
            model: "gpt-5.4-2026-03-05",
            input: 1_000_000,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0
        )
        let hyphenatedPreview = UsagePricing.estimateUSD(
            kind: .codex,
            model: "gpt-5.4-2026-03-05-preview",
            input: 1_000_000,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0
        )

        XCTAssertEqual(try XCTUnwrap(known), 4, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(hyphenatedDate), 2.5, accuracy: 0.000_001)
        XCTAssertNil(unknown)
        XCTAssertNil(nonterminalDate)
        XCTAssertNil(hyphenatedPreview)
    }

    func testProviderCannotBorrowAnotherProvidersRates() {
        XCTAssertNil(UsagePricing.estimateUSD(
            kind: .kimi, model: "claude-opus-5-5", input: 1, output: 0,
            cacheRead: 0, cacheWrite: 0
        ))
        XCTAssertNil(UsagePricing.estimateUSD(
            kind: .claude, model: "gpt-6-luna", input: 1, output: 0,
            cacheRead: 0, cacheWrite: 0
        ))
    }

    func testInvalidAndUnsupportedCacheCountsReturnNil() {
        XCTAssertNil(UsagePricing.estimateUSD(
            kind: .claude, model: "claude-opus-5-5", input: -1, output: 0,
            cacheRead: 0, cacheWrite: 0
        ))
        XCTAssertNil(UsagePricing.estimateUSD(
            kind: .claude, model: "claude-opus-5-5", input: 0, output: 0,
            cacheRead: 0, cacheWrite: 1, cacheWrite1h: 2
        ))
        XCTAssertNil(UsagePricing.estimateUSD(
            kind: .codex, model: "gpt-6-sol", input: 0, output: 0,
            cacheRead: 0, cacheWrite: 1, cacheWrite1h: 1
        ))
        XCTAssertNil(UsagePricing.estimateUSD(
            kind: .codex, model: "gpt-5.4", input: 0, output: 0,
            cacheRead: 0, cacheWrite: 1
        ))
        XCTAssertNil(UsagePricing.estimateUSD(
            kind: .codex, model: "gpt-5.3-codex", input: 0, output: 0,
            cacheRead: 0, cacheWrite: 1
        ))
    }

    func testCodexBaseRateValue() throws {
        let value = UsagePricing.estimateUSD(
            kind: .codex,
            model: "gpt-6-luna",
            input: 1_000_000,
            output: 1_000_000,
            cacheRead: 1_000_000,
            cacheWrite: 1_000_000
        )

        XCTAssertEqual(try XCTUnwrap(value), 0.735, accuracy: 0.000_001)
    }

    func testZeroTokenValueAndLargeCountsStayFinite() {
        let zero = UsagePricing.estimateUSD(
            kind: .claude, model: "claude-opus-5-5", input: 0, output: 0,
            cacheRead: 0, cacheWrite: 0
        )
        let large = UsagePricing.estimateUSD(
            kind: .claude, model: "claude-opus-5-5", input: Int.max, output: Int.max,
            cacheRead: Int.max, cacheWrite: Int.max
        )

        XCTAssertEqual(zero, 0)
        XCTAssertNotNil(large)
        XCTAssertTrue(large?.isFinite == true)
    }
}
