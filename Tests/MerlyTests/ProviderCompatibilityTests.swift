import Darwin
import XCTest
@testable import Merly

final class ProviderCompatibilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func write(_ json: String, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url
    }

    func testUsageCacheIdentitySeparatesAccountsButKeepsMetadataAndNormalizedDirectories() {
        let config = ProviderConfig(id: "provider", name: "Kimi", account: "A", kind: .kimi, dir: "/tmp/account")
        var changed = config
        changed.dir = "/tmp/other-account"
        XCTAssertNotEqual(usageCacheKey(for: config), usageCacheKey(for: changed))
        changed = config
        changed.kind = .claude
        XCTAssertNotEqual(usageCacheKey(for: config), usageCacheKey(for: changed))
        changed = config
        changed.name = "Renamed"
        changed.account = "New label"
        changed.dir = "/tmp/account/"
        XCTAssertEqual(usageCacheKey(for: config), usageCacheKey(for: changed))
    }

    func testKimiCurrentUsageFixturePreservesEveryBudgetAndRealZero() throws {
        let payload = try object(#"""
        {"goods_version":2,"usages":{
          "limit_5h":{"used_ratio":0,"reset_time":"2026-09-11T18:00:00Z"},
          "limit_7d":{"used_ratio":"0.2","reset_time":"2026-09-17T00:00:00Z"},
          "limit_month_total":{"used_ratio":0.4,"reset_time":"2026-10-01T00:00:00Z"},
          "limit_month_code":{"used_ratio":0.25,"reset_time":"2026-10-01T00:00:00Z"}
        }}
        """#)
        let usage = try KimiUsageAPI.parseUsage(payload)
        XCTAssertEqual(usage.windows.map(\.label), ["5h", "Weekly", "Monthly total", "Monthly code"])
        XCTAssertEqual(usage.windows.map(\.window.usedPct), [0, 20, 40, 25])
        XCTAssertEqual(usage.windows.first?.window.windowSeconds, 18_000)
        XCTAssertEqual(usage.windows.last?.window.resetsAt, parseAPIDate("2026-10-01T00:00:00Z"))
        XCTAssertNil(usage.windows.last?.window.windowSeconds)
    }

    func testKimiLegacyWindowsSortShortestFirstAndKeepPlan() throws {
        let usage = try KimiUsageAPI.parseUsage(try object(#"""
        {"usage":{"limit":"100","used":"82"},"limits":[
          {"window":{"duration":1,"timeUnit":"TIME_UNIT_DAY"},"detail":{"limit":"100","remaining":"50"}},
          {"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"100"}}
        ],"user":{"membership":{"level":"LEVEL_BASIC"}}}
        """#))
        XCTAssertEqual(usage.windows.map(\.window.usedPct), [0, 50, 82])
        XCTAssertEqual(usage.windows.map(\.window.windowSeconds), [18_000, 86_400, 604_800])
        XCTAssertEqual(usage.planLabel, "Basic")
    }

    func testKimiModernShapeWinsWithoutDuplicatingLegacyWindows() throws {
        let usage = try KimiUsageAPI.parseUsage(try object(#"""
        {"usages":{"limit_5h":{"used_ratio":0.2}},"usage":{"limit":100,"used":90}}
        """#))
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows.first?.window.usedPct, 20)
    }

    func testKimiRejectsUnknownMalformedAndNonfiniteUsage() throws {
        let payloads: [[String: Any]] = [
            [:], ["usage": ["limit": 100]],
            ["usages": ["limit_5h": ["used_ratio": Double.nan]]],
            ["usages": ["limit_5h": ["used_ratio": Double.infinity]]],
        ]
        for payload in payloads {
            XCTAssertThrowsError(try KimiUsageAPI.parseUsage(payload))
        }
        let bounded = try KimiUsageAPI.parseUsage([
            "usages": ["limit_5h": ["used_ratio": -1], "limit_7d": ["used_ratio": 1e300]],
        ])
        XCTAssertEqual(bounded.windows.map(\.window.usedPct), [0, 100])
    }

    func testKimiOfficialWireFixtureCountsUsageRecordInsteadOfRepeatedStepEnd() throws {
        let url = try write(#"""
        {"type":"context.append_loop_event","event":{"type":"step.end","uuid":"s1","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0}},"time":1779256800300}
        {"type":"usage.record","model":"kimi-k2","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1779256800302}
        """#, name: "wire.jsonl")
        XCTAssertEqual(KimiReader.parse(url).values.first?["all"], 15)
    }

    func testKimiModernZeroPreservesUnrelatedLegacyUsage() throws {
        let legacy = #"{"type":"step.end","usage":{"inputOther":20},"time":1779256800300}"#
        let invalid = #"{"type":"usage.record","usage":{},"usageScope":"turn","time":1779256800302}"#
        let nonturn = #"{"type":"usage.record","usage":{"inputOther":500},"usageScope":"unknown","time":1779256800302}"#
        let url = try write([legacy, invalid, nonturn].joined(separator: "\n"), name: "wire.jsonl")
        XCTAssertEqual(KimiReader.parse(url).values.first?["all"], 20)
        let zero = #"{"type":"usage.record","usage":{"inputOther":0},"usageScope":"turn","time":1779256800302}"#
        try Data([legacy, zero].joined(separator: "\n").utf8).write(to: url)
        XCTAssertEqual(KimiReader.parse(url).values.first?["all"], 20)
    }

    func testParserCacheVersionReparsesOnlyItsOwnNamespace() {
        var cache = FileBucketCache()
        let url = directory.appendingPathComponent("wire.jsonl")
        let now = Date()
        _ = cache.buckets(for: url, mtime: now, size: 10) { _ in [0: ["all": 30]] }
        let current = cache.buckets(for: url, mtime: now, size: 10, parserVersion: "kimi-v2") {
            _ in [0: ["all": 15]]
        }
        let unchanged = cache.buckets(for: url, mtime: now, size: 10) { _ in XCTFail(); return [:] }
        XCTAssertEqual(current[0]?["all"], 15)
        XCTAssertEqual(unchanged[0]?["all"], 30)
    }

    func testCodexFallbackUsesEventTimestampAndRetainsWeeklyPrimaryMetadata() throws {
        let now = Date()
        func event(age: TimeInterval, pct: Int) -> String {
            let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))
            let reset = Int(now.addingTimeInterval(3600).timeIntervalSince1970)
            return """
            {"timestamp":"\(timestamp)","payload":{"rate_limits":{"primary":{"used_percent":\(pct),"window_minutes":10080,"resets_at":\(reset)},"secondary":{"used_percent":25,"window_minutes":10080,"resets_at":\(reset)}}}}
            """
        }
        let recentlyTouched = try write(event(age: 1800, pct: 10), name: "resumed.jsonl")
        let newerReading = try write(event(age: 300, pct: 88), name: "newer.jsonl")
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: recentlyTouched.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: newerReading.path)
        let config = ProviderConfig(id: "codex", name: "Codex", account: "Test", kind: .codex, dir: directory.path)
        let snapshot = try XCTUnwrap(CodexReader().rolloutFallback(config: config, now: now, root: directory))
        XCTAssertEqual(snapshot.sessionPct, 88)
        XCTAssertEqual(snapshot.sessionWindowSeconds, 604_800)
        XCTAssertNotNil(snapshot.weekly.first?.resetAt)
    }

    func testMonthlyPrimaryAndWindowDurationSurviveRealReadingCache() throws {
        let config = ProviderConfig(id: "kimi", name: "Kimi", account: "Test", kind: .kimi, dir: directory.path)
        let snapshot = ProviderSnapshot(
            config: config, sessionPct: 40, sessionResetAt: nil, weekly: [],
            isActive: false, isEstimated: false, primaryWindowLabel: "Monthly total", note: nil
        )
        let encoded = try JSONEncoder().encode(XCTUnwrap(snapshot.realReading(at: Date())))
        let decoded = try JSONDecoder().decode(RealReading.self, from: encoded)
        let cached = ProviderSnapshot.fromCache(decoded, config: config, now: Date())
        XCTAssertEqual(cached.primaryWindowName, "Monthly total")
        XCTAssertFalse(cached.hasSessionWindow)
        XCTAssertEqual(cached.iconGauges.map(\.window), ["mo"])
        XCTAssertTrue(cached.gaugeTooltip().contains("monthly total limit"))
        var weekly = snapshot
        weekly.primaryWindowLabel = nil
        weekly.sessionWindowSeconds = 604_800
        let weeklyCache = try XCTUnwrap(weekly.realReading(at: Date()))
        XCTAssertEqual(ProviderSnapshot.fromCache(weeklyCache, config: config, now: Date()).primaryWindowName, "Weekly")
    }

    func testKimiDirectoryLockRejectsContentionAndCleansUpItsOwnDirectory() throws {
        let target = directory.appendingPathComponent("kimi-code").path
        try KimiRefreshLock.withLock(at: target) { lock in
            XCTAssertTrue(FileManager.default.fileExists(atPath: target + ".lock"))
            XCTAssertThrowsError(try KimiRefreshLock.withLock(at: target) { _ in () })
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: target + ".lock")
            try lock.assertOwnership()
            let attrs = try FileManager.default.attributesOfItem(atPath: target + ".lock")
            XCTAssertGreaterThan(try XCTUnwrap(attrs[.modificationDate] as? Date), Date().addingTimeInterval(-2))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + ".lock"))
    }

    func testKimiLostDirectoryLockNeverRemovesAnotherOwnersDirectory() throws {
        let target = directory.appendingPathComponent("kimi-code").path
        try KimiRefreshLock.withLock(at: target) { lock in
            try FileManager.default.moveItem(atPath: target + ".lock", toPath: target + ".retired")
            try FileManager.default.createDirectory(atPath: target + ".lock", withIntermediateDirectories: false)
            XCTAssertThrowsError(try lock.assertOwnership())
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target + ".lock"))
    }

    private func credentials(access: String = "old-access", refresh: String = "old-refresh", expires: TimeInterval = 0) throws -> URL {
        let folder = directory.appendingPathComponent("credentials")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("kimi-code.json")
        try JSONSerialization.data(withJSONObject: [
            "access_token": access, "refresh_token": refresh, "expires_at": expires,
        ]).write(to: url)
        return url
    }

    func testKimiRefreshPersistsRotatedTokensAndLeaves429RateLimited() throws {
        let url = try credentials()
        let token = try KimiUsageAPI.freshAccessToken(configDir: directory.path) { form in
            XCTAssertEqual(form["refresh_token"], "old-refresh")
            return ["access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 900]
        }
        XCTAssertEqual(token, "new-access")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(saved["refresh_token"] as? String, "new-refresh")
        _ = try credentials()
        XCTAssertThrowsError(try KimiUsageAPI.freshAccessToken(configDir: directory.path) { _ in
            throw ProviderAPIError.http(429)
        }) { XCTAssertTrue($0.isRateLimited); XCTAssertFalse($0.isAuthLapse) }
    }

    func testKimiRevokedCredentialsAndHeldLegacyLockNeverRefresh() throws {
        _ = try credentials(access: "", refresh: "")
        XCTAssertThrowsError(try KimiUsageAPI.freshAccessToken(configDir: directory.path) { _ in
            XCTFail("Revoked credentials must not make a token request"); return [:]
        }) { XCTAssertTrue($0.isAuthLapse) }
        _ = try credentials()
        let folder = directory.appendingPathComponent("oauth")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appendingPathComponent("kimi-code").path, O_WRONLY | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try KimiUsageAPI.freshAccessToken(configDir: directory.path) { _ in
            XCTFail("Legacy lock contention must not make a token request"); return [:]
        })
    }

    func testKimiLostLockAdoptsFreshDiskWinnerWithoutOverwritingIt() throws {
        let url = try credentials()
        let target = directory.appendingPathComponent("oauth/kimi-code").path
        let token = try KimiUsageAPI.freshAccessToken(configDir: directory.path) { _ in
            try FileManager.default.moveItem(atPath: target + ".lock", toPath: target + ".retired")
            try FileManager.default.createDirectory(atPath: target + ".lock", withIntermediateDirectories: false)
            _ = try self.credentials(access: "winner-access", refresh: "winner-refresh", expires: Date().timeIntervalSince1970 + 900)
            return ["access_token": "loser-access", "refresh_token": "loser-refresh", "expires_in": 900]
        }
        XCTAssertEqual(token, "winner-access")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(saved["refresh_token"] as? String, "winner-refresh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target + ".lock"))
    }

    func testKimiLostLockWithoutDiskWinnerPreservesCredentialsAndFails() throws {
        let url = try credentials()
        let original = try Data(contentsOf: url)
        let target = directory.appendingPathComponent("oauth/kimi-code").path
        XCTAssertThrowsError(try KimiUsageAPI.freshAccessToken(configDir: directory.path) { _ in
            try FileManager.default.moveItem(atPath: target + ".lock", toPath: target + ".retired")
            try FileManager.default.createDirectory(atPath: target + ".lock", withIntermediateDirectories: false)
            return ["access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 900]
        })
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
