import XCTest
@testable import CiderModels
@testable import CiderApp

@MainActor
final class MoreDialogViewModelTests: XCTestCase {
    func testRoundTripsThroughLoadAndBuildConfig() {
        let original = CiderConfig(
            displayName: "Test Game",
            exe: "Game/Game.exe",
            args: ["/tui", "/log"],
            source: .init(mode: .url,
                          url: "https://example.com/x.zip",
                          sha256: "deadbeef"),
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
            icon: "icon.icns"
        )
        let vm = MoreDialogViewModel()
        vm.load(from: original)
        let rebuilt = vm.buildConfig()
        XCTAssertEqual(rebuilt.displayName, original.displayName)
        XCTAssertEqual(rebuilt.exe, original.exe)
        XCTAssertEqual(rebuilt.args, original.args)
        XCTAssertEqual(rebuilt.source.mode, original.source.mode)
        XCTAssertEqual(rebuilt.source.url, original.source.url)
        XCTAssertEqual(rebuilt.source.sha256, original.source.sha256)
        XCTAssertEqual(rebuilt.engine, original.engine)
        XCTAssertEqual(rebuilt.graphics, original.graphics)
        XCTAssertEqual(rebuilt.wine, original.wine)
        XCTAssertEqual(rebuilt.splash, original.splash)
        XCTAssertEqual(rebuilt.icon, original.icon)
    }

    func testInvalidUntilRequiredFieldsArePresent() {
        let vm = MoreDialogViewModel()
        XCTAssertFalse(vm.isValid)
        vm.displayName = "Foo"
        vm.exe = "Foo.exe"
        vm.engineName = "WS12WineCX24.0.7_7"
        vm.engineURL = "https://example.com/e.tar.xz"
        vm.sourceMode = .path
        vm.sourcePath = "/tmp/Foo"
        XCTAssertTrue(vm.isValid)

        vm.sourcePath = ""
        XCTAssertFalse(vm.isValid, "empty path in .path mode should invalidate")

        vm.sourceMode = .url
        vm.sourceURL = "https://example.com/x.zip"
        XCTAssertTrue(vm.isValid)
    }

    func testSeedFromDropFolderPopulatesPathAndName() {
        let vm = MoreDialogViewModel()
        let dropped = DropZoneViewModel.DroppedSource.folder(URL(fileURLWithPath: "/tmp/MyGame"))
        vm.seed(fromDrop: dropped)
        XCTAssertEqual(vm.sourceMode, .path)
        XCTAssertEqual(vm.sourcePath, "/tmp/MyGame")
        XCTAssertEqual(vm.displayName, "MyGame")
    }

    func testSeedFromDropZipUsesStemAsName() {
        let vm = MoreDialogViewModel()
        let dropped = DropZoneViewModel.DroppedSource.zip(URL(fileURLWithPath: "/tmp/MyGame.zip"))
        vm.seed(fromDrop: dropped)
        XCTAssertEqual(vm.sourceMode, .path)
        XCTAssertEqual(vm.sourcePath, "/tmp/MyGame.zip")
        XCTAssertEqual(vm.displayName, "MyGame")
    }
}
