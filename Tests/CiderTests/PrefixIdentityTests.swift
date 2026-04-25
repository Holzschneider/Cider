import XCTest
@testable import CiderModels
@testable import CiderCore

final class PrefixIdentityTests: XCTestCase {

    private func cfg(
        engineName: String = "WS12WineCX24.0.7_7",
        engineURL: String  = "https://example.com/engine.tar.xz",
        graphics: GraphicsDriverKind = .dxmt,
        esync: Bool = true,
        msync: Bool = true,
        winetricks: [String] = [],
        // These are explicitly NOT supposed to perturb the hash; tests
        // sweep them through varied values to assert independence.
        displayName: String = "MyGame",
        applicationPath: String = "/path/x",
        exe: String = "Game.exe",
        args: [String] = [],
        icon: String? = nil
    ) -> CiderConfig {
        CiderConfig(
            displayName: displayName,
            applicationPath: applicationPath,
            exe: exe,
            args: args,
            engine: .init(name: engineName, url: engineURL),
            graphics: graphics,
            wine: .init(esync: esync, msync: msync, winetricks: winetricks),
            icon: icon
        )
    }

    // MARK: - Stable hash

    func testStableForEquivalentConfigs() {
        let a = PrefixIdentity.compute(for: cfg())
        let b = PrefixIdentity.compute(for: cfg())
        XCTAssertEqual(a.key, b.key)
    }

    func testWinetricksOrderDoesNotAffectHash() {
        let a = PrefixIdentity.compute(for: cfg(winetricks: ["corefonts", "vcrun2019"]))
        let b = PrefixIdentity.compute(for: cfg(winetricks: ["vcrun2019", "corefonts"]))
        XCTAssertEqual(a.key, b.key,
                       "winetricks verbs should be sorted before hashing")
    }

    func testIgnoredFieldsDoNotChangeHash() {
        let baseline = PrefixIdentity.compute(for: cfg()).key
        XCTAssertEqual(PrefixIdentity.compute(for: cfg(displayName: "Other")).key, baseline)
        XCTAssertEqual(PrefixIdentity.compute(for: cfg(applicationPath: "/different/path")).key, baseline)
        XCTAssertEqual(PrefixIdentity.compute(for: cfg(exe: "OtherGame.exe")).key, baseline)
        XCTAssertEqual(PrefixIdentity.compute(for: cfg(args: ["/tui"])).key, baseline)
        XCTAssertEqual(PrefixIdentity.compute(for: cfg(icon: "icon.png")).key, baseline)
    }

    // MARK: - Sensitivity

    func testEngineNameChangesHash() {
        let a = PrefixIdentity.compute(for: cfg(engineName: "WS12WineCX24.0.7_7"))
        let b = PrefixIdentity.compute(for: cfg(engineName: "WS12WineCX24.0.8_0"))
        XCTAssertNotEqual(a.key, b.key)
    }

    func testEngineURLChangesHash() {
        let a = PrefixIdentity.compute(for: cfg(engineURL: "https://example.com/a.tar.xz"))
        let b = PrefixIdentity.compute(for: cfg(engineURL: "https://example.com/b.tar.xz"))
        XCTAssertNotEqual(a.key, b.key)
    }

    func testGraphicsChangesHash() {
        let a = PrefixIdentity.compute(for: cfg(graphics: .dxmt))
        let b = PrefixIdentity.compute(for: cfg(graphics: .d3dmetal))
        XCTAssertNotEqual(a.key, b.key)
    }

    func testEsyncMsyncChangeHash() {
        let baseline = PrefixIdentity.compute(for: cfg(esync: true, msync: true)).key
        XCTAssertNotEqual(PrefixIdentity.compute(for: cfg(esync: false, msync: true)).key, baseline)
        XCTAssertNotEqual(PrefixIdentity.compute(for: cfg(esync: true, msync: false)).key, baseline)
    }

    func testWinetricksContentChangesHash() {
        let a = PrefixIdentity.compute(for: cfg(winetricks: ["corefonts"]))
        let b = PrefixIdentity.compute(for: cfg(winetricks: ["corefonts", "vcrun2019"]))
        XCTAssertNotEqual(a.key, b.key)
    }

    // MARK: - Filesystem-safe key

    func testKeyIsFilesystemSafe() {
        // Engine names with spaces / slashes / shell metacharacters
        // mustn't bleed into the AppSupport path.
        let id = PrefixIdentity.compute(for: cfg(
            engineName: "Wine 1.0 / experimental: build*",
            graphics: .dxmt
        ))
        XCTAssertFalse(id.key.contains("/"))
        XCTAssertFalse(id.key.contains(" "))
        XCTAssertFalse(id.key.contains(":"))
        XCTAssertFalse(id.key.contains("*"))
        XCTAssertTrue(id.key.contains("dxmt"))
    }

    // MARK: - LaunchPipeline.selectPrefix wiring

    func testSelectPrefixHonoursInBundlePrefixPath() throws {
        var c = cfg()
        c.prefixPath = "System"
        let configURL = URL(fileURLWithPath: "/tmp/Test.app/cider.json")
        let prefix = LaunchPipeline.selectPrefix(config: c, configFile: configURL)
        XCTAssertEqual(prefix.standardizedFileURL.path,
                       "/tmp/Test.app/System")
    }

    func testSelectPrefixFallsBackToHashKeyedAppSupport() throws {
        let c = cfg()  // no prefixPath
        let configURL = URL(fileURLWithPath: "/tmp/whatever.json")
        let prefix = LaunchPipeline.selectPrefix(config: c, configFile: configURL)
        let identity = PrefixIdentity.compute(for: c)
        XCTAssertEqual(prefix.standardizedFileURL.path,
                       AppSupport.prefix(forIdentityKey: identity.key)
                            .standardizedFileURL.path)
    }
}
