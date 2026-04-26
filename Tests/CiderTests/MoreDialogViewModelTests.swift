import XCTest
@testable import CiderModels
@testable import CiderCore
@testable import CiderApp

@MainActor
final class MoreDialogViewModelTests: XCTestCase {

    // MARK: - Round-trip

    func testRoundTripsThroughLoadAndBuildConfig() {
        let original = CiderConfig(
            displayName: "Test Game",
            applicationPath: "MyGame",
            exe: "Game/Game.exe",
            args: ["/tui", "/log"],
            engine: .init(
                name: "WS12WineCX24.0.7_7",
                url: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineCX24.0.7_7.tar.xz",
                sha256: "cafefeed"
            ),
            graphics: .dxmt,
            wine: .init(esync: true, msync: true, useWinedbg: false,
                        winetricks: ["corefonts", "vcrun2019"],
                        console: true, inheritConsole: false),
            splash: .init(file: "splash.png", transparent: true),
            loading: .init(enabled: true, source: .logFile,
                           logFilePath: "logs/startup.log",
                           expectedLineCount: 1200,
                           autoHideOnTarget: true),
            icon: "icon.icns",
            originURL: "https://example.org/cider.json"
        )
        let vm = MoreDialogViewModel()
        vm.load(from: original)
        let rebuilt = vm.buildConfig()
        XCTAssertEqual(rebuilt.displayName, original.displayName)
        // applicationPath round-trips for Install/Bundle (we keep the
        // existing value when the user hasn't dropped a fresh source).
        XCTAssertEqual(rebuilt.applicationPath, original.applicationPath)
        XCTAssertEqual(rebuilt.exe, original.exe)
        XCTAssertEqual(rebuilt.args, original.args)
        XCTAssertEqual(rebuilt.engine, original.engine)
        XCTAssertEqual(rebuilt.graphics, original.graphics)
        XCTAssertEqual(rebuilt.wine, original.wine)
        XCTAssertEqual(rebuilt.splash, original.splash)
        XCTAssertEqual(rebuilt.loading, original.loading)
        XCTAssertEqual(rebuilt.icon, original.icon)
        XCTAssertEqual(rebuilt.originURL, original.originURL)
    }

    // MARK: - Mode inference

    func testInferModeFromApplicationPath() {
        XCTAssertEqual(MoreDialogViewModel.inferMode(from: "/Users/me/Game"), .link)
        XCTAssertEqual(MoreDialogViewModel.inferMode(from: "~/Games/Foo"), .link)
        XCTAssertEqual(MoreDialogViewModel.inferMode(from: "Application"), .bundle)
        XCTAssertEqual(MoreDialogViewModel.inferMode(from: "Application/MyGame"), .bundle)
        XCTAssertEqual(MoreDialogViewModel.inferMode(from: "MyGame"), .install)
        XCTAssertEqual(MoreDialogViewModel.inferMode(from: ""), .install)
    }

    func testLoadInfersInstallModeFromApplicationPath() {
        let vm = MoreDialogViewModel()
        vm.load(from: sampleConfig(applicationPath: "/Users/me/Game"))
        XCTAssertEqual(vm.installMode, .link)
        XCTAssertEqual(vm.sourcePath, "/Users/me/Game",
                       "Link mode mirrors applicationPath into sourcePath")

        vm.load(from: sampleConfig(applicationPath: "Application/MyGame"))
        XCTAssertEqual(vm.installMode, .bundle)
        XCTAssertEqual(vm.sourcePath, "",
                       "Bundle/Install don't mirror applicationPath — source is empty until user drops a new one")

        vm.load(from: sampleConfig(applicationPath: "MyGame"))
        XCTAssertEqual(vm.installMode, .install)
    }

    // MARK: - Validity

    func testIsValidRequiresDisplayNameAndExeAndEngineAndSource() {
        let vm = MoreDialogViewModel()
        XCTAssertFalse(vm.isValid)

        vm.displayName = "Foo"
        vm.exe = "Foo.exe"
        vm.engineName = "WS12WineCX24.0.7_7"
        vm.engineURL = "https://example.com/e.tar.xz"
        // Mode = install (default), no source, no applicationPath → invalid.
        XCTAssertFalse(vm.isValid)

        // Adding a previously-installed applicationPath satisfies Install mode.
        vm.applicationPath = "MyGame"
        XCTAssertTrue(vm.isValid)
    }

    func testLinkModeRequiresFolderSource() {
        let vm = MoreDialogViewModel()
        vm.displayName = "Foo"
        vm.exe = "Foo.exe"
        vm.engineName = "WS12WineCX24.0.7_7"
        vm.engineURL = "https://example.com/e.tar.xz"
        vm.installMode = .link

        // A non-existent path → not a folder → invalid.
        vm.sourcePath = "/tmp/cider-test-\(UUID().uuidString)"
        XCTAssertFalse(vm.isValid)

        // A real folder → valid.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-link-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.sourcePath = dir.path
        XCTAssertTrue(vm.isValid)

        // A URL → not a folder → invalid for Link.
        vm.sourcePath = "https://example.org/game.zip"
        XCTAssertFalse(vm.isValid)
    }

