import XCTest
@testable import CiderModels

final class CiderConfigTests: XCTestCase {
    private func sampleConfig() -> CiderConfig {
        CiderConfig(
            displayName: "Test Game",
            applicationPath: "MyGame",
            exe: "Game.exe",
            args: ["/tui", "/log"],
            engine: .init(
                name: "WS12WineCX24.0.7_7",
                url: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineCX24.0.7_7.tar.xz"
            ),
            graphics: .dxmt,
            wine: .init(esync: true, msync: true, console: true, inheritConsole: false),
            splash: .init(file: "splash.png", transparent: true),
            icon: "icon.icns",
            originURL: "https://example.org/games/test.cider.json"
        )
    }

    func testRoundTrip() throws {
        let original = sampleConfig()
        let data = try original.encoded()
        let decoded = try CiderConfig.decode(data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.schemaVersion, 2)
    }

    func testJSONIsHumanEditable() throws {
        let cfg = sampleConfig()
        let data = try cfg.encoded()
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"displayName\""))
        XCTAssertTrue(s.contains("\"applicationPath\""))
        XCTAssertTrue(s.contains("\"Test Game\""))
        XCTAssertTrue(s.contains("\n"))
        // Sorted keys → "applicationPath" before "displayName".
        let appIdx = s.range(of: "\"applicationPath\"")!.lowerBound
        let nameIdx = s.range(of: "\"displayName\"")!.lowerBound
        XCTAssertLessThan(appIdx, nameIdx)
    }

    func testWriteAndRead() throws {
        let cfg = sampleConfig()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try cfg.write(to: url)
        let read = try CiderConfig.read(from: url)
        XCTAssertEqual(read, cfg)
    }

    func testApplicationDirectoryRelativeIsResolvedAgainstConfigDir() {
        let cfg = sampleConfig()
        let configFile = URL(fileURLWithPath: "/Users/me/Library/Application Support/Cider/Configs/Test Game.json")
        let resolved = cfg.resolvedApplicationDirectory(configFile: configFile)
        XCTAssertEqual(resolved.path,
                       "/Users/me/Library/Application Support/Cider/Configs/MyGame")
    }

    func testApplicationDirectoryAbsoluteIsReturnedAsIs() {
        var cfg = sampleConfig()
        cfg.applicationPath = "/Users/me/Games/MyGame"
        let configFile = URL(fileURLWithPath: "/somewhere/else/cider.json")
        let resolved = cfg.resolvedApplicationDirectory(configFile: configFile)
        XCTAssertEqual(resolved.path, "/Users/me/Games/MyGame")
    }

    func testResolvedExecutableJoinsExeUnderApplicationDir() {
        let cfg = sampleConfig()
        let configFile = URL(fileURLWithPath: "/tmp/cider.json")
        let exe = cfg.resolvedExecutable(configFile: configFile)
        XCTAssertEqual(exe.path, "/tmp/MyGame/Game.exe")
    }

    func testDefaultWineOptions() {
        let opts = CiderConfig.WineOptions.default
        XCTAssertTrue(opts.esync)
        XCTAssertTrue(opts.msync)
        XCTAssertFalse(opts.useWinedbg)
        XCTAssertFalse(opts.console)
        XCTAssertFalse(opts.inheritConsole)
    }

    func testDefaultTemplateRefMatchesPlannedVersion() {
        let t = CiderConfig.TemplateRef.default
        XCTAssertEqual(t.version, "1.0.11")
        XCTAssertTrue(t.url.contains("Sikarugir-App/Wrapper"))
    }
}
