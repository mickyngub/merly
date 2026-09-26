import Foundation

enum UsagePricing {
    static let verifiedDate = "2026-09-27"

    private struct Rates {
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite5m: Double?
        var cacheWrite1h: Double?
    }

    // Standard base-rate API equivalents verified 2026-09-27, not billed spend.
    private static let rates: [ProviderKind: [String: Rates]] = [
        .claude: [
            "claude-fable-5-1": Rates(input: 10, output: 50, cacheRead: 0.25, cacheWrite5m: 12.5, cacheWrite1h: 20),
            "claude-mythos-5-1": Rates(input: 10, output: 50, cacheRead: 0.25, cacheWrite5m: 12.5, cacheWrite1h: 20),
            "claude-fable-5": Rates(input: 10, output: 50, cacheRead: 1, cacheWrite5m: 12.5, cacheWrite1h: 20),
            "claude-mythos-5": Rates(input: 10, output: 50, cacheRead: 1, cacheWrite5m: 12.5, cacheWrite1h: 20),
            "claude-opus-5-5": Rates(input: 4, output: 20, cacheRead: 0.2, cacheWrite5m: 5, cacheWrite1h: 8),
            "claude-opus-5": Rates(input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10),
            "claude-opus-4-8": Rates(input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10),
            "claude-opus-4-7": Rates(input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10),
            "claude-opus-4-6": Rates(input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10),
            "claude-opus-4-5": Rates(input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10),
            "claude-sonnet-5": Rates(input: 2, output: 10, cacheRead: 0.2, cacheWrite5m: 2.5, cacheWrite1h: 4),
            "claude-sonnet-4-6": Rates(input: 3, output: 15, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6),
            "claude-sonnet-4-5": Rates(input: 3, output: 15, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6),
            "claude-sonnet-4": Rates(input: 3, output: 15, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6),
            "claude-haiku-4-5": Rates(input: 1, output: 5, cacheRead: 0.1, cacheWrite5m: 1.25, cacheWrite1h: 2),
        ],
        .codex: [
            "gpt-6-astra": Rates(input: 10, output: 50, cacheRead: 1, cacheWrite5m: 12.5, cacheWrite1h: nil),
            "gpt-6-sol": Rates(input: 2, output: 10, cacheRead: 0.2, cacheWrite5m: 2.5, cacheWrite1h: nil),
            "gpt-6-luna": Rates(input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite5m: 0.125, cacheWrite1h: nil),
            "gpt-5.6-sol": Rates(input: 4, output: 20, cacheRead: 0.4, cacheWrite5m: 5, cacheWrite1h: nil),
            "gpt-5.6": Rates(input: 4, output: 20, cacheRead: 0.4, cacheWrite5m: 5, cacheWrite1h: nil),
            "gpt-5.4": Rates(input: 2.5, output: 15, cacheRead: 0.25, cacheWrite5m: nil, cacheWrite1h: nil),
            "gpt-5.3-codex": Rates(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite5m: nil, cacheWrite1h: nil),
        ],
        .kimi: [:]
    ]

    static func estimateUSD(
        kind: ProviderKind,
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        cacheWrite1h: Int = 0
    ) -> Double? {
        guard input >= 0, output >= 0, cacheRead >= 0,
              cacheWrite >= 0, cacheWrite1h >= 0, cacheWrite1h <= cacheWrite,
              let modelRates = rates[kind],
              let model = modelRates[normalizedModel(model)]
        else { return nil }

        let cacheWrite1hTokens = Double(cacheWrite1h)
        let cacheWrite5mTokens = Double(cacheWrite) - cacheWrite1hTokens
        let cacheWrite5mRate: Double
        if cacheWrite5mTokens > 0 {
            guard let rate = model.cacheWrite5m else { return nil }
            cacheWrite5mRate = rate
        } else {
            cacheWrite5mRate = 0
        }

        let cacheWrite1hRate: Double
        if cacheWrite1hTokens > 0 {
            guard let rate = model.cacheWrite1h else { return nil }
            cacheWrite1hRate = rate
        } else {
            cacheWrite1hRate = 0
        }

        return (
            Double(input) * model.input
                + Double(output) * model.output
                + Double(cacheRead) * model.cacheRead
                + cacheWrite5mTokens * cacheWrite5mRate
                + cacheWrite1hTokens * cacheWrite1hRate
        ) / 1_000_000
    }

    static func sourceURL(for kind: ProviderKind) -> URL {
        switch kind {
        case .claude:
            URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!
        case .codex:
            URL(string: "https://developers.openai.com/api/docs/pricing")!
        case .kimi:
            URL(string: "https://platform.kimi.ai/docs/pricing/chat")!
        }
    }

    private static func normalizedModel(_ model: String) -> String {
        var value = model.lowercased()
        if value.hasSuffix("[1m]") {
            value.removeLast(4)
            while value.last?.isWhitespace == true { value.removeLast() }
        }

        if hasHyphenatedDateSuffix(value) {
            value.removeLast(11)
            return value
        }

        guard value.count >= 9 else { return value }
        let versionStart = value.index(value.endIndex, offsetBy: -8)
        let hyphen = value.index(before: versionStart)
        let version = value[versionStart...]
        guard value[hyphen] == "-", version.utf8.count == 8,
              version.utf8.allSatisfy({ (48...57).contains($0) })
        else { return value }
        value.removeSubrange(hyphen...)
        return value
    }

    private static func hasHyphenatedDateSuffix(_ value: String) -> Bool {
        let suffix = Array(value.suffix(11).utf8)
        guard suffix.count == 11,
              suffix[0] == 45, suffix[5] == 45, suffix[8] == 45
        else { return false }
        return suffix[1...4].allSatisfy(isASCIIDigit)
            && suffix[6...7].allSatisfy(isASCIIDigit)
            && suffix[9...10].allSatisfy(isASCIIDigit)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }
}