    // MARK: - Source acquisition

    func testSourceAcquisitionRecognisesFolderZipAndURL() throws {
        let vm = MoreDialogViewModel()

        // URL
        vm.sourcePath = "https://example.org/game.zip"
        if case .url(let url) = vm.sourceAcquisition {
            XCTAssertEqual(url.absoluteString, "https://example.org/game.zip")
        } else {
            XCTFail("expected .url")
        }

        // Folder
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-vm-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.sourcePath = dir.path
        if case .folder(let url) = vm.sourceAcquisition {
            XCTAssertEqual(url.path, dir.path)
        } else {
            XCTFail("expected .folder")
        }

        // Zip (the file doesn't need to exist as a real zip — only the
        // extension matters for source-kind detection. But it does need
        // to exist on disk.)
        let zip = dir.appendingPathComponent("fake.zip")
        try Data().write(to: zip)
        vm.sourcePath = zip.path
        if case .zip(let url) = vm.sourceAcquisition {
            XCTAssertEqual(url.path, zip.path)
        } else {
            XCTFail("expected .zip")
        }

        // Empty
        vm.sourcePath = ""
        XCTAssertNil(vm.sourceAcquisition)

        // Non-existent path
        vm.sourcePath = "/tmp/cider-does-not-exist-\(UUID().uuidString)"
        XCTAssertNil(vm.sourceAcquisition)
    }

    // MARK: - Drop seeding

    func testSeedFromDropFolderPicksLinkMode() {
        let vm = MoreDialogViewModel()
        let dropped = DropZoneViewModel.DroppedSource.folder(URL(fileURLWithPath: "/tmp/MyGame"))
        vm.seed(fromDrop: dropped)
        XCTAssertEqual(vm.sourcePath, "/tmp/MyGame")
        XCTAssertEqual(vm.displayName, "MyGame")
        XCTAssertEqual(vm.installMode, .link,
                       "folder drops default to Link — natural 'run from where it sits'")
    }

    func testSeedFromDropZipPicksInstallMode() {
        let vm = MoreDialogViewModel()
        let dropped = DropZoneViewModel.DroppedSource.zip(URL(fileURLWithPath: "/tmp/MyGame.zip"))
        vm.seed(fromDrop: dropped)
        XCTAssertEqual(vm.sourcePath, "/tmp/MyGame.zip")
        XCTAssertEqual(vm.displayName, "MyGame")
        XCTAssertEqual(vm.installMode, .install,
                       "zip can't be linked — pre-pick Install")
    }

    func testSeedFromDropURLPicksInstallMode() {
        let vm = MoreDialogViewModel()
        let dropped = DropZoneViewModel.DroppedSource.url(
            URL(string: "https://example.org/MyGame.zip")!
        )
        vm.seed(fromDrop: dropped)
        XCTAssertEqual(vm.sourcePath, "https://example.org/MyGame.zip")
        XCTAssertEqual(vm.installMode, .install)
    }

    // MARK: - Build (Link mirrors source into applicationPath)

    func testBuildLinkModeWritesSourceAsAbsoluteApplicationPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-build-link-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = MoreDialogViewModel()
        vm.displayName = "Foo"
        vm.exe = "Foo.exe"
        vm.engineName = "WS12WineCX24.0.7_7"
        vm.engineURL = "https://example.com/e.tar.xz"
        vm.installMode = .link
        vm.sourcePath = dir.path

