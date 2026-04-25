import XCTest
@testable import CiderCore

final class PrefixInitializerTests: XCTestCase {
    private var prefix: URL!
    private var source: URL!
    private var stagingPaths: [URL] = []

    override func setUp() {
        super.setUp()
        prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-prefix-\(UUID().uuidString)", isDirectory: true)
        source = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-source-\(UUID().uuidString)/MyGame", isDirectory: true)
        try? FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try? Data("exe-bytes".utf8).write(to: source.appendingPathComponent("Game.exe"))
        try? Data("dat".utf8).write(to: source.appendingPathComponent("data.dat"))
        stagingPaths.append(prefix)
        stagingPaths.append(source.deletingLastPathComponent())
    }

    override func tearDown() {
        for p in stagingPaths { try? FileManager.default.removeItem(at: p) }
        super.tearDown()
    }

    private func initWithFakeWine() -> PrefixInitializer {
        // wineBinary isn't called by stagePayload — passing a path that
        // doesn't exist is fine for these tests.
        PrefixInitializer(prefix: prefix,
                          wineBinary: URL(fileURLWithPath: "/usr/bin/false"))
    }

    func testStagePayloadCreatesSingleSymlink() throws {
        let initialiser = initWithFakeWine()
        let winPath = try initialiser.stagePayload(
            from: source,
            exeRelativePath: "Game.exe",
            programName: "MyGame"
        )
        XCTAssertEqual(winPath, "C:\\Program Files\\MyGame\\Game.exe")

        let target = prefix.appendingPathComponent("drive_c/Program Files/MyGame")
        // The target itself is a symlink (not a directory).
        let linkDest = try FileManager.default.destinationOfSymbolicLink(atPath: target.path)
        XCTAssertEqual(linkDest, source.standardizedFileURL.path)

        // Reading through the link finds the source's files.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("Game.exe").path))
    }

    func testStagePayloadIsIdempotent() throws {
        let initialiser = initWithFakeWine()
        _ = try initialiser.stagePayload(
            from: source, exeRelativePath: "Game.exe", programName: "MyGame")
        let target = prefix.appendingPathComponent("drive_c/Program Files/MyGame")
        let firstInode = try FileManager.default
            .attributesOfItem(atPath: target.path)[.systemFileNumber] as? UInt64

        // Re-run — should be a no-op (same symlink, no replacement).
        _ = try initialiser.stagePayload(
            from: source, exeRelativePath: "Game.exe", programName: "MyGame")
        let secondInode = try FileManager.default
            .attributesOfItem(atPath: target.path)[.systemFileNumber] as? UInt64

        XCTAssertEqual(firstInode, secondInode,
                       "re-stage with the same source must not recreate the link")
    }

    func testStagePayloadRebindsWhenSourceChanges() throws {
        let initialiser = initWithFakeWine()
        _ = try initialiser.stagePayload(
            from: source, exeRelativePath: "Game.exe", programName: "MyGame")

        // Build a fresh source with a different exe + path.
        let newSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-newsource-\(UUID().uuidString)/MyGame",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: newSource, withIntermediateDirectories: true)
        try Data("v2".utf8).write(to: newSource.appendingPathComponent("Game.exe"))
        stagingPaths.append(newSource.deletingLastPathComponent())

        _ = try initialiser.stagePayload(
            from: newSource, exeRelativePath: "Game.exe", programName: "MyGame")

        let target = prefix.appendingPathComponent("drive_c/Program Files/MyGame")
        let linkDest = try FileManager.default.destinationOfSymbolicLink(atPath: target.path)
        XCTAssertEqual(linkDest, newSource.standardizedFileURL.path,
                       "symlink must be rebound to the new source")

        // Reading through the link finds the new file content.
        let bytes = try Data(contentsOf: target.appendingPathComponent("Game.exe"))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "v2")
    }

    func testStagePayloadReplacesLegacyDirectory() throws {
        // Pre-create a real directory at the target (simulates a prefix
        // initialised with the old per-entry-symlink layout).
        let target = prefix.appendingPathComponent("drive_c/Program Files/MyGame")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: target.appendingPathComponent("STALE_MARKER"))

        let initialiser = initWithFakeWine()
        _ = try initialiser.stagePayload(
            from: source, exeRelativePath: "Game.exe", programName: "MyGame")

        // Old directory is gone; target is now a symlink.
        let linkDest = try FileManager.default.destinationOfSymbolicLink(atPath: target.path)
        XCTAssertEqual(linkDest, source.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("STALE_MARKER").path))
    }

    func testStagePayloadFailsWhenExeMissing() throws {
        let initialiser = initWithFakeWine()
        do {
            _ = try initialiser.stagePayload(
                from: source,
                exeRelativePath: "DoesNotExist.exe",
                programName: "MyGame"
            )
            XCTFail("expected exeNotFound")
        } catch PrefixInitializer.Error.exeNotFound {
            // ok
        } catch {
            XCTFail("expected exeNotFound, got \(error)")
        }
    }

    func testTwoBundlesShareTheSamePrefix() throws {
        // Sibling source for a second bundle.
        let secondSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-source-\(UUID().uuidString)/OtherApp",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)
        try Data("e".utf8).write(to: secondSource.appendingPathComponent("Other.exe"))
        stagingPaths.append(secondSource.deletingLastPathComponent())

        let initialiser = initWithFakeWine()
        _ = try initialiser.stagePayload(
            from: source, exeRelativePath: "Game.exe", programName: "MyGame")
        _ = try initialiser.stagePayload(
            from: secondSource, exeRelativePath: "Other.exe", programName: "OtherApp")

        let pf = prefix.appendingPathComponent("drive_c/Program Files")
        let entries = try FileManager.default.contentsOfDirectory(atPath: pf.path).sorted()
        XCTAssertEqual(entries, ["MyGame", "OtherApp"],
                       "two bundles should both have entries under the shared prefix's Program Files")
    }
}
