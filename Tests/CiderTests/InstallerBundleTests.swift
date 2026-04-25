import XCTest
@testable import CiderModels
@testable import CiderCore

final class InstallerBundleTests: XCTestCase {
    private var bundleParent: URL!
    private var bundleURL: URL!
    private var stagingPaths: [URL] = []

    override func setUp() {
        super.setUp()
        bundleParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-installer-bundle-\(UUID().uuidString)",
                                    isDirectory: true)
        bundleURL = bundleParent.appendingPathComponent("Test.app", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: bundleParent)
        for url in stagingPaths {
            try? FileManager.default.removeItem(at: url)
        }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func sampleConfig(_ exe: String, name: String = "BundleTest") -> CiderConfig {
        CiderConfig(
            displayName: name,
            applicationPath: "PLACEHOLDER",
            exe: exe,
            engine: .init(name: "WS12WineCX24.0.7_7",
                          url: "https://example.com/x.tar.xz"),
            graphics: .dxmt
        )
    }

    private func makeFolder(named: String, files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-bundle-folder-\(UUID().uuidString)/\(named)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (rel, body) in files {
            let target = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(body.utf8).write(to: target)
        }
        stagingPaths.append(dir.deletingLastPathComponent())
        return dir
    }

    private func makeZip(named: String, contents: [String: String]) throws -> URL {
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-bundle-zip-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        stagingPaths.append(stage)
        for (rel, body) in contents {
            let target = stage.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(body.utf8).write(to: target)
        }
        let zipURL = stage.deletingLastPathComponent()
            .appendingPathComponent("\(named).zip")
        let entries = try FileManager.default.contentsOfDirectory(atPath: stage.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", zipURL.path] + entries
        process.currentDirectoryURL = stage
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip command failed")
        stagingPaths.append(zipURL)
        return zipURL
    }

    // MARK: - Tests

    private var expectedAppDir: URL {
        // schema-v3 Bundle layout: data lives at
        // <bundle>/System/drive_c/Program Files/<programName>/
        bundleURL.appendingPathComponent("System")
            .appendingPathComponent("drive_c")
            .appendingPathComponent("Program Files")
            .appendingPathComponent("BundleTest")  // == sampleConfig's name
    }

    func testBundleFolderDropsContentsIntoProgramFiles() async throws {
        let folder = try makeFolder(named: "MyGame", files: [
            "start.exe": "exe-bytes",
            "data/foo.dat": "data-bytes"
        ])
        let result = try await Installer().run(
            source: .folder(folder),
            mode: .bundle,
            baseConfig: sampleConfig("start.exe"),
            bundleURL: bundleURL
        )

        XCTAssertEqual(result.mode, .bundle)

        // cider.json sits next to Contents/, not inside it.
        XCTAssertEqual(result.configFileURL,
                       bundleURL.appendingPathComponent("cider.json"))

        let written = try CiderConfig.read(from: result.configFileURL)
        XCTAssertEqual(written.applicationPath,
                       "System/drive_c/Program Files/BundleTest")
        XCTAssertEqual(written.prefixPath, "System")

        // Bundle mode drops the source folder NAME — contents land
        // directly under Program Files/<programName>/. The exe field
        // is therefore relative to that directory.
        let copiedExe = expectedAppDir.appendingPathComponent("start.exe")
        let copiedData = expectedAppDir.appendingPathComponent("data/foo.dat")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedExe.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedData.path))

        // Resolving the exe through the in-bundle cider.json lands on
        // the copied file.
        XCTAssertEqual(written.resolvedExecutable(configFile: result.configFileURL).path,
                       copiedExe.standardizedFileURL.path)
        // resolvedPrefixDirectory points at the in-bundle System/.
        XCTAssertEqual(written.resolvedPrefixDirectory(configFile: result.configFileURL)?.path,
                       bundleURL.appendingPathComponent("System").path)
    }

    func testBundleZipWithTopLevelDirPreservesIt() async throws {
        let zip = try makeZip(named: "MyGame", contents: [
            "MyGame/start.exe": "exe-bytes",
            "MyGame/data/foo.dat": "data-bytes"
        ])
        _ = try await Installer().run(
            source: .zip(zip),
            mode: .bundle,
            baseConfig: sampleConfig("MyGame/start.exe"),
            bundleURL: bundleURL
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: expectedAppDir.appendingPathComponent("MyGame/start.exe").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: expectedAppDir.appendingPathComponent("MyGame/data/foo.dat").path))
    }

    func testBundleZipWithFlatContentsLandsAtProgramFilesRoot() async throws {
        let zip = try makeZip(named: "Flat", contents: [
            "start.exe": "exe-bytes",
            "lib.dll": "dll-bytes"
        ])
        let result = try await Installer().run(
            source: .zip(zip),
            mode: .bundle,
            baseConfig: sampleConfig("start.exe"),
            bundleURL: bundleURL
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: expectedAppDir.appendingPathComponent("start.exe").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: expectedAppDir.appendingPathComponent("lib.dll").path))

        let written = try CiderConfig.read(from: result.configFileURL)
        XCTAssertEqual(written.resolvedExecutable(configFile: result.configFileURL)
                       .standardizedFileURL.path,
                       expectedAppDir.appendingPathComponent("start.exe")
                       .standardizedFileURL.path)
    }

    func testBundleReplacesExistingApplicationContent() async throws {
        // Pre-seed the new layout's data dir with stale content.
        try FileManager.default.createDirectory(
            at: expectedAppDir, withIntermediateDirectories: true)
        try Data("stale".utf8).write(
            to: expectedAppDir.appendingPathComponent("STALE_MARKER"))

        let folder = try makeFolder(named: "Fresh", files: ["start.exe": "fresh"])
        _ = try await Installer().run(
            source: .folder(folder),
            mode: .bundle,
            baseConfig: sampleConfig("start.exe"),
            bundleURL: bundleURL
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: expectedAppDir.appendingPathComponent("STALE_MARKER").path),
            "previous Program Files content must be cleared on re-bundle")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: expectedAppDir.appendingPathComponent("start.exe").path))
    }

    func testBundleDoesNotTouchContents() async throws {
        // Drop a sentinel file under Contents/ — Bundle mode must leave it
        // alone, since touching Contents/ would invalidate codesign +
        // notarization.
        let contentsDir = bundleURL.appendingPathComponent("Contents")
        let sentinel = contentsDir.appendingPathComponent("SENTINEL")
        try Data("do-not-touch".utf8).write(to: sentinel)

        let folder = try makeFolder(named: "Game", files: ["start.exe": "x"])
        _ = try await Installer().run(
            source: .folder(folder),
            mode: .bundle,
            baseConfig: sampleConfig("Game/start.exe"),
            bundleURL: bundleURL
        )

        XCTAssertEqual(try Data(contentsOf: sentinel),
                       Data("do-not-touch".utf8),
                       "Bundle mode must not modify Contents/")
    }

}
