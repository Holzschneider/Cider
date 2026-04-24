import XCTest
@testable import CiderModels
@testable import CiderCore

final class InstallerInstallTests: XCTestCase {
    private var displayName: String = ""
    private var installedPaths: [URL] = []

    override func setUp() {
        super.setUp()
        // Unique per-test display name so we don't collide with concurrent
        // runs OR with the user's real configured bundles.
        displayName = "InstallTest-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        for url in installedPaths {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(
            at: AppSupport.config(forBundleNamed: displayName))
        try? FileManager.default.removeItem(
            at: AppSupport.programFiles(forBundleNamed: displayName))
        super.tearDown()
    }

    // MARK: - Fixtures

    private func sampleConfig(_ exe: String) -> CiderConfig {
        CiderConfig(
            displayName: displayName,
            applicationPath: "PLACEHOLDER",
            exe: exe,
            engine: .init(name: "WS12WineCX24.0.7_7",
                          url: "https://example.com/x.tar.xz"),
            graphics: .dxmt
        )
    }

    private func makeFolder(named: String, files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-installer-folder-\(UUID().uuidString)/\(named)",
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
        installedPaths.append(dir.deletingLastPathComponent())
        return dir
    }

    private func makeZip(named: String, contents: [String: String]) throws -> URL {
        // Build the contents in a staging dir, then zip from there.
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-installer-zip-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        installedPaths.append(stage)
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
        // zip -r <out> <entries…> from inside stage so paths in the archive
        // are relative.
        let entries = try FileManager.default.contentsOfDirectory(atPath: stage.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", zipURL.path] + entries
        process.currentDirectoryURL = stage
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip command failed")
        installedPaths.append(zipURL)
        return zipURL
    }

    // MARK: - Tests

    func testInstallFolderCopiesIntoProgramFilesUnderSourceName() async throws {
        let folder = try makeFolder(named: "MyGame", files: [
            "start.exe": "exe-bytes",
            "data/foo.dat": "data-bytes"
        ])
        let result = try await Installer().run(
            source: .folder(folder),
            mode: .install,
            baseConfig: sampleConfig("MyGame/start.exe"),
            bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
        )

        XCTAssertEqual(result.mode, .install)

        let target = AppSupport.programFiles(forBundleNamed: displayName)
        XCTAssertEqual(result.applicationPath, target.standardizedFileURL.path)

        // The source folder name was preserved beneath the target.
        let copiedExe = target.appendingPathComponent("MyGame/start.exe")
        let copiedData = target.appendingPathComponent("MyGame/data/foo.dat")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedExe.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedData.path))

        // Re-resolving exe through the written cider.json lands on the
        // copied file.
        let written = try CiderConfig.read(from: result.configFileURL)
        XCTAssertEqual(written.resolvedExecutable(configFile: result.configFileURL).path,
                       copiedExe.standardizedFileURL.path)
    }

    func testInstallZipWithTopLevelDirPreservesIt() async throws {
        let zip = try makeZip(named: "MyGame", contents: [
            "MyGame/start.exe": "exe-bytes",
            "MyGame/data/foo.dat": "data-bytes"
        ])
        let result = try await Installer().run(
            source: .zip(zip),
            mode: .install,
            baseConfig: sampleConfig("MyGame/start.exe"),
            bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
        )

        let target = AppSupport.programFiles(forBundleNamed: displayName)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("MyGame/start.exe").path))
        XCTAssertEqual(result.applicationPath, target.standardizedFileURL.path)
    }

    func testInstallZipWithFlatContentsLandsAtRoot() async throws {
        let zip = try makeZip(named: "Flat", contents: [
            "start.exe": "exe-bytes",
            "lib.dll": "dll-bytes"
        ])
        let result = try await Installer().run(
            source: .zip(zip),
            mode: .install,
            baseConfig: sampleConfig("start.exe"),
            bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
        )

        let target = AppSupport.programFiles(forBundleNamed: displayName)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("start.exe").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("lib.dll").path))

        let written = try CiderConfig.read(from: result.configFileURL)
        XCTAssertEqual(written.resolvedExecutable(configFile: result.configFileURL)
                       .standardizedFileURL.path,
                       target.appendingPathComponent("start.exe")
                       .standardizedFileURL.path)
    }

    func testInstallReplacesExistingProgramFilesContent() async throws {
        // Pre-seed with stale data so we can verify it gets wiped.
        let target = AppSupport.programFiles(forBundleNamed: displayName)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: target.appendingPathComponent("STALE_MARKER"))

        let folder = try makeFolder(named: "Fresh", files: ["start.exe": "fresh"])
        _ = try await Installer().run(
            source: .folder(folder),
            mode: .install,
            baseConfig: sampleConfig("Fresh/start.exe"),
            bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("STALE_MARKER").path),
            "previous Program Files content must be cleared on re-install")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("Fresh/start.exe").path))
    }

    func testInstallRejectsURLSourceUntilPhase5() async {
        let url = URL(string: "https://example.org/game.zip")!
        do {
            _ = try await Installer().run(
                source: .url(url),
                mode: .install,
                baseConfig: sampleConfig("Game.exe"),
                bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
            )
            XCTFail("expected urlSourceRequiresPhase5")
        } catch Installer.Error.urlSourceRequiresPhase5 {
            // expected
        } catch {
            XCTFail("expected urlSourceRequiresPhase5, got \(error)")
        }
    }
}
