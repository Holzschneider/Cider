import XCTest
@testable import Cider

final class LauncherScriptTests: XCTestCase {
    func testRendersTemplateWithSubstitutions() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-launcher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try LauncherScript.render(
            .init(
                bundleId: "com.example.mygame",
                wineBinaryRelativePath: "wswine.bundle/bin/wine",
                winExePath: "C:\\Program Files\\My Game\\Game.exe",
                exeWorkingDirRelativeToDriveC: "Program Files/My Game",
                exeArgs: ["--windowed", "--nosplash"],
                launch: .direct,
                dllOverrides: "d3d11,dxgi=n,b",
                extraEnv: ["FOO": "bar"]
            ),
            to: tmp
        )

        let contents = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(contents.contains("#!/bin/bash"))
        XCTAssertTrue(contents.contains("com.example.mygame"))
        XCTAssertTrue(contents.contains("wswine.bundle/bin/wine"))
        XCTAssertTrue(contents.contains("d3d11,dxgi=n,b"))
        XCTAssertTrue(contents.contains("--windowed"))
        XCTAssertTrue(contents.contains("--nosplash"))
        XCTAssertTrue(contents.contains("export FOO=\"bar\""))
        // dlopen support: must reference the engine dir where wrapper-template
        // dylibs (libfreetype, libgnutls, libMoltenVK) are deposited.
        XCTAssertTrue(contents.contains("$DIR/engine"))
        XCTAssertTrue(contents.contains("DYLD_FALLBACK_LIBRARY_PATH"))
        XCTAssertTrue(contents.contains(#"cd "$DIR/wineprefix/drive_c/Program Files/My Game""#))

        // Executable bit must be set.
        let perms = try FileManager.default.attributesOfItem(atPath: tmp.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value ?? 0, 0o755)
    }

    func testConsoleVariantInvokesCmdExe() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-launcher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try LauncherScript.render(
            .init(
                bundleId: "com.example.tui",
                wineBinaryRelativePath: "wswine.bundle/bin/wine",
                winExePath: "C:\\Program Files\\Test\\App.exe",
                exeWorkingDirRelativeToDriveC: "Program Files/Test",
                exeArgs: ["/log"],
                launch: .viaCmd(batWindowsPath: "C:\\Program Files\\Test\\run.bat"),
                dllOverrides: "d3d11=n,b",
                extraEnv: [:]
            ),
            to: tmp
        )

        let contents = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(contents.contains("cmd.exe"))
        XCTAssertTrue(contents.contains("run.bat"))
        // The exe args should NOT be on the launcher line in cmd mode — they
        // are encoded into the bat file instead.
        XCTAssertFalse(contents.contains("/log"))
    }
}
