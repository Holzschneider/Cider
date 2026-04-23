import XCTest
@testable import CiderModels

final class CiderConfigTests: XCTestCase {
    private func sampleConfig() -> CiderConfig {
        CiderConfig(
            displayName: "Test Game",
            exe: "Game/Game.exe",
            args: ["/tui", "/log"],
            source: .init(mode: .path, path: "/tmp/Game"),
            engine: .init(
                name: "WS12WineCX24.0.7_7",
                url: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineCX24.0.7_7.tar.xz"
            ),
            graphics: .dxmt,
            wine: .init(esync: true, msync: true, console: true, inheritConsole: false),
            splash: .init(file: "splash.png", transparent: true),
            icon: "icon.icns"
        )
    }

    func testRoundTrip() throws {
        let original = sampleConfig()
        let data = try original.encoded()
        let decoded = try CiderConfig.decode(data)
        XCTAssertEqual(decoded, original)
    }

    func testJSONIsHumanEditable() throws {
        let cfg = sampleConfig()
        let data = try cfg.encoded()
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"displayName\""))
        XCTAssertTrue(s.contains("\"Test Game\""))
        // pretty-printed = newlines + indentation
        XCTAssertTrue(s.contains("\n"))
        // sorted keys → "args" before "displayName"
        let argsIdx = s.range(of: "\"args\"")!.lowerBound
        let nameIdx = s.range(of: "\"displayName\"")!.lowerBound
        XCTAssertLessThan(argsIdx, nameIdx)
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
