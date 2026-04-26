import XCTest
@testable import CiderCore

final class WineWrapperBundleTests: XCTestCase {

    func testWrapperContainsSymlinkAndPlist() throws {
        // Use any existing executable as the "engine wine" stand-in.
        let dummyEngine = URL(fileURLWithPath: "/bin/echo")
        let built = try WineWrapperBundle.make(
            displayName: "My Game",
            engineWineBinary: dummyEngine
        )
        defer { WineWrapperBundle.cleanup(built) }

        // wineURL is the wrapper's MacOS/wine.
        XCTAssertEqual(built.wineURL.lastPathComponent, "wine")
        XCTAssertEqual(built.wineURL.deletingLastPathComponent().lastPathComponent, "MacOS")

        // It's a symlink pointing at the engine binary.
        let dest = try FileManager.default.destinationOfSymbolicLink(
            atPath: built.wineURL.path)
        XCTAssertEqual(dest, dummyEngine.path)

        // Info.plist exists with the right CFBundleName.
        let plistURL = built.bundleURL.appendingPathComponent("Contents/Info.plist")
        let plistText = try String(contentsOf: plistURL, encoding: .utf8)
        XCTAssertTrue(plistText.contains("<key>CFBundleName</key>"))
        XCTAssertTrue(plistText.contains("<string>My Game</string>"))
        XCTAssertTrue(plistText.contains("<key>CFBundleDisplayName</key>"))
    }

    func testBundleNameIsSanitisedForFilename() throws {
        // Names with slashes / colons / spaces shouldn't blow up the
        // wrapper directory layout.
        let built = try WineWrapperBundle.make(
            displayName: "Foo/Bar: 1.0 (test)",
            engineWineBinary: URL(fileURLWithPath: "/bin/echo")
        )
        defer { WineWrapperBundle.cleanup(built) }

        let bundleName = built.bundleURL.lastPathComponent
        XCTAssertTrue(bundleName.hasSuffix(".app"))
        XCTAssertFalse(bundleName.contains("/"))
        XCTAssertFalse(bundleName.contains(":"))
        // Whitespace was collapsed to dashes.
        XCTAssertFalse(bundleName.contains(" "))

        // BUT the human-readable Info.plist still preserves the
        // original displayName (with all its punctuation) so the
        // menu bar reads what the user typed.
        let plistText = try String(
            contentsOf: built.bundleURL.appendingPathComponent("Contents/Info.plist"),
            encoding: .utf8)
        XCTAssertTrue(plistText.contains("Foo/Bar: 1.0 (test)"))
    }

    func testCleanupRemovesTheParentDir() throws {
        let built = try WineWrapperBundle.make(
            displayName: "Cleanup",
            engineWineBinary: URL(fileURLWithPath: "/bin/echo"))
        let parent = built.bundleURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.path))

        WineWrapperBundle.cleanup(built)

        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    func testEmptyDisplayNameStillProducesValidWrapper() throws {
        let built = try WineWrapperBundle.make(
            displayName: "",
            engineWineBinary: URL(fileURLWithPath: "/bin/echo"))
        defer { WineWrapperBundle.cleanup(built) }
        // Filename falls back to "App" so the wrapper is still well-formed.
        XCTAssertTrue(built.bundleURL.lastPathComponent.contains("App"))
    }
}
