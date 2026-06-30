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

    var description: String {
        switch self {
        case .noCredentials(let what): "no credentials (\(what))"
        case .expiredToken(let what): "login expired (\(what))"
        case .http(let code): "HTTP \(code)"
        case .network(let msg): "network: \(msg)"
        case .parse(let what): "unexpected response (\(what))"
        }
    }

    /// The login is gone, not merely unreachable: the token expired or there are
    /// no credentials. Readers whose only fallback is a misleading local estimate
    /// surface "No data" for these instead of guessing.
    var isAuthLapse: Bool {
        switch self {
        case .expiredToken, .noCredentials: true
        default: false
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
    var isServerUnreachable: Bool { (self as? ProviderAPIError)?.isServerUnreachable ?? false }
    var isRateLimited: Bool { (self as? ProviderAPIError)?.isRateLimited ?? false }
}

// MARK: - small sync HTTP helper (always called off the main thread)

enum HTTP {
    static func request(
        _ url: URL, method: String = "GET",
        headers: [String: String] = [:], formBody: [String: String]? = nil
    ) throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 15)
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
        nonisolated(unsafe) var result: Result<(Data, Int), Error>!
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()

        switch result! {
        case .failure(let error):
            throw ProviderAPIError.network(error.localizedDescription)
        case .success(let (data, status)):
            guard (200..<300).contains(status) else { throw ProviderAPIError.http(status) }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProviderAPIError.parse("not a JSON object")
            }
            return obj
        }
    }
}

/// Parses API dates: ISO 8601 with any fractional precision, or epoch seconds.
func parseAPIDate(_ value: Any?) -> Date? {
    if let n = value as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
    guard var s = value as? String, !s.isEmpty else { return nil }
    // ISO8601DateFormatter only accepts millisecond fractions — trim longer ones
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
        s = s.replacingCharacters(in: r, with: String(s[r].prefix(4)))
    }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
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
}

// MARK: - Claude

