import XCTest
@testable import Merly

/// The Merlyn → Merly rename moved the state folder. These pin the three cases
/// that decide whether a real user keeps their providers.json across the rename.
final class SupportDirMigrationTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("merly-migration-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: base)
    }

    private func write(_ text: String, to folder: String) throws {
        let dir = base.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("providers.json"),
                       atomically: true, encoding: .utf8)
    }

    private func read(_ folder: String) throws -> String {
        try String(contentsOf: base.appendingPathComponent(folder)
            .appendingPathComponent("providers.json"), encoding: .utf8)
    }

    func testLegacyFolderIsMovedAcross() throws {
        try write("{\"marker\": \"old\"}", to: "Merlyn")

        AppPaths.migrateLegacySupportDir(in: base)

        XCTAssertEqual(try read("Merly"), "{\"marker\": \"old\"}",
                       "the user's config must survive the rename")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: base.appendingPathComponent("Merlyn").path),
            "the old folder must not be left behind to confuse the next migration")
    }

    /// The dangerous case: never overwrite state the renamed app already wrote.
    func testExistingFolderIsNeverClobbered() throws {
        try write("{\"marker\": \"old\"}", to: "Merlyn")
        try write("{\"marker\": \"current\"}", to: "Merly")

        AppPaths.migrateLegacySupportDir(in: base)

        XCTAssertEqual(try read("Merly"), "{\"marker\": \"current\"}")
        XCTAssertEqual(try read("Merlyn"), "{\"marker\": \"old\"}",
                       "the legacy folder stays put rather than being half-merged")
    }

    func testNoLegacyFolderIsANoOp() {
        AppPaths.migrateLegacySupportDir(in: base)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: base.appendingPathComponent("Merly").path),
            "migration must not conjure an empty folder for a fresh install")
    }
}
