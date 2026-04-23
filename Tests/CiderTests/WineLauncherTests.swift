import XCTest
@testable import CiderModels
@testable import CiderCore

final class WineLauncherTests: XCTestCase {
    private func planFixture(console: Bool, inherit: Bool, exe: String = "Foo/Game.exe") -> WineLauncher.Plan {
        WineLauncher.Plan(
            wineBinary: URL(fileURLWithPath: "/tmp/engine/wswine.bundle/bin/wine"),
            engineRoot: URL(fileURLWithPath: "/tmp/engine"),
            prefix: URL(fileURLWithPath: "/tmp/prefix"),
            displayName: "MyGame",
            exeRelative: exe,
            exeArgs: ["/tui", "/log"],
            wine: .init(
                esync: true, msync: true, useWinedbg: false,
                winetricks: [], console: console, inheritConsole: inherit
            ),
            dllOverrides: "d3d11=n,b",
            graphicsExtraEnv: ["MTL_HUD_ENABLED": "0"]
        )
    }

    func testBatWithoutInheritConsole() throws {
        let launcher = WineLauncher(plan: planFixture(console: true, inherit: false))
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-bat-\(UUID().uuidString).bat")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try launcher.writeRunBat(at: tmp,
                                 winExePath: #"C:\Program Files\MyGame\Foo\Game.exe"#)
        let text = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("@echo off\r\n"))
        XCTAssertTrue(text.contains(#""C:\Program Files\MyGame\Foo\Game.exe""#))
        XCTAssertTrue(text.contains("/tui"))
        XCTAssertTrue(text.contains("< NUL > all.txt 2>&1"))
        XCTAssertFalse(text.contains(#"start "" /B /WAIT"#),
                        "plain console mode must NOT use start /B")
    }

    func testBatWithInheritConsole() throws {
        let launcher = WineLauncher(plan: planFixture(console: true, inherit: true))
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-bat-\(UUID().uuidString).bat")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try launcher.writeRunBat(at: tmp,
                                 winExePath: #"C:\Program Files\MyGame\Foo\Game.exe"#)
        let text = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(text.contains(#"start "" /B /WAIT"#))
        XCTAssertTrue(text.contains("< NUL > all.txt 2>&1"))
    }
}

// LineBuffer is file-private inside Core; reach in via @testable to test.
final class LineBufferTests: XCTestCase {
    func testSplitsAcrossChunks() {
        let b = LineBuffer()
        XCTAssertEqual(b.feed("hello\nwor"), ["hello"])
        XCTAssertEqual(b.feed("ld\nend"), ["world"])
        XCTAssertEqual(b.flush(), ["end"])
    }

    func testStripsTrailingCarriageReturn() {
        let b = LineBuffer()
        XCTAssertEqual(b.feed("one\r\ntwo\r\n"), ["one", "two"])
    }

    func testHandlesEmptyChunks() {
        let b = LineBuffer()
        XCTAssertEqual(b.feed(""), [])
        XCTAssertEqual(b.feed("a\nb\n"), ["a", "b"])
        XCTAssertEqual(b.flush(), [])
    }
}
