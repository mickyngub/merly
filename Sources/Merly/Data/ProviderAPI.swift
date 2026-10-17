// ProviderAPI.swift — real, provider-reported rate limits.
//
//  claude — Claude Code stores OAuth creds in the macOS Keychain (service
//           "Claude Code-credentials", or "…-<sha256(configDir)[:8]>" for a
//           custom CLAUDE_CONFIG_DIR). GET api.anthropic.com/api/oauth/usage
//           returns five_hour / seven_day / seven_day_<model> utilization.
//  codex  — ~/.codex/auth.json holds a ChatGPT OAuth token. GET
//           chatgpt.com/backend-api/wham/usage returns primary (5h) and
//           secondary (weekly) windows plus per-model additional limits.
//  kimi   — ~/.kimi-code/credentials/kimi-code.json holds a 15-minute access
//           token + refresh token. We refresh exactly like the CLI does
//           (flock on oauth/kimi-code, POST auth.kimi.com/api/oauth/token,
//           persist rotated creds), then GET api.kimi.com/coding/v1/usages.
//
// Every fetch here can fail (expired login, offline, schema drift) — readers
// fall back to local token-count estimation.

import Foundation
import CryptoKit
import Security

enum ProviderAPIError: Error, CustomStringConvertible {
    case noCredentials(String)
    case expiredToken(String)
    case http(Int)
    case network(String)
    case parse(String)
    /// The server answered with a quota/balance refusal in the body: a lapsed
    /// subscription or spent credits. Kimi sends this as a 429, which the plain
    /// status code would misread as "try again in a few minutes".
    case quotaExhausted(String)

    var description: String {
        switch self {
        case .noCredentials(let what): "no credentials (\(what))"
        case .expiredToken(let what): "login expired (\(what))"
        case .http(let code): "HTTP \(code)"
        case .network(let msg): "network: \(msg)"
        case .parse(let what): "unexpected response (\(what))"
        case .quotaExhausted(let msg): "no quota (\(msg))"
        }
    }

    /// The login is gone, not merely unreachable: the token expired, the server
    /// rejected it (401), or there are no credentials at all. Readers whose only
    /// fallback is a misleading local estimate surface "No data" for these
    /// instead of guessing.
    var isAuthLapse: Bool {
        switch self {
        case .expiredToken, .noCredentials: true
        case .http(401): true
        default: false
        }
    }

    /// The credentials exist but the access token went stale. For providers we
    /// never refresh ourselves (Claude, Codex), the CLI still holds a live
    /// refresh token, so recovery is just *activity* — running any command
    /// silently refreshes it — not a full re-login. Distinguished from
    /// `noCredentials`, where the login is truly gone and a sign-in is required.
    var isExpiredLogin: Bool {
        switch self {
        case .expiredToken: true
        case .http(401): true
        default: false
        }
    }

    /// The server answered and refused: 403 when a subscription lapses or an org
    /// disables usage access, 402 unpaid, 404 no such resource. Neither a retry
    /// nor a fresh sign-in changes it, so there is genuinely no quota to read —
    /// and no honest way to stand a local estimate in for one.
    ///
    /// Deliberately *only* those three codes. Other 4xx (a 400 from request or
    /// schema drift, say) would be a bug on our side, not a refused account —
    /// classifying it here would permanently brand a healthy subscription "no
    /// usage access". Unlisted codes fall through to the cached/estimate path.
    var isAccessDenied: Bool {
        switch self {
        case .quotaExhausted: return true
        case .http(let code): return [402, 403, 404].contains(code)
        default: return false
        }
    }

    /// The server couldn't be reached or is erroring out — offline, DNS failure,
    /// timeout, or a 5xx — as opposed to an auth lapse (where the server answered
    /// and rejected our token). Estimate-only readers surface the same "No data"/
    /// dead state for these once no fresh real reading remains, rather than a
    /// fabricated "vs your busiest week" guess that reads as live usage.
    var isServerUnreachable: Bool {
        switch self {
        case .network: true
        case .http(let code): code >= 500
        default: false
        }
    }

