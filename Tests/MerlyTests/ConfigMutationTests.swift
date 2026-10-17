import Combine
import XCTest
@testable import Merly

final class ConfigMutationTests: XCTestCase {
    private var directory: URL!
    private var configDirectory: URL!
    private var preservedDirectory: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("merly-config-mutations-\(UUID().uuidString)")
        configDirectory = directory.appendingPathComponent("config")
        preservedDirectory = directory.appendingPathComponent("preserved")
        configURL = configDirectory.appendingPathComponent("providers.json")
        var config = AppConfig.default
        config.providers = [provider("first", slot: 1), provider("second", slot: 2)]
        config.defaultMascotConfig = DefaultMascot(style: .cat, colorSlot: 0, sprite: "merly-sprite")
        XCTAssertTrue(ConfigStore.save(config, to: configURL))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testFailedReorderKeepsConfigAndSnapshotOrder() async throws {
        let engine = UsageEngine(configURL: configURL)
        let originalProviders = engine.appConfig.providers
        let originalSnapshots = engine.snapshots
        try blockWrites()
        var publications = 0
        let subscription = engine.$snapshots.dropFirst().sink { _ in publications += 1 }

        XCTAssertFalse(engine.moveProvider("first", toIndexOf: "second"))

        XCTAssertEqual(engine.appConfig.providers, originalProviders)
        XCTAssertEqual(engine.snapshots, originalSnapshots)
        XCTAssertEqual(publications, 0)
        XCTAssertFalse(engine.isRefreshing)
        XCTAssertTrue(engine.configSaveError?.contains(configURL.path) == true)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testFailedProviderMutationsKeepStateWithoutStartingRefresh() async throws {
        let engine = UsageEngine(configURL: configURL)
        let originalProviders = engine.appConfig.providers
        let originalSnapshots = engine.snapshots
        try blockWrites()
        var snapshotPublications = 0
        var refreshPublications = 0
        let snapshots = engine.$snapshots.dropFirst().sink { _ in snapshotPublications += 1 }
        let refreshing = engine.$isRefreshing.dropFirst().sink { _ in refreshPublications += 1 }
        var edited = originalProviders[0]
        edited.name = "Renamed"

        XCTAssertFalse(engine.addProvider(provider("added", slot: 3)))
        XCTAssertFalse(engine.updateProvider(edited))
        XCTAssertFalse(engine.removeProvider("first"))

        XCTAssertEqual(engine.appConfig.providers, originalProviders)
        XCTAssertEqual(engine.snapshots, originalSnapshots)
        XCTAssertEqual(snapshotPublications, 0)
        XCTAssertEqual(refreshPublications, 0)
        XCTAssertFalse(engine.isRefreshing)
        XCTAssertNil(engine.lastRefresh)
        XCTAssertNotNil(engine.configSaveError)
        withExtendedLifetime((snapshots, refreshing)) {}
    }

    @MainActor
    func testFailedPreferencesKeepSavedValues() async throws {
        let engine = UsageEngine(configURL: configURL)
        let originalSettings = engine.appConfig.notificationSettings
        let originalPlacement = engine.appConfig.railPlacement
        let originalMascot = engine.appConfig.defaultMascotConfig
        let originalPin = engine.appConfig.menuBarProviderId
        try blockWrites()
        var publications = 0
        let subscription = engine.$snapshots.dropFirst().sink { _ in publications += 1 }
        var settings = originalSettings
        settings.enabled.toggle()

        XCTAssertFalse(engine.updateNotificationSettings(settings))
        XCTAssertFalse(engine.updateRailPlacement(RailPlacement(edge: .left, offset: 0.5)))
        XCTAssertFalse(engine.updateDefaultMascot(DefaultMascot(style: .robot, colorSlot: 3, sprite: "")))
        XCTAssertFalse(engine.updateMenuBarProvider("first"))

        XCTAssertEqual(engine.appConfig.notificationSettings, originalSettings)
        XCTAssertEqual(engine.appConfig.railPlacement, originalPlacement)
        XCTAssertEqual(engine.appConfig.defaultMascotConfig, originalMascot)
        XCTAssertEqual(engine.appConfig.menuBarProviderId, originalPin)
        XCTAssertEqual(publications, 0)
        XCTAssertFalse(engine.isRefreshing)
        XCTAssertNotNil(engine.configSaveError)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testSuccessfulReorderPersistsAndClearsPreviousError() async throws {
        let engine = UsageEngine(configURL: configURL)
        try blockWrites()
        XCTAssertFalse(engine.moveProvider("first", toIndexOf: "second"))
        XCTAssertNotNil(engine.configSaveError)
        try restoreWrites()

        XCTAssertTrue(engine.moveProvider("first", toIndexOf: "second"))

        XCTAssertEqual(engine.appConfig.providers.map(\.id), ["second", "first"])
        XCTAssertEqual(engine.snapshots.map(\.id), ["second", "first"])
        XCTAssertEqual(ConfigStore.load(from: configURL).providers, engine.appConfig.providers)
        XCTAssertNil(engine.configSaveError)
        XCTAssertFalse(engine.isRefreshing)
    }

    @MainActor
    func testInvalidIDsAndNoOpsDoNotAttemptWrites() async throws {
        let engine = UsageEngine(configURL: configURL)
        let originalProviders = engine.appConfig.providers
        let originalSnapshots = engine.snapshots
        try blockWrites()

        XCTAssertFalse(engine.updateProvider(provider("missing", slot: 3)))
        XCTAssertFalse(engine.removeProvider("missing"))
        XCTAssertFalse(engine.moveProvider("missing", toIndexOf: "first"))
        XCTAssertFalse(engine.moveProvider("first", toIndexOf: "missing"))
        XCTAssertFalse(engine.updateMenuBarProvider("missing"))
        XCTAssertTrue(engine.updateProvider(originalProviders[0]))
        XCTAssertTrue(engine.moveProvider("first", toIndexOf: "first"))
        XCTAssertTrue(engine.updateNotificationSettings(engine.appConfig.notificationSettings))
        XCTAssertTrue(engine.updateRailPlacement(engine.appConfig.railPlacement))
        XCTAssertTrue(engine.updateDefaultMascot(engine.appConfig.defaultMascotConfig))
        XCTAssertTrue(engine.updateMenuBarProvider(engine.appConfig.menuBarProviderId))

        XCTAssertEqual(engine.appConfig.providers, originalProviders)
        XCTAssertEqual(engine.snapshots, originalSnapshots)
        XCTAssertFalse(engine.isRefreshing)
        XCTAssertNil(engine.configSaveError)

        XCTAssertFalse(engine.moveProvider("first", toIndexOf: "second"))
        let error = engine.configSaveError
        XCTAssertTrue(engine.moveProvider("first", toIndexOf: "first"))
        XCTAssertEqual(engine.configSaveError, error)
        engine.dismissConfigSaveError()
        XCTAssertNil(engine.configSaveError)
    }

    private func provider(_ id: String, slot: Int) -> ProviderConfig {
        ProviderConfig(id: id, name: id, account: "Test", kind: .claude,
                       dir: "/fixtures/\(id)", colorSlot: slot)
    }

    private func blockWrites() throws {
        try FileManager.default.moveItem(at: configDirectory, to: preservedDirectory)
        try Data("not a directory".utf8).write(to: configDirectory)
    }

    private func restoreWrites() throws {
        try FileManager.default.removeItem(at: configDirectory)
        try FileManager.default.moveItem(at: preservedDirectory, to: configDirectory)
    }
}