enum ClaudeUsageAPI {
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
            URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
            ]
        )

        func window(_ key: String) -> UsageWindow? {
            guard let w = obj[key] as? [String: Any],
                  let pct = flexDouble(w["utilization"]) else { return nil }
            return UsageWindow(usedPct: pct, resetsAt: parseAPIDate(w["resets_at"]))
        }

        var usage = Usage(fiveHour: window("five_hour"), sevenDay: window("seven_day"))
        for (key, label) in [("seven_day_sonnet", "Sonnet only"), ("seven_day_opus", "Opus only")] {
            if let w = window(key), w.usedPct > 0 || w.resetsAt != nil {
                usage.sevenDayModels.append((label, w))
            }
        }
        usage.planLabel = planLabel(
            subscription: oauth["subscriptionType"] as? String,
            tier: oauth["rateLimitTier"] as? String
        )
        return usage
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
    struct Usage {
        var primary: UsageWindow?
        var secondary: UsageWindow?
        var additional: [(name: String, fiveHour: UsageWindow?, weekly: UsageWindow?)] = []
        var planLabel: String?
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
            URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            headers: [
                "Authorization": "Bearer \(token)",
                "chatgpt-account-id": accountId,
                "User-Agent": "Lens",
            ]
        )

        func window(_ container: [String: Any]?, _ key: String) -> UsageWindow? {
            guard let w = container?[key] as? [String: Any],
                  let pct = flexDouble(w["used_percent"]) else { return nil }
            return UsageWindow(usedPct: pct, resetsAt: parseAPIDate(w["reset_at"]))
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
        var weekly: UsageWindow?
        var shortWindows: [(label: String, window: UsageWindow)] = []
        var planLabel: String?
    }

    private static let clientId = "17e5f671-d194-4dfb-9706-5516cb48c098"

    static func fetch(configDir: String) throws -> Usage {
        let token = try freshAccessToken(configDir: configDir)
        let obj = try HTTP.request(
            URL(string: "https://api.kimi.com/coding/v1/usages")!,
            headers: ["Authorization": "Bearer \(token)"]
        )

        func window(_ dict: [String: Any]?) -> UsageWindow? {
            guard let dict, let limit = flexDouble(dict["limit"]), limit > 0 else { return nil }
            let used = flexDouble(dict["used"])
                ?? flexDouble(dict["remaining"]).map { limit - $0 }
                ?? 0
            return UsageWindow(
                usedPct: min(100, max(0, used / limit * 100)),
                resetsAt: parseAPIDate(dict["resetTime"] ?? dict["resetAt"] ?? dict["reset_at"])
            )
        }

        var usage = Usage(weekly: window(obj["usage"] as? [String: Any]))
        for item in obj["limits"] as? [[String: Any]] ?? [] {
            let detail = (item["detail"] as? [String: Any]) ?? item
            guard let w = window(detail) else { continue }
            let win = item["window"] as? [String: Any]
            let label: String
            if let duration = flexDouble(win?["duration"]) {
                let unit = win?["timeUnit"] as? String ?? ""
                let minutes = unit.contains("MINUTE") ? duration
                    : unit.contains("HOUR") ? duration * 60
                    : unit.contains("DAY") ? duration * 1440 : duration / 60
                label = minutes.truncatingRemainder(dividingBy: 60) == 0
                    ? "\(Int(minutes / 60))h limit" : "\(Int(minutes))m limit"
            } else {
                label = "Rate limit"
            }
            usage.shortWindows.append((label, w))
        }
        if let user = obj["user"] as? [String: Any],
           let membership = user["membership"] as? [String: Any],
           let level = membership["level"] as? String {
            usage.planLabel = level.replacingOccurrences(of: "LEVEL_", with: "").capitalized
        }
        return usage
    }

    /// Mirrors the CLI's refresh protocol: flock the shared lockfile, re-read
    /// creds (another process may have refreshed first), refresh if still
    /// stale, and persist — refresh tokens rotate, so losing the new one
    /// would log the CLI out.
    private static func freshAccessToken(configDir: String) throws -> String {
        let credsURL = URL(fileURLWithPath: configDir).appendingPathComponent("credentials/kimi-code.json")
        let lockPath = configDir + "/oauth/kimi-code"

        func load() throws -> [String: Any] {
            guard let data = try? Data(contentsOf: credsURL),
                  let creds = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  creds["access_token"] is String
            else { throw ProviderAPIError.noCredentials("credentials/kimi-code.json") }
            return creds
        }

        var creds = try load()
        let now = Date().timeIntervalSince1970
        if let expiresAt = flexDouble(creds["expires_at"]), expiresAt > now + 60 {
            return creds["access_token"] as! String
        }

        try? FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let fd = open(lockPath, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw ProviderAPIError.network("cannot open refresh lock") }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }

        creds = try load() // re-read under the lock
        if let expiresAt = flexDouble(creds["expires_at"]), expiresAt > now + 60 {
            return creds["access_token"] as! String
        }
        guard let refreshToken = creds["refresh_token"] as? String else {
            throw ProviderAPIError.expiredToken("no refresh token — run kimi to re-auth")
        }

        let tok = try HTTP.request(
            URL(string: "https://auth.kimi.com/api/oauth/token")!,
            method: "POST",
            formBody: [
                "client_id": clientId,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ]
        )
        guard let access = tok["access_token"] as? String else {
            throw ProviderAPIError.expiredToken("refresh rejected — run kimi to re-auth")
        }

        creds["access_token"] = access
        if let newRefresh = tok["refresh_token"] as? String, !newRefresh.isEmpty {
            creds["refresh_token"] = newRefresh
        }
        let expiresIn = flexDouble(tok["expires_in"]) ?? 900
        creds["expires_in"] = Int(expiresIn)
        creds["expires_at"] = Int(now + expiresIn)
        if let scope = tok["scope"] as? String { creds["scope"] = scope }
        if let type = tok["token_type"] as? String { creds["token_type"] = type }

        let out = try JSONSerialization.data(withJSONObject: creds)
        let tmp = credsURL.appendingPathExtension("tmp")
        try out.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(credsURL, withItemAt: tmp)

        return access
    }
}
