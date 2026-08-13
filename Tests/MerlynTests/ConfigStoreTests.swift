import XCTest
@testable import Merlyn

final class ConfigStoreTests: XCTestCase {
    private var dir: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("merlyn-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configURL = dir.appendingPathComponent("providers.json")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    /// The one bug this store must never have again: a hand-edit typo in
    /// providers.json must not be overwritten with defaults. The broken file is
    /// quarantined beside the config, byte-for-byte intact.
    func testCorruptConfigIsQuarantinedNotOverwritten() throws {
        let broken = #"{"providers": [ this is not json"#
        try broken.write(to: configURL, atomically: true, encoding: .utf8)

        _ = ConfigStore.load(from: configURL)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let quarantined = siblings.filter { $0.contains("providers.json.broken-") }
        XCTAssertEqual(quarantined.count, 1, "the broken file must be moved aside")
        let preserved = try String(
            contentsOf: dir.appendingPathComponent(quarantined[0]), encoding: .utf8)
        XCTAssertEqual(preserved, broken, "quarantined content must be untouched")
    }

    func testRoundTripPreservesProviders() throws {
        var config = AppConfig.default
        config.providers = [ProviderConfig(
            id: "custom", name: "Custom", account: "Me", kind: .kimi,
            dir: "~/.kimi-alt", sessionTokenLimit: 123_456
        )]
        XCTAssertTrue(ConfigStore.save(config, to: configURL))

        let loaded = ConfigStore.load(from: configURL)
        XCTAssertEqual(loaded.providers.map(\.id), ["custom"])
        XCTAssertEqual(loaded.providers.first?.sessionTokenLimit, 123_456)
    }

    /// Configs written before optional keys existed must decode — a missing key
    /// throwing is exactly the wipe-the-config path this store guards against.
    func testLegacyConfigWithoutOptionalKeysDecodes() throws {
        let legacy = """
        {
          "sessionHours": 5,
          "refreshSeconds": 60,
          "providers": [
            {"id": "claude", "name": "Claude", "account": "", "kind": "claude", "dir": "~/.claude"}
          ]
        }
        """
        try legacy.write(to: configURL, atomically: true, encoding: .utf8)
        let loaded = ConfigStore.load(from: configURL)
        XCTAssertEqual(loaded.providers.count, 1)
        // Defaults flow through the always-present accessors.
        XCTAssertFalse(loaded.notificationSettings.enabled)
        XCTAssertEqual(loaded.defaultMascotConfig, .standard)
        // Migration assigns position-based color slots and persists them.
        XCTAssertNotNil(loaded.providers.first?.colorSlot)
    }

    func testMissingFileWritesFirstRunDefault() {
        let loaded = ConfigStore.load(from: configURL)
        XCTAssertFalse(loaded.providers.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path),
                      "first run must persist a starting config")
    }
}