    /// The endpoint answered with 429 — it's rate-limiting us (often because the
    /// account is concurrently in use by the provider's own CLI). Drives the
    /// "rate-limited" note so a stale card explains itself.
    var isRateLimited: Bool {
        if case .http(429) = self { return true }
        return false
    }
}

extension Error {
    var isAuthLapse: Bool { (self as? ProviderAPIError)?.isAuthLapse ?? false }
    var isExpiredLogin: Bool { (self as? ProviderAPIError)?.isExpiredLogin ?? false }
    var isAccessDenied: Bool { (self as? ProviderAPIError)?.isAccessDenied ?? false }
    var isServerUnreachable: Bool { (self as? ProviderAPIError)?.isServerUnreachable ?? false }
    var isRateLimited: Bool { (self as? ProviderAPIError)?.isRateLimited ?? false }
}

// MARK: - small sync HTTP helper (always called off the main thread)

enum HTTP {
    /// Per-request timeout. Providers are fetched sequentially on one work queue,
    /// so this bounds the worst refresh pass at (providers × timeout) when every
    /// endpoint is unreachable — 10s keeps four dead providers under the default
    /// 60s refresh interval, and a healthy endpoint answers in well under it.
    static let timeout: TimeInterval = 10

    /// `classifyFailure` lets a provider read the error *body* of a non-2xx reply
    /// before it collapses to a bare status code; return nil to keep `.http(status)`.
    static func request(
        _ url: URL, method: String = "GET",
        headers: [String: String] = [:], formBody: [String: String]? = nil,
        classifyFailure: ((Int, Data) -> ProviderAPIError?)? = nil
    ) throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if let formBody {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = formBody
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
                .joined(separator: "&")
                .data(using: .utf8)
        }

        let semaphore = DispatchSemaphore(value: 0)
        // Safe without a lock: written exactly once by the completion handler,
        // and the semaphore orders that write before the read below. The default
        // covers the impossible no-callback case rather than force-unwrapping.
        nonisolated(unsafe) var result: Result<(Data, Int), Error> =
            .failure(ProviderAPIError.network("no response"))
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()

        switch result {
        case .failure(let error):
            throw ProviderAPIError.network(error.localizedDescription)
        case .success(let (data, status)):
            guard (200..<300).contains(status) else {
                if let classified = classifyFailure?(status, data) { throw classified }
                throw ProviderAPIError.http(status)
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProviderAPIError.parse("not a JSON object")
            }
            return obj
        }
    }
}

// Cached because ISO8601DateFormatter is expensive to build and thread-safe to
// share; parseAPIDate runs for every window of every provider each refresh.
private let fractionalISOParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let plainISOParser = ISO8601DateFormatter()

/// Parses API dates: ISO 8601 with any fractional precision, or epoch seconds.
func parseAPIDate(_ value: Any?) -> Date? {
    if let n = value as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
    guard var s = value as? String, !s.isEmpty else { return nil }
    // ISO8601DateFormatter only accepts millisecond fractions — trim longer ones
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
        s = s.replacingCharacters(in: r, with: String(s[r].prefix(4)))
    }
    return fractionalISOParser.date(from: s) ?? plainISOParser.date(from: s)
}

/// Reads numbers that providers serialize as Int, Double, or String.
func flexDouble(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
}

struct UsageWindow {
    var usedPct: Double
    var resetsAt: Date?
    /// How long this window spans, when the provider says. Never assume: Codex
    /// moved its primary window from 5h to 7 days, and every label derived from
    /// the old assumption ("5h limit · resets in 3d 18h") became a lie.
    var windowSeconds: Double?
}

// MARK: - Claude

enum ClaudeUsageAPI {
    static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    struct Usage {
        var fiveHour: UsageWindow?
        var sevenDay: UsageWindow?
        var sevenDayModels: [(label: String, window: UsageWindow)] = []
        var planLabel: String?
    }

