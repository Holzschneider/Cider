import XCTest
@testable import CiderModels
@testable import CiderCore

final class BundleTransmogrifierTests: XCTestCase {
    private func makeFakeBundle(named: String = "Cider", in dir: URL) throws -> URL {
        let bundle = dir.appendingPathComponent("\(named).app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let exe = macOS.appendingPathComponent("cider")
        try Data("not a real binary".utf8).write(to: exe)
        try Data().write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    private func sampleConfig(_ displayName: String) -> CiderConfig {
        CiderConfig(
            displayName: displayName,
            exe: "Game.exe",
            source: .init(mode: .path, path: "/tmp/source"),
            engine: .init(name: "WS12WineCX24.0.7_7", url: "https://example.com/x.tar.xz"),
            graphics: .dxmt
        )
    }

    private func tmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-bt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testApplyInPlaceRenamesAndPersistsConfigToInBundleOverride() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try makeFakeBundle(in: dir)

        let result = try BundleTransmogrifier(
            currentBundle: bundle,
            config: sampleConfig("My Game"),
            storage: .inBundleOverride
        ).transmogrify(mode: .applyInPlace)

        XCTAssertEqual(result.finalBundleURL.lastPathComponent, "My Game.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.finalBundleURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertEqual(
            result.configWrittenTo.lastPathComponent, "cider.json")
        XCTAssertTrue(result.configWrittenTo.path.contains("CiderConfig"))
        let loaded = try CiderConfig.read(from: result.configWrittenTo)
        XCTAssertEqual(loaded.displayName, "My Game")
    }

    func testCloneCopiesAndLeavesOriginalUntouched() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = try makeFakeBundle(in: dir)
        let dest = dir.appendingPathComponent("Sub").appendingPathComponent("Copied.app")

        let result = try BundleTransmogrifier(
            currentBundle: original,
            config: sampleConfig("Anything"),
            storage: .inBundleOverride
        ).transmogrify(mode: .cloneTo(dest))

        XCTAssertEqual(result.finalBundleURL, dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "original must remain")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("Contents/MacOS/cider").path))
    }

    func testCloneWipesStaleInBundleOverrideWhenStorageIsAppSupport() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = try makeFakeBundle(in: dir)
        // Pre-seed a stale CiderConfig/ override on the source.
        let staleOverride = original.appendingPathComponent("CiderConfig", isDirectory: true)
        try FileManager.default.createDirectory(at: staleOverride, withIntermediateDirectories: true)
        try sampleConfig("Stale").write(to: staleOverride.appendingPathComponent("cider.json"))

        let dest = dir.appendingPathComponent("Out.app")
        let result = try BundleTransmogrifier(
            currentBundle: original,
            config: sampleConfig("Fresh"),
            storage: .appSupport
        ).transmogrify(mode: .cloneTo(dest))

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("CiderConfig/cider.json").path),
            "stale override should have been wiped on clone with appSupport storage"
        )
        XCTAssertTrue(result.configWrittenTo.path.contains("Application Support/Cider/Configs/"),
                      "appSupport storage should write under AppSupport")
    }

    func testFailsWhenTargetExistsWithoutForce() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = try makeFakeBundle(in: dir)
        let collision = dir.appendingPathComponent("My Game.app", isDirectory: true)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)

        XCTAssertThrowsError(try BundleTransmogrifier(
            currentBundle: original,
            config: sampleConfig("My Game"),
            storage: .inBundleOverride,
            allowOverwrite: false
        ).transmogrify(mode: .applyInPlace)) { error in
            guard case BundleTransmogrifier.Error.targetExists = error else {
                XCTFail("expected .targetExists, got \(error)")
                return
            }
        }
    }

    func testForceOverwritesExistingTarget() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = try makeFakeBundle(in: dir)
        let collision = dir.appendingPathComponent("My Game.app", isDirectory: true)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: collision.appendingPathComponent("MARKER"))

        let result = try BundleTransmogrifier(
            currentBundle: original,
            config: sampleConfig("My Game"),
            storage: .inBundleOverride,
            allowOverwrite: true
        ).transmogrify(mode: .applyInPlace)

        XCTAssertEqual(result.finalBundleURL, collision)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: collision.appendingPathComponent("MARKER").path),
            "force should have replaced the placeholder"
        )
    }

    func testSanitiseStripsDisallowedCharacters() {
        XCTAssertEqual(BundleTransmogrifier.sanitiseBundleName("Foo:Bar/Baz"), "Foo Bar Baz")
        XCTAssertEqual(BundleTransmogrifier.sanitiseBundleName("  My  Game  "), "My Game")
        XCTAssertEqual(BundleTransmogrifier.sanitiseBundleName("Game?<>|"), "Game")
    }
}
