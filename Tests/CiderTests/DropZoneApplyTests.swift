import XCTest
@testable import CiderModels
@testable import CiderCore
@testable import CiderApp

// Phase 8 orchestrator tests. Drives DropZoneController.performApply
// directly (the static work unit pulled out of the @MainActor surface)
// to verify the on-disk effects of Apply / Create combined with
// Install / Bundle / Link install modes.
final class DropZoneApplyTests: XCTestCase {
    private var displayName: String = ""
    private var stagingPaths: [URL] = []
    private var fakeBundleParent: URL!
    private var fakeBundle: URL!

    override func setUp() {
        super.setUp()
        displayName = "ApplyTest-\(UUID().uuidString.prefix(8))"
        fakeBundleParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-apply-\(UUID().uuidString)", isDirectory: true)
        // Stand up a fake "Cider.app" with a Contents/ + a sentinel inside
        // so we can verify Apply / Create don't disturb it.
        fakeBundle = fakeBundleParent.appendingPathComponent("Cider.app", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: fakeBundle.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try? Data("binary-bytes".utf8).write(
            to: fakeBundle.appendingPathComponent("Contents/MacOS/cider"))
        try? Data("plist".utf8).write(
            to: fakeBundle.appendingPathComponent("Contents/Info.plist"))
        stagingPaths.append(fakeBundleParent)
    }

    override func tearDown() {
        for url in stagingPaths {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(
            at: AppSupport.config(forBundleNamed: displayName))
        try? FileManager.default.removeItem(
            at: AppSupport.programFiles(forBundleNamed: displayName))
        super.tearDown()
    }

    // MARK: - Fixtures

    private func sampleConfig(applicationPath: String = "PLACEHOLDER",
                              exe: String = "Game/start.exe") -> CiderConfig {
        CiderConfig(
            displayName: displayName,
            applicationPath: applicationPath,
            exe: exe,
            engine: .init(name: "WS12WineCX24.0.7_7",
                          url: "https://example.com/x.tar.xz"),
            graphics: .dxmt
        )
    }

    private func makeFolder(named: String, files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-apply-folder-\(UUID().uuidString)/\(named)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (rel, body) in files {
            let target = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(body.utf8).write(to: target)
        }
        stagingPaths.append(dir.deletingLastPathComponent())
        return dir
    }

    // MARK: - Apply in-place

    func testApplyInPlaceWithInstallModeRenamesAndWritesAppSupportConfig() async throws {
        let folder = try makeFolder(named: "Game", files: ["start.exe": "x"])
        let plan = InstallPlan(
            config: sampleConfig(),
            mode: .install,
            source: .folder(folder)
        )
        let final = try await DropZoneController.performApply(
            plan: plan,
            target: .applyInPlace,
            currentBundle: fakeBundle,
            icnsURL: nil,
            progress: { _ in }
        )

        // Bundle was renamed to <DisplayName>.app under the same parent.
        XCTAssertEqual(final.lastPathComponent, "\(displayName).app")
        XCTAssertEqual(final.deletingLastPathComponent(), fakeBundleParent)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("Contents/MacOS/cider").path),
            "Contents/ must survive intact")

        // cider.json went to AppSupport (Install mode).
        let appSupportConfig = AppSupport.config(forBundleNamed: displayName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appSupportConfig.path))
        let written = try CiderConfig.read(from: appSupportConfig)
        // Installer rewrites applicationPath to AppSupport/Program Files/<name>/.
        XCTAssertEqual(written.applicationPath,
                       AppSupport.programFiles(forBundleNamed: displayName).standardizedFileURL.path)