    static func keychainService(forConfigDir dir: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if dir == home + "/.claude" { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(dir.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "Claude Code-credentials-\(suffix)"
    }

    /// Reads the credential JSON via /usr/bin/security rather than
    /// SecItemCopyMatching: the keychain ACL prompt then attaches to the
    /// stable `security` binary instead of our ad-hoc-signed one, so a single
    /// "Always Allow" survives rebuilds (and on most Claude Code installs the
    /// tool is already authorized).
    static func readKeychain(service: String) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return Data(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }

    static func fetch(configDir: String) throws -> Usage {
        let service = keychainService(forConfigDir: configDir)
        guard let data = readKeychain(service: service),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ProviderAPIError.noCredentials("keychain \(service)") }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = oauth["accessToken"] as? String else {
            throw ProviderAPIError.noCredentials("keychain \(service)")
        }

        if let expiresAt = flexDouble(oauth["expiresAt"]), expiresAt / 1000 < Date().timeIntervalSince1970 + 30 {
            throw ProviderAPIError.expiredToken("run any claude command to re-auth")
        }

        let obj = try HTTP.request(
            usageEndpoint,
            headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
            ]
        )

        // Claude names its windows in the key itself, so the span is implied rather
        // than reported; state it explicitly so nothing downstream has to assume.
        func window(_ key: String, seconds: Double?) -> UsageWindow? {
            guard let w = obj[key] as? [String: Any],
                  let pct = flexDouble(w["utilization"]) else { return nil }
            return UsageWindow(usedPct: pct, resetsAt: parseAPIDate(w["resets_at"]),
                               windowSeconds: seconds)
        }

        var usage = Usage(fiveHour: window("five_hour", seconds: 5 * 3600),
                          sevenDay: window("seven_day", seconds: 7 * 86400))

        // Per-model weekly caps (Fable, and now Sonnet/Opus too) arrive in a
        // unified `limits[]` array, each labeled by the model's display name; the
        // old top-level `seven_day_<model>` keys are going null. Prefer the array;
        // fall back to the legacy keys for CLIs still on the old response shape.
        let scoped = (obj["limits"] as? [[String: Any]] ?? [])
            .filter { ($0["kind"] as? String) == "weekly_scoped" }
        if !scoped.isEmpty {
            for item in scoped {
                guard let pct = flexDouble(item["percent"]),
                      let name = ((item["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                else { continue }
                let w = UsageWindow(usedPct: pct, resetsAt: parseAPIDate(item["resets_at"]),
                                    windowSeconds: 7 * 86400)
                usage.sevenDayModels.append(("\(name) only", w))
            }
        } else {
            for (key, label) in [("seven_day_sonnet", "Sonnet only"), ("seven_day_opus", "Opus only")] {
                if let w = window(key, seconds: 7 * 86400), w.usedPct > 0 || w.resetsAt != nil {
                    usage.sevenDayModels.append((label, w))
                }
            }
        }
        usage.planLabel = planLabel(
            subscription: oauth["subscriptionType"] as? String,
            tier: oauth["rateLimitTier"] as? String
        )
        return usage
    }

    /// Plan label straight from the keychain, no usage call — so the card keeps
    /// its "Max (20x)" / "Free" pill even when the usage endpoint 429s or is down.
    static func planLabel(configDir: String) -> String? {
        guard let data = readKeychain(service: keychainService(forConfigDir: configDir)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        return planLabel(
            subscription: oauth["subscriptionType"] as? String,
            tier: oauth["rateLimitTier"] as? String
        )
    }

    /// "max" + "default_claude_max_20x" → "Max (20x)"
    static func planLabel(subscription: String?, tier: String?) -> String? {
        guard let subscription else { return nil }
        var label = subscription.capitalized
        if let tier, let r = tier.range(of: #"(\d+)x$"#, options: .regularExpression) {
            label += " (\(tier[r]))"
        }
        return label
    }
}

// MARK: - Codex

enum CodexUsageAPI {
    static let usageEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    struct Usage {
        var primary: UsageWindow?
        var secondary: UsageWindow?
        var additional: [(name: String, fiveHour: UsageWindow?, weekly: UsageWindow?)] = []
        var planLabel: String?
        /// Spare window resets on the account (`rate_limit_reset_credits`).
        var resetCredits: ResetCredits?
    }

    static func fetch(configDir: String) throws -> Usage {
        let authURL = URL(fileURLWithPath: configDir).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String
        else { throw ProviderAPIError.noCredentials("auth.json") }
        let accountId = tokens["account_id"] as? String ?? ""

        let obj = try HTTP.request(
            usageEndpoint,
            headers: [
                "Authorization": "Bearer \(token)",
                "chatgpt-account-id": accountId,
                "User-Agent": "Merly",
            ]
        )

        func window(_ container: [String: Any]?, _ key: String) -> UsageWindow? {
            guard let w = container?[key] as? [String: Any],
                  let pct = flexDouble(w["used_percent"]) else { return nil }
            return UsageWindow(usedPct: pct, resetsAt: parseAPIDate(w["reset_at"]),
                               windowSeconds: flexDouble(w["limit_window_seconds"]))
        }

        let rateLimit = obj["rate_limit"] as? [String: Any]
        var usage = Usage(
            primary: window(rateLimit, "primary_window"),
            secondary: window(rateLimit, "secondary_window")
        )
        for extra in obj["additional_rate_limits"] as? [[String: Any]] ?? [] {
            guard let name = extra["limit_name"] as? String,
                  let rl = extra["rate_limit"] as? [String: Any] else { continue }
            usage.additional.append((name, window(rl, "primary_window"), window(rl, "secondary_window")))
        }
        if let credits = obj["rate_limit_reset_credits"] as? [String: Any] {
            let available = Int(flexDouble(credits["available_count"]) ?? 0)
            // Absent on older responses; treat that as "unknown, don't promise it's
            // spendable" rather than defaulting to the full available count.
            let applicable = Int(flexDouble(credits["applicable_available_count"]) ?? 0)
            if available > 0 {
                usage.resetCredits = ResetCredits(available: available, applicable: applicable)
            }
        }
        usage.planLabel = planLabel(obj["plan_type"] as? String)
        return usage
    }

    /// Map OpenAI's internal `plan_type` codes to the names people actually use.
    /// The usage endpoint reports a billing bucket, not the marketed plan: the
    /// rate-limited Pro tier comes back as "prolite", which capitalizes to the
    /// nonsense "Prolite". Fall back to a tidy capitalization for unknown codes.
    static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "free": return "Free"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro (5x)" // weekly-rate-limited Pro tier
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        default: return raw.capitalized
        }
    }
}

// MARK: - Kimi

enum KimiUsageAPI {
    struct Usage {
        var windows: [(label: String, window: UsageWindow)] = []
        var planLabel: String?
    }

    private static let clientId = "17e5f671-d194-4dfb-9706-5516cb48c098"
    static let usageEndpoint = URL(string: "https://api.kimi.com/coding/v1/usages")!
    static let tokenEndpoint = URL(string: "https://auth.kimi.com/api/oauth/token")!

    static func fetch(configDir: String) throws -> Usage {
        let token = try freshAccessToken(configDir: configDir)
        let obj = try HTTP.request(
            usageEndpoint,
            headers: ["Authorization": "Bearer \(token)"],
            classifyFailure: classifyUsageFailure
        )
        return try parseUsage(obj)
    }

    static func parseUsage(_ obj: [String: Any]) throws -> Usage {
        func window(_ dict: [String: Any]?, seconds: Double?) -> UsageWindow? {
            guard let dict, let limit = flexDouble(dict["limit"]), limit.isFinite, limit > 0 else { return nil }
            let used = flexDouble(dict["used"])
                ?? flexDouble(dict["remaining"]).map { limit - $0 }
            guard let used, used.isFinite else { return nil }
            return UsageWindow(
                usedPct: min(1, max(0, used / limit)) * 100,
                resetsAt: parseAPIDate(dict["resetTime"] ?? dict["resetAt"] ?? dict["reset_at"]),
                windowSeconds: seconds
            )
        }

        var usage = Usage()
        if let modern = obj["usages"] as? [String: Any] {
            let definitions: [(String, String, Double?)] = [
                ("limit_5h", "5h", 5 * 3600),
                ("limit_7d", "Weekly", 7 * 86400),
                ("limit_month_total", "Monthly total", nil),
                ("limit_month_code", "Monthly code", nil),
            ]
            for (key, label, seconds) in definitions {
                guard let entry = modern[key] as? [String: Any],
                      let ratio = flexDouble(entry["used_ratio"]), ratio.isFinite else { continue }
                usage.windows.append((label, UsageWindow(
                    usedPct: min(1, max(0, ratio)) * 100,
                    resetsAt: parseAPIDate(entry["reset_time"]), windowSeconds: seconds
                )))
            }
        }
        if usage.windows.isEmpty {
            if let week = window(obj["usage"] as? [String: Any], seconds: 7 * 86400) {
                usage.windows.append(("Weekly", week))
            }
            for item in obj["limits"] as? [[String: Any]] ?? [] {
                let detail = (item["detail"] as? [String: Any]) ?? item
                let win = item["window"] as? [String: Any]
                let seconds = flexDouble(win?["duration"]).flatMap { duration -> Double? in
                    guard duration.isFinite, duration > 0 else { return nil }
                    let unit = win?["timeUnit"] as? String ?? ""
                    let result = unit.contains("MINUTE") ? duration * 60
                        : unit.contains("HOUR") ? duration * 3600
                        : unit.contains("DAY") ? duration * 86400
                        : unit.contains("WEEK") ? duration * 604800 : duration
                    return result.isFinite ? result : nil
                }
                guard let w = window(detail, seconds: seconds) else { continue }
                let label = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (seconds == nil ? "Rate limit" : "\(LimitWindow.name(seconds: seconds)) limit")
                usage.windows.append((label, w))
            }
        }
        guard !usage.windows.isEmpty else { throw ProviderAPIError.parse("no valid Kimi usage windows") }
        usage.windows = usage.windows.enumerated().sorted {
            let left = $0.element.window.windowSeconds ?? .infinity
            let right = $1.element.window.windowSeconds ?? .infinity
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        if let user = obj["user"] as? [String: Any],
           let membership = user["membership"] as? [String: Any],
           let level = membership["level"] as? String {
            usage.planLabel = level.replacingOccurrences(of: "LEVEL_", with: "").capitalized
        }
        return usage
    }

    /// A spent or lapsed Kimi account answers `/usages` with **429**, not 402/403:
    /// `{"code":"resource_exhausted","message":"insufficient balance", details[].debug
    /// .reason: "REASON_QUOTA_EXCEEDED"}`. Read by status alone that is a transient
    /// rate limit; by body it is "no quota on this account". The wording checks
    /// mirror the CLI's own `kimi-errors.ts` quota-exhausted patterns.
    static func classifyUsageFailure(status: Int, body: Data) -> ProviderAPIError? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let code = obj["code"] as? String ?? ""
        let message = obj["message"] as? String ?? ""
        let details = obj["details"] as? [[String: Any]] ?? []
        let debug = details.compactMap { $0["debug"] as? [String: Any] }.first
        let reason = debug?["reason"] as? String ?? ""
        let localized = (debug?["localizedMessage"] as? [String: Any])?["message"] as? String

        let quotaWording = [
            #"exceeded your current (token )?quota"#, "check your account balance",
            "insufficient balance", "recharge your account|please recharge",
            "account (is )?in arrears",
        ]
        let exhausted = code == "exceeded_current_quota_error"
            || reason == "REASON_QUOTA_EXCEEDED"
            || quotaWording.contains { message.range(of: $0, options: .regularExpression) != nil }
        guard exhausted else { return nil }
        return .quotaExhausted(localized ?? (message.isEmpty ? "HTTP \(status)" : message))
    }

    static func freshAccessToken(
        configDir: String,
        refresh: ([String: String]) throws -> [String: Any] = {
            try HTTP.request(KimiUsageAPI.tokenEndpoint, method: "POST", formBody: $0)
        }
    ) throws -> String {
        let credsURL = URL(fileURLWithPath: configDir).appendingPathComponent("credentials/kimi-code.json")
        let lockPath = configDir + "/oauth/kimi-code"

        /// The raw credential dict plus its access token, typed at the one place
        /// the shape is checked — so no later call site has to force-cast.
        func load() throws -> (creds: [String: Any], accessToken: String) {
            guard let data = try? Data(contentsOf: credsURL),
                  let creds = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = creds["access_token"] as? String
            else { throw ProviderAPIError.noCredentials("credentials/kimi-code.json") }
            guard !token.isEmpty else {
                throw ProviderAPIError.expiredToken("Kimi credentials were revoked — run kimi to re-auth")
            }
            return (creds, token)
        }

        var (creds, accessToken) = try load()
        let now = Date().timeIntervalSince1970
        if let expiresAt = flexDouble(creds["expires_at"]), expiresAt.isFinite, expiresAt > now + 60 {
            return accessToken
        }

        try? FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let fd = open(lockPath, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ProviderAPIError.network("cannot open refresh lock") }
        // Refreshing without the lock is exactly the race that logs the user's
        // CLI out (two refreshers, one rotated token lost) — so a failed flock
        // aborts the refresh rather than proceeding unlocked.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ProviderAPIError.network("cannot acquire refresh lock")
        }
        defer { flock(fd, LOCK_UN); close(fd) }

        return try KimiRefreshLock.withLock(at: lockPath) { lock in
            (creds, accessToken) = try load()
            if let expiresAt = flexDouble(creds["expires_at"]), expiresAt.isFinite,
               expiresAt > Date().timeIntervalSince1970 + 60 {
                return accessToken
            }
            guard let refreshToken = creds["refresh_token"] as? String, !refreshToken.isEmpty else {
                throw ProviderAPIError.expiredToken("no refresh token — run kimi to re-auth")
            }

            let tok: [String: Any]
            try lock.assertOwnership()
            do {
                tok = try refresh([
                        "client_id": clientId,
                        "grant_type": "refresh_token",
                        "refresh_token": refreshToken,
                    ])
            } catch let ProviderAPIError.http(code) where (400..<500).contains(code) && code != 429 {
                // A 4xx on a refresh_token grant means the grant itself is dead
                // (OAuth `invalid_grant` — the login lapsed, often because the CLI
                // re-authed elsewhere and rotated the token). Surface it as an auth
                // lapse so the card says "sign in again" instead of a cryptic 400.
                throw ProviderAPIError.expiredToken("refresh rejected (\(code)) — run kimi to re-auth")
            }
            guard let access = tok["access_token"] as? String, !access.isEmpty else {
                throw ProviderAPIError.expiredToken("refresh rejected — run kimi to re-auth")
            }

            creds["access_token"] = access
            if let newRefresh = tok["refresh_token"] as? String, !newRefresh.isEmpty {
                creds["refresh_token"] = newRefresh
            }
            let expiresIn = flexDouble(tok["expires_in"]) ?? 900
            guard expiresIn.isFinite, expiresIn > 0,
                  expiresIn < Double(Int.max) - Date().timeIntervalSince1970 else {
                throw ProviderAPIError.parse("invalid Kimi token expiry")
            }
            creds["expires_in"] = Int(expiresIn)
            creds["expires_at"] = Int(Date().timeIntervalSince1970 + expiresIn)
            if let scope = tok["scope"] as? String { creds["scope"] = scope }
            if let type = tok["token_type"] as? String { creds["token_type"] = type }

            func verifyOwnership() throws -> String? {
                do {
                    try lock.assertOwnership()
                    return nil
                } catch {
                    if let winner = try? load(),
                       let winnerRefresh = winner.creds["refresh_token"] as? String,
                       !winnerRefresh.isEmpty, winnerRefresh != refreshToken,
                       let expiry = flexDouble(winner.creds["expires_at"]), expiry.isFinite,
                       expiry > Date().timeIntervalSince1970 + 60 {
                        return winner.accessToken
                    }
                    throw error
                }
            }
            if let winner = try verifyOwnership() { return winner }
            let out = try JSONSerialization.data(withJSONObject: creds)
            let tmp = credsURL.appendingPathExtension("tmp.\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try out.write(to: tmp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if let winner = try verifyOwnership() { return winner }
            _ = try FileManager.default.replaceItemAt(credsURL, withItemAt: tmp)

            return access
        }
    }
}
