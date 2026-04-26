import XCTest
@testable import CiderModels
@testable import CiderCore

final class SplashAssetStagerTests: XCTestCase {
    private var stagingPaths: [URL] = []
    private var assetCleanupNames: [String] = []

    override func tearDown() {
        for url in stagingPaths { try? FileManager.default.removeItem(at: url) }
        for name in assetCleanupNames {
            try? FileManager.default.removeItem(at: AppSupport.assets(forBundleNamed: name))
        }
        super.tearDown()
    }

    private func makeFolder() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-splash-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        stagingPaths.append(parent)
        return parent
    }

    private func uniqueName() -> String {
        let n = "SplashStagerTest-\(UUID().uuidString.prefix(8))"
        assetCleanupNames.append(n)
        return n
    }

    private func writeImage(at url: URL, ext: String = "png") throws {
        // Tiny PNG header so the file at least exists with the right
        // extension. SplashAssetStager doesn't validate image content.
        try Data("not-actually-an-image".utf8).write(to: url)
    }

    // MARK: - Inside-source: relative path, no copy

    func testRelativePathInsideSourceStaysRelativeAcrossModes() throws {
        let source = try makeFolder()
        try writeImage(at: source.appendingPathComponent("splash.png"))

        for mode in InstallMode.allCases {
            let staged = try SplashAssetStager.stage(
                rawSplashPath: "splash.png",
                mode: mode,
                sourceFolder: source,
                bundleName: uniqueName(),
                bundleURL: source.appendingPathComponent("Test.app")
            )
            XCTAssertEqual(staged, "splash.png",
                           "\(mode.rawValue) should keep an in-source splash relative")
        }
    }

    func testAbsolutePathInsideSourceCollapsesToRelative() throws {
        let source = try makeFolder()
        let abs = source.appendingPathComponent("ui/splash.png")
        try FileManager.default.createDirectory(
            at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeImage(at: abs)

        let staged = try SplashAssetStager.stage(
            rawSplashPath: abs.path,
            mode: .install,
            sourceFolder: source,
            bundleName: uniqueName(),
            bundleURL: source.appendingPathComponent("Test.app")
        )
        XCTAssertEqual(staged, "ui/splash.png")
    }

    // MARK: - Outside-source: per-mode handling

    func testLinkModeKeepsAbsoluteOutsideSource() throws {
        let source = try makeFolder()
        let outside = try makeFolder().appendingPathComponent("art.png")
        try writeImage(at: outside)

        let staged = try SplashAssetStager.stage(
            rawSplashPath: outside.path,
            mode: .link,
            sourceFolder: source,
            bundleName: uniqueName(),
            bundleURL: source.appendingPathComponent("Test.app")
        )
        XCTAssertEqual(staged, outside.path,
                       "link mode never copies — splash stays where the user left it")
    }

    func testInstallModeCopiesIntoAppSupportAssets() throws {
        let source = try makeFolder()
        let outside = try makeFolder().appendingPathComponent("art.png")
        try writeImage(at: outside)
        let bundleName = uniqueName()

        let staged = try SplashAssetStager.stage(
            rawSplashPath: outside.path,
            mode: .install,
            sourceFolder: source,
            bundleName: bundleName,
            bundleURL: source.appendingPathComponent("Test.app")
        )

        let expected = AppSupport.assets(forBundleNamed: bundleName)
            .appendingPathComponent("splash-screen.png").path
        XCTAssertEqual(staged, expected,
                       "install mode copies the splash into AppSupport/Assets/<name>/")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))
    }

    func testBundleModeCopiesNextToCiderJSON() throws {
        let source = try makeFolder()
        let outside = try makeFolder().appendingPathComponent("art.jpg")
        try writeImage(at: outside, ext: "jpg")
        let bundleURL = source.appendingPathComponent("MyGame.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let staged = try SplashAssetStager.stage(
            rawSplashPath: outside.path,
            mode: .bundle,
            sourceFolder: source,
            bundleName: uniqueName(),
            bundleURL: bundleURL
        )

        // Bundle mode stores a path relative to the cider.json (which
        // sits at <bundle>/cider.json) — just the filename.
        XCTAssertEqual(staged, "splash-screen.jpg")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("splash-screen.jpg").path))
    }

    func testBundleModeJpegCanonicalisesToJpgExtension() throws {
        let source = try makeFolder()
        let outside = try makeFolder().appendingPathComponent("art.jpeg")
        try writeImage(at: outside, ext: "jpeg")
        let bundleURL = source.appendingPathComponent("MyGame.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let staged = try SplashAssetStager.stage(
            rawSplashPath: outside.path,
            mode: .bundle,
            sourceFolder: source,
            bundleName: uniqueName(),
            bundleURL: bundleURL
        )
        XCTAssertEqual(staged, "splash-screen.jpg",
                       ".jpeg should canonicalise to .jpg in the staged copy")
    }

    func testCopyOverwritesPriorSplash() throws {
        let source = try makeFolder()
        let bundleName = uniqueName()
        let assetsDir = AppSupport.assets(forBundleNamed: bundleName)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        // Pre-seed an old splash.
        try Data("old".utf8).write(to: assetsDir.appendingPathComponent("splash-screen.png"))

        let outside = try makeFolder().appendingPathComponent("new.png")
        try Data("new".utf8).write(to: outside)

        _ = try SplashAssetStager.stage(
            rawSplashPath: outside.path,
            mode: .install,
            sourceFolder: source,
            bundleName: bundleName,
            bundleURL: source.appendingPathComponent("Test.app")
        )

        let bytes = try Data(contentsOf: assetsDir.appendingPathComponent("splash-screen.png"))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "new",
                       "stage should overwrite a previous splash-screen.png")
    }

    // MARK: - Error paths

    func testEmptyPathReturnsNilNoCopy() throws {
        let staged = try SplashAssetStager.stage(
            rawSplashPath: "",
            mode: .install,
            sourceFolder: nil,
            bundleName: uniqueName(),
            bundleURL: URL(fileURLWithPath: "/tmp/T.app")
        )
        XCTAssertNil(staged)
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try SplashAssetStager.stage(
            rawSplashPath: "/tmp/cider-does-not-exist-\(UUID().uuidString).png",
            mode: .install,
            sourceFolder: nil,
            bundleName: uniqueName(),
            bundleURL: URL(fileURLWithPath: "/tmp/T.app")
        )) { error in
            guard case SplashAssetStager.Error.sourceMissing = error else {
                XCTFail("expected .sourceMissing, got \(error)")
                return
            }
        }
    }

    func testUnsupportedExtensionRefused() throws {
        let outside = try makeFolder().appendingPathComponent("art.tiff")
        try Data("x".utf8).write(to: outside)

        XCTAssertThrowsError(try SplashAssetStager.stage(
            rawSplashPath: outside.path,
            mode: .install,
            sourceFolder: nil,
            bundleName: uniqueName(),
            bundleURL: URL(fileURLWithPath: "/tmp/T.app")
        )) { error in
            guard case SplashAssetStager.Error.unsupportedExtension = error else {
                XCTFail("expected .unsupportedExtension, got \(error)")
                return
            }
        }
    }
}
