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
                winExePath: "C:\\Program Files\\My Game\\Game.exe",
                exeArgs: ["--windowed", "--nosplash"],
                dllOverrides: "d3d11,dxgi=n,b",
                extraEnv: ["FOO": "bar"]
            ),
            to: tmp
        )

        let contents = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(contents.contains("#!/bin/bash"))
        XCTAssertTrue(contents.contains("com.example.mygame"))
        XCTAssertTrue(contents.contains("d3d11,dxgi=n,b"))
        XCTAssertTrue(contents.contains("--windowed"))
        XCTAssertTrue(contents.contains("--nosplash"))
        XCTAssertTrue(contents.contains("export FOO=\"bar\""))

        // Executable bit must be set.
        let perms = try FileManager.default.attributesOfItem(atPath: tmp.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value ?? 0, 0o755)
    }
}
