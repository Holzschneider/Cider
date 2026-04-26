import XCTest
@testable import CiderModels
@testable import CiderApp

final class ConfigSummaryTests: XCTestCase {

    private func cfg(
        displayName: String = "MyApp",
        applicationPath: String = "/Users/me/MyApp",
        exe: String = "Game.exe",
        args: [String] = [],
        engineName: String = "WS12WineCX24.0.7_7",
        graphics: GraphicsDriverKind = .dxmt,
        wine: CiderConfig.WineOptions = .default,
        splash: CiderConfig.Splash? = nil,
        icon: String? = nil,
        originURL: String? = nil,
        distributionURL: String? = nil
    ) -> CiderConfig {
        CiderConfig(
            displayName: displayName,
            applicationPath: applicationPath,
            exe: exe,
            args: args,
            engine: .init(name: engineName, url: "https://example.com/e.tar.xz"),
            graphics: graphics,
            wine: wine,
            splash: splash,
            icon: icon,
            originURL: originURL,
            distributionURL: distributionURL
        )
    }

    // MARK: - Heading + always-on lines

    func testHeadingIsTheDisplayName() {
        let s = ConfigSummary.summary(for: cfg(displayName: "RagnarokPlus"))
        XCTAssertEqual(s.heading, "RagnarokPlus")
    }

    func testFirstLineIsModeAndGraphics() {
        let s = ConfigSummary.summary(for: cfg(applicationPath: "/abs", graphics: .d3dmetal))
        XCTAssertEqual(s.lines.first, "Link · D3DMetal")
    }

    // MARK: - Mode inference

    func testInstallModeForRelativePath() {
        let s = ConfigSummary.summary(for: cfg(applicationPath: "MyApp"))
        XCTAssertTrue(s.lines.first?.hasPrefix("Install · ") == true)
    }

    func testBundleModeForApplicationPrefix() {
        let s = ConfigSummary.summary(for: cfg(applicationPath: "Application"))
        XCTAssertTrue(s.lines.first?.hasPrefix("Bundle · ") == true)
    }

    func testBundleModeForSystemPrefix() {
        let s = ConfigSummary.summary(for: cfg(
            applicationPath: "System/drive_c/Program Files/MyApp"))
        XCTAssertTrue(s.lines.first?.hasPrefix("Bundle · ") == true)
    }

    // MARK: - Exe basename only

    func testExeShownAsBasenameOnly() {
        let s = ConfigSummary.summary(for: cfg(exe: "MyApp/sub/dir/Game.exe"))
        XCTAssertTrue(s.lines.contains("Game.exe"),
                      "exe should be reduced to its filename, not the relative path")
        XCTAssertFalse(s.lines.contains(where: { $0.contains("/") && $0 != s.lines.first }),
                       "no row should contain a path separator (mode/graphics line excluded)")
    }

    // MARK: - Defaults are suppressed

    func testEmptyArgsDoesNotAddLine() {
        let s = ConfigSummary.summary(for: cfg(args: []))
        XCTAssertFalse(s.lines.contains(where: { $0.hasPrefix("args:") }))
    }

    func testNonEmptyArgsAddsLine() {
        let s = ConfigSummary.summary(for: cfg(args: ["/tui", "/log"]))
        XCTAssertTrue(s.lines.contains("args: /tui /log"))
    }

    func testDefaultWineOmitsTheWineLine() {
        let s = ConfigSummary.summary(for: cfg(wine: .default))
        // No row mentioning esync / msync / console / winedbg.
        XCTAssertFalse(s.lines.contains(where: {
            $0.contains("esync") || $0.contains("msync") ||
            $0.contains("console") || $0.contains("winedbg") ||
            $0.contains("tricks")
        }))
    }

    func testWineConsoleOnlyShowsConsole() {
        let w = CiderConfig.WineOptions(esync: true, msync: true,
                                        useWinedbg: false,
                                        winetricks: [],
                                        console: true,
                                        inheritConsole: false)
        let s = ConfigSummary.summary(for: cfg(wine: w))
        XCTAssertTrue(s.lines.contains("console"))
    }

    func testWineCombinedNonDefaultsJoinWithMiddot() {
        let w = CiderConfig.WineOptions(esync: false, msync: false,
                                        useWinedbg: true,
                                        winetricks: ["corefonts"],
                                        console: true,
                                        inheritConsole: true)
        let s = ConfigSummary.summary(for: cfg(wine: w))
        let wineLine = s.lines.first(where: { $0.contains("esync off") })
        XCTAssertNotNil(wineLine)
        XCTAssertTrue(wineLine?.contains("msync off") == true)
        XCTAssertTrue(wineLine?.contains("console") == true)
        XCTAssertTrue(wineLine?.contains("shared console") == true)
        XCTAssertTrue(wineLine?.contains("winedbg on") == true)
        XCTAssertTrue(wineLine?.contains("tricks: corefonts") == true)
        // Joined with " · "
        XCTAssertTrue(wineLine?.contains(" · ") == true)
    }

    // MARK: - Optional metadata rows

    func testSplashAddsRowWhenSet() {
        let s = ConfigSummary.summary(for: cfg(
            splash: .init(file: "splash.png")))
        XCTAssertTrue(s.lines.contains("custom splash"))
    }

    func testSplashOmittedWhenNil() {
        let s = ConfigSummary.summary(for: cfg(splash: nil))
        XCTAssertFalse(s.lines.contains("custom splash"))
    }

    func testIconAddsRowWhenSet() {
        let s = ConfigSummary.summary(for: cfg(icon: "icon.icns"))
        XCTAssertTrue(s.lines.contains("custom icon"))
    }

    func testFromURLRowWhenOriginSet() {
        let s = ConfigSummary.summary(for: cfg(
            originURL: "https://example.org/cider.json"))
        XCTAssertTrue(s.lines.contains("from URL"))
    }

    func testFromURLRowWhenDistributionSet() {
        let s = ConfigSummary.summary(for: cfg(
            distributionURL: "https://example.org/Game.zip"))
        XCTAssertTrue(s.lines.contains("from URL"))
    }

    // MARK: - Engine + graphics labels

    func testEngineNameAppearsAsItsOwnLine() {
        let s = ConfigSummary.summary(for: cfg(engineName: "Whisky-1.2.3"))
        XCTAssertTrue(s.lines.contains("Whisky-1.2.3"))
    }

    func testGraphicsLabelsAreUppercase() {
        let dxmt = ConfigSummary.summary(for: cfg(graphics: .dxmt)).lines.first ?? ""
        let dx12 = ConfigSummary.summary(for: cfg(graphics: .d3dmetal)).lines.first ?? ""
        let dxvk = ConfigSummary.summary(for: cfg(graphics: .dxvk)).lines.first ?? ""
        XCTAssertTrue(dxmt.hasSuffix("DXMT"))
        XCTAssertTrue(dx12.hasSuffix("D3DMetal"))
        XCTAssertTrue(dxvk.hasSuffix("DXVK"))
    }
}