        // Bundle contains no cider.json (Install mode wipes/leaves it absent).
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("cider.json").path))
    }

    func testApplyInPlaceWithBundleModeWritesInBundleConfig() async throws {
        let folder = try makeFolder(named: "Game", files: ["start.exe": "x"])
        let plan = InstallPlan(
            config: sampleConfig(exe: "start.exe"),
            mode: .bundle,
            source: .folder(folder)
        )
        let final = try await DropZoneController.performApply(
            plan: plan,
            target: .applyInPlace,
            currentBundle: fakeBundle,
            icnsURL: nil,
            progress: { _ in }
        )

        // schema-v3 Bundle layout: cider.json sibling of Contents/,
        // prefixPath "System", applicationPath inside System/drive_c/...
        let inBundleConfig = final.appendingPathComponent("cider.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inBundleConfig.path))
        let written = try CiderConfig.read(from: inBundleConfig)
        XCTAssertEqual(written.prefixPath, "System")
        XCTAssertEqual(written.applicationPath,
                       "System/drive_c/Program Files/\(displayName)")

        // Source CONTENTS land directly under Program Files/<programName>/
        // (no source-folder nesting in Bundle mode).
        let appDir = final.appendingPathComponent(written.applicationPath)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: appDir.appendingPathComponent("start.exe").path))
        // Contents/ untouched.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("Contents/MacOS/cider").path))
    }

    // MARK: - Create (clone)

    func testCreateClonesBundleAndDoesNotMutateOriginal() async throws {
        let folder = try makeFolder(named: "Game", files: ["start.exe": "x"])
        let dest = fakeBundleParent.appendingPathComponent("MyClone.app", isDirectory: true)
        let plan = InstallPlan(
            config: sampleConfig(),
            mode: .install,
            source: .folder(folder)
        )
        let final = try await DropZoneController.performApply(
            plan: plan,
            target: .cloneTo(dest),
            currentBundle: fakeBundle,
            icnsURL: nil,
            progress: { _ in }
        )

        XCTAssertEqual(final, dest, "Create mode keeps the user-picked bundle name")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("Contents/MacOS/cider").path))
        // Original bundle still on disk, unmodified.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fakeBundle.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fakeBundle.appendingPathComponent("Contents/MacOS/cider").path))
    }

    func testCreateRefusesToOverwriteExistingTarget() async throws {
        let folder = try makeFolder(named: "Game", files: ["start.exe": "x"])
        let dest = fakeBundleParent.appendingPathComponent("Existing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let plan = InstallPlan(
            config: sampleConfig(),
            mode: .install,
            source: .folder(folder)
        )
        do {
            _ = try await DropZoneController.performApply(
                plan: plan,
                target: .cloneTo(dest),
                currentBundle: fakeBundle,
                icnsURL: nil,
                progress: { _ in }
            )
            XCTFail("expected targetExists")
        } catch DropZoneController.OrchestratorError.targetExists {
            // ok
        } catch {
            XCTFail("expected targetExists, got \(error)")
        }
    }

    // MARK: - No-source edit

    func testNoSourceJustRewritesConfigInAppSupport() async throws {
        let plan = InstallPlan(
            config: sampleConfig(applicationPath: "MyGame"),
            mode: .install,
            source: nil
        )
        let final = try await DropZoneController.performApply(
            plan: plan,
            target: .applyInPlace,
            currentBundle: fakeBundle,
            icnsURL: nil,
            progress: { _ in }
        )
        // Bundle was renamed.
        XCTAssertEqual(final.lastPathComponent, "\(displayName).app")
        // cider.json written verbatim — applicationPath preserved.
        let configURL = AppSupport.config(forBundleNamed: displayName)
        let written = try CiderConfig.read(from: configURL)
        XCTAssertEqual(written.applicationPath, "MyGame")
    }

    // MARK: - Wipe stale

    func testApplyInstallWipesStaleInBundleCiderJSON() async throws {
        // Pre-seed the running bundle with a stale cider.json (e.g. from
        // a previous Bundle-mode install) — Install mode should wipe it.
        let stale = fakeBundle.appendingPathComponent("cider.json")
        try Data("stale".utf8).write(to: stale)

        let folder = try makeFolder(named: "Game", files: ["start.exe": "x"])
        let plan = InstallPlan(config: sampleConfig(), mode: .install, source: .folder(folder))
        let final = try await DropZoneController.performApply(
            plan: plan, target: .applyInPlace,
            currentBundle: fakeBundle, icnsURL: nil, progress: { _ in }
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("cider.json").path),
            "stale in-bundle cider.json must be wiped for non-Bundle modes")
    }

    // MARK: - Phase 10 rename-on-Save

    func testNoSourceRenameInstallMovesProgramFilesAndConfig() async throws {
        // Pre-seed an existing "OldName" Install: data under
        // Program Files/OldName/ and a config in Configs/OldName.json.
        let oldName = "OldRenameTest-\(UUID().uuidString.prefix(8))"
        let newName = displayName  // tearDown cleans this up
        let oldDir = AppSupport.programFiles(forBundleNamed: oldName)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("blob".utf8).write(to: oldDir.appendingPathComponent("payload.bin"))
        defer {
            try? FileManager.default.removeItem(at: oldDir)
            try? FileManager.default.removeItem(at: AppSupport.programFiles(forBundleNamed: oldName))
            try? FileManager.default.removeItem(at: AppSupport.config(forBundleNamed: oldName))
        }
        let oldConfig = sampleConfig(applicationPath: oldDir.standardizedFileURL.path,
                                     exe: "payload.bin")
        var seedConfig = oldConfig
        seedConfig.displayName = oldName
        try seedConfig.write(to: AppSupport.config(forBundleNamed: oldName))

        // Stand the running bundle in as `OldName.app` so the orchestrator
        // sees this as a rename rather than a fresh install.
        let renamedBundle = fakeBundleParent.appendingPathComponent("\(oldName).app",
                                                                    isDirectory: true)
        try FileManager.default.moveItem(at: fakeBundle, to: renamedBundle)

        // The plan keeps the same applicationPath value coming in
        // (load() preserves it) — performApply's rename step rewrites it.
        var planConfig = oldConfig
        planConfig.displayName = newName
        let plan = InstallPlan(config: planConfig, mode: .install, source: nil)

        let final = try await DropZoneController.performApply(
            plan: plan,
            target: .applyInPlace,
            currentBundle: renamedBundle,
            icnsURL: nil,
            progress: { _ in }
        )

        // Bundle renamed.
        XCTAssertEqual(final.lastPathComponent, "\(newName).app")

        // Data moved from Program Files/OldName/ to Program Files/<newName>/.
        let newDir = AppSupport.programFiles(forBundleNamed: newName)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: newDir.appendingPathComponent("payload.bin").path),
            "Program Files data must move to the new name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path),
                       "Old Program Files dir must be gone after rename")

        // Config moved AND updated (applicationPath now points at new dir).
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AppSupport.config(forBundleNamed: oldName).path))
        let written = try CiderConfig.read(from: AppSupport.config(forBundleNamed: newName))
        XCTAssertEqual(written.displayName, newName)
        XCTAssertEqual(written.applicationPath, newDir.standardizedFileURL.path,
                       "applicationPath rewritten to point at the new Program Files dir")
    }

    func testNoSourceRenameLinkMovesOnlyTheConfig() async throws {
        let oldName = "OldLinkTest-\(UUID().uuidString.prefix(8))"
        let newName = displayName
        let externalFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-link-target-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: externalFolder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: externalFolder)
            try? FileManager.default.removeItem(at: AppSupport.config(forBundleNamed: oldName))
        }
        let oldCfg = sampleConfig(applicationPath: externalFolder.path)
        var seedCfg = oldCfg
        seedCfg.displayName = oldName
        try seedCfg.write(to: AppSupport.config(forBundleNamed: oldName))

        let renamedBundle = fakeBundleParent.appendingPathComponent("\(oldName).app",
                                                                    isDirectory: true)
        try FileManager.default.moveItem(at: fakeBundle, to: renamedBundle)

        var planConfig = oldCfg
        planConfig.displayName = newName
        let plan = InstallPlan(config: planConfig, mode: .link, source: nil)

        _ = try await DropZoneController.performApply(
            plan: plan,
            target: .applyInPlace,
            currentBundle: renamedBundle,
            icnsURL: nil,
            progress: { _ in }
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AppSupport.config(forBundleNamed: oldName).path))
        let written = try CiderConfig.read(from: AppSupport.config(forBundleNamed: newName))
        XCTAssertEqual(written.displayName, newName)
        // External folder unchanged (Link doesn't move user data).
        XCTAssertEqual(written.applicationPath, externalFolder.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFolder.path))
    }

    func testWithSourceRenameCleansUpOldAppSupportEntries() async throws {
        // Pre-seed an existing "OldName" Install we'll be renaming away
        // from with a fresh source.
        let oldName = "OldOrphanTest-\(UUID().uuidString.prefix(8))"
        let oldDir = AppSupport.programFiles(forBundleNamed: oldName)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: oldDir.appendingPathComponent("stale.bin"))
        defer {
            try? FileManager.default.removeItem(at: oldDir)
            try? FileManager.default.removeItem(at: AppSupport.config(forBundleNamed: oldName))
        }
        try sampleConfig(applicationPath: oldDir.path).write(
            to: AppSupport.config(forBundleNamed: oldName))

        let renamedBundle = fakeBundleParent.appendingPathComponent("\(oldName).app",
                                                                    isDirectory: true)
        try FileManager.default.moveItem(at: fakeBundle, to: renamedBundle)

        let folder = try makeFolder(named: "Game", files: ["start.exe": "x"])
        let plan = InstallPlan(
            config: sampleConfig(),  // displayName = self.displayName (the new name)
            mode: .install,
            source: .folder(folder)
        )
        _ = try await DropZoneController.performApply(
            plan: plan,
            target: .applyInPlace,
            currentBundle: renamedBundle,
            icnsURL: nil,
            progress: { _ in }
        )

        // Old AppSupport entries are gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path),
                       "old Program Files dir must be cleaned up after rename")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AppSupport.config(forBundleNamed: oldName).path),
            "old config must be cleaned up after rename")

        // New entries are in place.
        let newDir = AppSupport.programFiles(forBundleNamed: displayName)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: newDir.appendingPathComponent("Game/start.exe").path))
    }

    func testFreshInstallFromVanillaCiderHasNoOldNameToCleanUp() async throws {
        // Sanity: the bundle is "Cider.app", the orchestrator must NOT
        // try to clean up Configs/Cider.json or Program Files/Cider/.
        let folder = try makeFolder(named: "Game", files: ["start.exe": "x"])
        let plan = InstallPlan(config: sampleConfig(), mode: .install, source: .folder(folder))

        XCTAssertNil(DropZoneController.previousAppSupportName(
            currentBundle: fakeBundle, target: .applyInPlace))

        _ = try await DropZoneController.performApply(
            plan: plan, target: .applyInPlace,
            currentBundle: fakeBundle, icnsURL: nil, progress: { _ in }
        )
    }

    func testApplyBundleKeepsInBundleCiderJSON() async throws {
        // Pre-seed too — Bundle mode rewrites it; just make sure we don't
        // accidentally delete it before the Installer writes the new one.
        let stale = fakeBundle.appendingPathComponent("cider.json")
        try Data("stale".utf8).write(to: stale)

        let folder = try makeFolder(named: "Game", files: ["start.exe": "x"])
        let plan = InstallPlan(
            config: sampleConfig(exe: "start.exe"),
            mode: .bundle,
            source: .folder(folder)
        )
        let final = try await DropZoneController.performApply(
            plan: plan, target: .applyInPlace,
            currentBundle: fakeBundle, icnsURL: nil, progress: { _ in }
        )
        let cider = final.appendingPathComponent("cider.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cider.path))
        let written = try CiderConfig.read(from: cider)
        XCTAssertEqual(written.applicationPath,
                       "System/drive_c/Program Files/\(displayName)",
                       "the new (schema-v3 Bundle-mode) config replaced the stale one")
        XCTAssertEqual(written.prefixPath, "System")
    }
}
