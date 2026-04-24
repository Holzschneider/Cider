import XCTest
@testable import CiderModels
@testable import CiderCore

final class InstallerURLSourceTests: XCTestCase {
    private var displayName: String = ""
    private var server: LocalHTTPServer?
    private var stagingPaths: [URL] = []

    override func setUp() {
        super.setUp()
        displayName = "URLSrcTest-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        server?.stop()
        server = nil
        for url in stagingPaths {
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

    private func makeZip(named: String, contents: [String: String]) throws -> URL {
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-url-zip-\(UUID().uuidString)",
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
        XCTAssertEqual(process.terminationStatus, 0)
        stagingPaths.append(zipURL)
        return zipURL
    }

    // MARK: - Tests

    func testInstallURLDownloadsZipAndExtracts() async throws {
        let zipPath = try makeZip(named: "Game", contents: [
            "Game/start.exe": "exe-bytes",
            "Game/data/foo.dat": "data-bytes"
        ])
        let zipBytes = try Data(contentsOf: zipPath)

        let server = try LocalHTTPServer(routes: [
            "/game.zip": .init(body: zipBytes, contentType: "application/zip")
        ])
        try server.start()
        self.server = server

        let url = server.url(for: "game.zip")
        let result = try await Installer().run(
            source: .url(url),
            mode: .install,
            baseConfig: sampleConfig("Game/start.exe"),
            bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
        )

        let target = AppSupport.programFiles(forBundleNamed: displayName)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("Game/start.exe").path))

        // The persisted cider.json records the original URL as
        // distributionURL — origin stays nil since the URL was a zip,
        // not a cider.json indirection.
        let written = try CiderConfig.read(from: result.configFileURL)
        XCTAssertEqual(written.distributionURL, url.absoluteString)
        XCTAssertNil(written.originURL)
    }

    func testInstallURLFollowsCiderJSONIndirection() async throws {
        let zipPath = try makeZip(named: "Game", contents: [
            "Game/start.exe": "exe-bytes"
        ])
        let zipBytes = try Data(contentsOf: zipPath)

        // Start the server first so we know the real URL the manifest
        // must reference.
        let server = try LocalHTTPServer()
        try server.start()
        self.server = server
        server.setRoute("/game.zip", response: .init(body: zipBytes, contentType: "application/zip"))

        let zipURL = server.url(for: "game.zip")
        let manifest = CiderConfig(
            displayName: "from-manifest",
            applicationPath: "PLACEHOLDER",
            exe: "Game/start.exe",
            engine: .init(name: "WS12WineCX24.0.7_7",
                          url: "https://example.com/x.tar.xz"),
            graphics: .dxmt,
            distributionURL: zipURL.absoluteString
        )
        server.setRoute("/cider.json",
                        response: .init(body: try manifest.encoded(),
                                        contentType: "application/json"))

        let manifestURL = server.url(for: "cider.json")
        let result = try await Installer().run(
            source: .url(manifestURL),
            mode: .install,
            baseConfig: sampleConfig("Game/start.exe"),
            bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
        )

        let target = AppSupport.programFiles(forBundleNamed: displayName)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("Game/start.exe").path))

        let written = try CiderConfig.read(from: result.configFileURL)
        XCTAssertEqual(written.originURL, manifestURL.absoluteString,
                       "originURL must point at the dropped cider.json URL")
        XCTAssertEqual(written.distributionURL, zipURL.absoluteString,
                       "distributionURL must point at the indirect zip URL")
    }

    func testInstallURLFailsWhenCiderJSONHasNoDistributionURL() async throws {
        // Manifest with no distributionURL → resolver should refuse.
        let badManifest = CiderConfig(
            displayName: "no-data",
            applicationPath: "X",
            exe: "x.exe",
            engine: .init(name: "WS12WineCX24.0.7_7", url: "https://example.com/x.tar.xz"),
            graphics: .dxmt
        )
        let manifestBytes = try badManifest.encoded()

        let server = try LocalHTTPServer(routes: [
            "/cider.json": .init(body: manifestBytes, contentType: "application/json")
        ])
        try server.start()
        self.server = server

        let url = server.url(for: "cider.json")
        do {
            _ = try await Installer().run(
                source: .url(url),
                mode: .install,
                baseConfig: sampleConfig("Game.exe"),
                bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
            )
            XCTFail("expected ciderJSONWithoutDistributionURL")
        } catch URLSourceResolver.Error.ciderJSONWithoutDistributionURL {
            // expected
        } catch {
            XCTFail("expected ciderJSONWithoutDistributionURL, got \(error)")
        }
    }

    func testLinkRejectsURLSource() async {
        // Link still requires a local folder; URL must be rejected
        // *before* any download happens.
        let url = URL(string: "https://example.org/game.zip")!
        do {
            _ = try await Installer().run(
                source: .url(url),
                mode: .link,
                baseConfig: sampleConfig("Game.exe"),
                bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
            )
            XCTFail("expected linkRequiresFolderSource")
        } catch Installer.Error.linkRequiresFolderSource {
            // expected
        } catch {
            XCTFail("expected linkRequiresFolderSource, got \(error)")
        }
    }
}
