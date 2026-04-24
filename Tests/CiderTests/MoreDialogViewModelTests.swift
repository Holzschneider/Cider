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
