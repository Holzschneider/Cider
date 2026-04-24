import XCTest
@testable import CiderModels
@testable import CiderCore

final class InstallerLinkTests: XCTestCase {
    private func tmpFolder(named: String = "MyGame") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-install-\(UUID().uuidString)/\(named)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("Game.exe"))
        return dir
    }

    private func sampleConfig(_ displayName: String) -> CiderConfig {
        CiderConfig(
            displayName: displayName,
            applicationPath: "PLACEHOLDER",
            exe: "Game.exe",
            engine: .init(name: "WS12WineCX24.0.7_7",
                          url: "https://example.com/x.tar.xz"),
            graphics: .dxmt
        )
    }

    func testLinkWritesConfigWithAbsoluteApplicationPath() async throws {
        let folder = try tmpFolder(named: "MyGame")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let displayName = "InstallerLinkTest-\(UUID().uuidString.prefix(8))"
        let result = try await Installer().run(
            source: .folder(folder),
            mode: .link,
            baseConfig: sampleConfig(String(displayName)),
            bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
        )
        defer {
            try? FileManager.default.removeItem(at: result.configFileURL)
            try? FileManager.default.removeItem(at: AppSupport.programFiles(forBundleNamed: String(displayName)))
        }

        // cider.json was written to the conventional Configs path.
        XCTAssertEqual(result.mode, .link)
        XCTAssertEqual(result.configFileURL.lastPathComponent, "\(displayName).json")
        XCTAssertTrue(result.configFileURL.path.contains("/Application Support/Cider/Configs/"))

        // applicationPath is the absolute path to the original folder.
        XCTAssertEqual(result.applicationPath, folder.standardizedFileURL.path)

        // The on-disk config matches what we computed.
        let written = try CiderConfig.read(from: result.configFileURL)
        XCTAssertEqual(written.applicationPath, folder.standardizedFileURL.path)
        XCTAssertEqual(written.displayName, String(displayName))
        // The cider.json's applicationPath resolves to the original folder.
        XCTAssertEqual(written.resolvedApplicationDirectory(configFile: result.configFileURL).path,
                       folder.standardizedFileURL.path)

        // Marker directory under Program Files/.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: AppSupport.programFiles(forBundleNamed: String(displayName)).path))
    }

    func testLinkRejectsZipSource() async {
        let url = URL(fileURLWithPath: "/tmp/MyGame.zip")
        do {
            _ = try await Installer().run(
                source: .zip(url),
                mode: .link,
                baseConfig: sampleConfig("X"),
                bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
            )
            XCTFail("expected linkRequiresFolderSource to throw")
        } catch Installer.Error.linkRequiresFolderSource {
            // expected
        } catch {
            XCTFail("expected linkRequiresFolderSource, got \(error)")
        }
    }

    func testLinkRejectsMissingFolder() async {
        let missing = URL(fileURLWithPath: "/tmp/cider-does-not-exist-\(UUID().uuidString)")
        do {
            _ = try await Installer().run(
                source: .folder(missing),
                mode: .link,
                baseConfig: sampleConfig("X"),
                bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
            )
            XCTFail("expected sourceFolderMissing to throw")
        } catch Installer.Error.sourceFolderMissing {
            // expected
        } catch {
            XCTFail("expected sourceFolderMissing, got \(error)")
        }
    }

    // Install mode landed in Phase 3; Bundle is still notYetImplemented
    // until Phase 4.
    func testBundleIsNotYetImplemented() async {
        do {
            _ = try await Installer().run(
                source: .folder(URL(fileURLWithPath: "/tmp")),
                mode: .bundle,
                baseConfig: sampleConfig("X"),
                bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
            )
            XCTFail("expected notYetImplemented for bundle")
        } catch Installer.Error.notYetImplemented(let m) {
            XCTAssertEqual(m, .bundle)
        } catch {
            XCTFail("expected notYetImplemented for bundle, got \(error)")
        }
    }
}