        let cfg = vm.buildConfig()
        XCTAssertEqual(cfg.applicationPath, dir.path,
                       "Link mode mirrors sourcePath into applicationPath")
    }

    // MARK: - Per-field validation (Phase 9)

    func testPerFieldErrorsReturnHumanReadableMessages() {
        let vm = MoreDialogViewModel()
        XCTAssertNotNil(vm.displayNameError)
        XCTAssertNotNil(vm.exeError)
        XCTAssertNotNil(vm.engineNameError)
        XCTAssertNotNil(vm.engineURLError)
        XCTAssertNotNil(vm.sourceError)

        vm.displayName = "Foo"
        vm.exe = "Foo.exe"
        vm.engineName = "WS12WineCX24.0.7_7"
        vm.engineURL = "https://example.com/e.tar.xz"
        vm.applicationPath = "MyGame"  // existing-install satisfies Install mode

        XCTAssertNil(vm.displayNameError)
        XCTAssertNil(vm.exeError)
        XCTAssertNil(vm.engineNameError)
        XCTAssertNil(vm.engineURLError)
        XCTAssertNil(vm.sourceError)
    }

    func testEngineURLRequiresAScheme() {
        let vm = MoreDialogViewModel()
        vm.engineURL = "example.com/e.tar.xz"
        XCTAssertEqual(vm.engineURLError, "Engine URL must include a scheme (https://…).")

        vm.engineURL = "https://example.com/e.tar.xz"
        XCTAssertNil(vm.engineURLError)
    }

    func testSourceErrorIsModeAware() {
        let vm = MoreDialogViewModel()

        // Link mode rejects URLs.
        vm.installMode = .link
        vm.sourcePath = "https://example.org/game.zip"
        XCTAssertNotNil(vm.sourceError)

        // Install mode accepts URLs.
        vm.installMode = .install
        XCTAssertNil(vm.sourceError)

        // Install mode rejects nonsensical paths (not a folder, not a zip,
        // not a URL) when no existing applicationPath is around to satisfy it.
        vm.sourcePath = "/tmp/cider-bogus-\(UUID().uuidString)"
        XCTAssertNotNil(vm.sourceError)
    }

    func testGeneralErrorPropertyRoundTrips() {
        let vm = MoreDialogViewModel()
        XCTAssertNil(vm.generalError)
        vm.generalError = "Apply failed: HTTP 404"
        XCTAssertEqual(vm.generalError, "Apply failed: HTTP 404")
    }

    // MARK: - Reset

    func testResetToDefaultsClearsLoadedFields() {
        let original = CiderConfig(
            displayName: "Foo",
            applicationPath: "/Users/me/Foo",
            exe: "Foo.exe",
            args: ["/log"],
            engine: .init(name: "Custom", url: "https://example.com/c.tar.xz",
                          sha256: "deadbeef"),
            graphics: .dxvk,
            wine: .init(esync: false, msync: false, useWinedbg: true,
                        winetricks: ["corefonts"],
                        console: true, inheritConsole: true),
            splash: .init(file: "splash.png", transparent: false),
            icon: "icon.icns",
            originURL: "https://example.org/cider.json",
            distributionURL: "https://example.org/Foo.zip"
        )
        let vm = MoreDialogViewModel()
        vm.load(from: original)
        // Also seed external errors so we can verify Reset clears them.
        vm.generalError = "previous failure"
        vm.externalSourceError = "missing source"
        vm.externalExeError = "missing exe"

        vm.resetToDefaults()

        // Required-input fields are blank.
        XCTAssertEqual(vm.displayName, "")
        XCTAssertEqual(vm.exe, "")
        XCTAssertEqual(vm.argsText, "")
        XCTAssertEqual(vm.applicationPath, "")
        XCTAssertEqual(vm.sourcePath, "")
        XCTAssertEqual(vm.originURL, "")
        XCTAssertEqual(vm.installMode, .install)
        XCTAssertNil(vm.originalDisplayName,
                     "Reset should drop the post-load identity so a fresh save isn't seen as a rename")

        // Engine/template fields back to brand-new defaults.
        XCTAssertEqual(vm.engineName, "")
        XCTAssertEqual(vm.engineURL, "")
        XCTAssertEqual(vm.engineSha256, "")
        XCTAssertEqual(vm.useCustomRepository, false)
        XCTAssertEqual(vm.customRepositoryURL, "")
        XCTAssertEqual(vm.templateVersion, CiderConfig.TemplateRef.default.version)
        XCTAssertEqual(vm.templateURL, CiderConfig.TemplateRef.default.url)
        XCTAssertEqual(vm.templateSha256, "")

        // Graphics + wine + presentation back to defaults.
        XCTAssertEqual(vm.graphics, .defaultForThisMachine)
        XCTAssertEqual(vm.wineEsync, true)
        XCTAssertEqual(vm.wineMsync, true)
        XCTAssertEqual(vm.wineUseWinedbg, false)
        XCTAssertEqual(vm.wineConsole, false)
        XCTAssertEqual(vm.wineInheritConsole, false)
        XCTAssertEqual(vm.winetricksText, "")
        XCTAssertEqual(vm.splashFile, "")
        XCTAssertEqual(vm.splashTransparent, true)
        XCTAssertEqual(vm.iconFile, "")

        // Errors cleared.
        XCTAssertNil(vm.generalError)
        XCTAssertNil(vm.externalSourceError)
        XCTAssertNil(vm.externalExeError)
    }

    // MARK: - Helpers

    private func sampleConfig(applicationPath: String) -> CiderConfig {
        CiderConfig(
            displayName: "Sample",
            applicationPath: applicationPath,
            exe: "x.exe",
            engine: .init(name: "n", url: "https://example.com/e.tar.xz"),
            graphics: .dxmt
        )
    }
}
