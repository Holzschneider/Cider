import XCTest
@testable import CiderModels
@testable import CiderCore

final class NameClashCheckerTests: XCTestCase {
    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        // Use the real AppSupport paths but seed unique-name slots so
        // tests don't trip over each other or over the user's data.
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-clash-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    private func uniqueName() -> String { "ClashTest-\(UUID().uuidString.prefix(8))" }

    private func seedConfig(name: String) {
        let url = AppSupport.config(forBundleNamed: name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    private func seedProgramFiles(name: String) {
        let url = AppSupport.programFiles(forBundleNamed: name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func cleanup(_ name: String) {
        try? FileManager.default.removeItem(at: AppSupport.config(forBundleNamed: name))
        try? FileManager.default.removeItem(at: AppSupport.programFiles(forBundleNamed: name))
    }

    // MARK: - Bundle mode never clashes

    func testBundleModeNeverClashes() {
        let name = uniqueName()
        seedConfig(name: name)
        seedProgramFiles(name: name)
        defer { cleanup(name) }

        XCTAssertNil(NameClashChecker.clash(
            for: name, mode: .bundle, originalName: nil))
    }

    // MARK: - Install mode

    func testInstallModeFlagsExistingProgramFiles() {
        let name = uniqueName()
        seedProgramFiles(name: name)
        defer { cleanup(name) }

        XCTAssertNotNil(NameClashChecker.clash(
            for: name, mode: .install, originalName: nil))
    }

    func testInstallModeFlagsExistingConfig() {
        let name = uniqueName()
        seedConfig(name: name)
        defer { cleanup(name) }

        XCTAssertNotNil(NameClashChecker.clash(
            for: name, mode: .install, originalName: nil))
    }

    func testInstallModePassesWhenNameIsFree() {
        let name = uniqueName()  // never seeded
        XCTAssertNil(NameClashChecker.clash(
            for: name, mode: .install, originalName: nil))
    }

    // MARK: - Link mode

    func testLinkModeFlagsExistingConfig() {
        let name = uniqueName()
        seedConfig(name: name)
        defer { cleanup(name) }

        XCTAssertNotNil(NameClashChecker.clash(
            for: name, mode: .link, originalName: nil))
    }

    func testLinkModeIgnoresProgramFilesAlone() {
        // Link doesn't own a Program Files slot — a stray dir there
        // shouldn't block a Link rename.
        let name = uniqueName()
        seedProgramFiles(name: name)
        defer { cleanup(name) }

        XCTAssertNil(NameClashChecker.clash(
            for: name, mode: .link, originalName: nil))
    }

    // MARK: - originalName lets edits through

    func testEditingOwnConfigNeverClashes() {
        let name = uniqueName()
        seedConfig(name: name)
        seedProgramFiles(name: name)
        defer { cleanup(name) }

        XCTAssertNil(NameClashChecker.clash(
            for: name, mode: .install, originalName: name),
            "the slot belongs to us — editing the same name shouldn't clash")
    }

    func testRenamingToAnotherBundlesSlotClashes() {
        let mine = uniqueName()
        let theirs = uniqueName()
        seedConfig(name: theirs)
        defer { cleanup(theirs) }

        XCTAssertNotNil(NameClashChecker.clash(
            for: theirs, mode: .install, originalName: mine),
            "renaming our config to a name another bundle owns should clash")
    }

    // MARK: - Trim handling

    func testWhitespaceIsTrimmed() {
        let name = uniqueName()
        seedConfig(name: name)
        defer { cleanup(name) }

        XCTAssertNotNil(NameClashChecker.clash(
            for: "  \(name)  ", mode: .install, originalName: nil),
            "leading/trailing whitespace should still detect the clash")
    }

    func testEmptyNameNeverClashes() {
        XCTAssertNil(NameClashChecker.clash(
            for: "", mode: .install, originalName: nil),
            "empty name is the displayNameError's job, not the clash check's")
    }
}
