import XCTest
@testable import CiderModels
@testable import CiderCore
@testable import CiderApp

@MainActor
final class DropZoneAutoLoadTests: XCTestCase {
    private var stagingPaths: [URL] = []
    private var appSupportNamesToCleanup: [String] = []

    override func tearDown() {
        for url in stagingPaths { try? FileManager.default.removeItem(at: url) }
        for name in appSupportNamesToCleanup {
            try? FileManager.default.removeItem(
                at: AppSupport.config(forBundleNamed: name))
        }
        super.tearDown()
    }

    private func makeFolder(named: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-autoload-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = parent.appendingPathComponent(named, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Drop a stub exe in so anything that reads the folder doesn't trip.
        try Data("exe".utf8).write(to: folder.appendingPathComponent("Game.exe"))
        stagingPaths.append(parent)
        return folder
    }

    private func sampleConfig(displayName: String,
                              applicationPath: String,
                              extra: String = "") -> CiderConfig {
        CiderConfig(
            displayName: displayName,
            applicationPath: applicationPath,
            exe: "Game.exe\(extra)",
            engine: .init(name: "WS12WineCX24.0.7_7",
                          url: "https://example.com/x.tar.xz"),
            graphics: .dxmt
        )
    }

    private func writeConfig(_ config: CiderConfig, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try config.write(to: url)
    }

    // MARK: - Folder cider.json fallback

    func testFolderWithCiderJSONLoadsAndSynthesisesPlan() throws {
        let name = "AutoLoadTest-\(UUID().uuidString.prefix(8))"
        let folder = try makeFolder(named: name)
        try writeConfig(sampleConfig(displayName: name,
                                     applicationPath: "/abs/path"),
                        to: folder.appendingPathComponent("cider.json"))

        let vm = DropZoneViewModel()
        vm.handleDrop(folder)

        XCTAssertNotNil(vm.loadedConfig, "folder cider.json should populate loadedConfig")
        XCTAssertEqual(vm.loadedConfig?.displayName, name)
        XCTAssertNotNil(vm.installPlan, "auto-load should synthesise an installPlan")
        XCTAssertEqual(vm.installPlan?.mode, .link,
                       "absolute applicationPath should infer Link mode")
        if case .folder(let url) = vm.installPlan?.source {
            XCTAssertEqual(url.standardizedFileURL.path,
                           folder.standardizedFileURL.path)
        } else {
            XCTFail("source should be the dropped folder")
        }
        XCTAssertTrue(vm.statusMessage.contains("cider.json from \(name)"))
    }

    // MARK: - AppSupport precedence

    func testAppSupportConfigBeatsFolderConfig() throws {
        let name = "AutoLoadTest-\(UUID().uuidString.prefix(8))"
        appSupportNamesToCleanup.append(name)
        let folder = try makeFolder(named: name)

        // Two distinct configs — one in AppSupport, one in the folder.
        // AppSupport's should win.
        let appSupportConfig = sampleConfig(displayName: name,
                                            applicationPath: "AppSupportPath",
                                            extra: "/AppSupport")
        let folderConfig = sampleConfig(displayName: name,
                                        applicationPath: "/folder/path",
                                        extra: "/Folder")
        try writeConfig(appSupportConfig,
                        to: AppSupport.config(forBundleNamed: name))
        try writeConfig(folderConfig,
                        to: folder.appendingPathComponent("cider.json"))

        let vm = DropZoneViewModel()
        vm.handleDrop(folder)

        XCTAssertEqual(vm.loadedConfig?.exe, "Game.exe/AppSupport",
                       "AppSupport config must win over the folder's cider.json")
        XCTAssertTrue(vm.statusMessage.contains("Application Support"))
    }

    // MARK: - No config

    func testFolderWithNoConfigLeavesLoadedConfigNil() throws {
        let folder = try makeFolder(named: "AutoLoadTest-\(UUID().uuidString.prefix(8))")
        let vm = DropZoneViewModel()
        vm.handleDrop(folder)
        XCTAssertNil(vm.loadedConfig)
        XCTAssertNil(vm.installPlan)
        XCTAssertTrue(vm.statusMessage.contains("Configure"),
                      "user should be told to click Configure")
    }

    func testMalformedAppSupportConfigFallsThroughToFolderConfig() throws {
        // AppSupport entry exists but isn't a valid v2 config.
        // The folder's cider.json should still load.
        let name = "AutoLoadTest-\(UUID().uuidString.prefix(8))"
        appSupportNamesToCleanup.append(name)
        let folder = try makeFolder(named: name)

        let appSupportURL = AppSupport.config(forBundleNamed: name)
        try FileManager.default.createDirectory(
            at: appSupportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: appSupportURL)

        try writeConfig(sampleConfig(displayName: name,
                                     applicationPath: "/abs"),
                        to: folder.appendingPathComponent("cider.json"))

        let vm = DropZoneViewModel()
        vm.handleDrop(folder)

        XCTAssertNotNil(vm.loadedConfig,
                        "malformed AppSupport entry should not block the folder fallback")
        XCTAssertEqual(vm.loadedConfig?.applicationPath, "/abs")
    }

    // MARK: - Mode inference for Bundle / Install

    func testBundleModeInferredFromSystemPrefix() throws {
        let name = "AutoLoadTest-\(UUID().uuidString.prefix(8))"
        let folder = try makeFolder(named: name)
        try writeConfig(sampleConfig(displayName: name,
                                     applicationPath: "System/drive_c/Program Files/X"),
                        to: folder.appendingPathComponent("cider.json"))

        let vm = DropZoneViewModel()
        vm.handleDrop(folder)

        XCTAssertEqual(vm.installPlan?.mode, .bundle,
                       "System/... applicationPath → Bundle mode")
    }

    func testInstallModeInferredFromRelativePath() throws {
        let name = "AutoLoadTest-\(UUID().uuidString.prefix(8))"
        let folder = try makeFolder(named: name)
        try writeConfig(sampleConfig(displayName: name,
                                     applicationPath: "MyGame"),
                        to: folder.appendingPathComponent("cider.json"))

        let vm = DropZoneViewModel()
        vm.handleDrop(folder)

        XCTAssertEqual(vm.installPlan?.mode, .install,
                       "plain relative applicationPath → Install mode")
    }
}
