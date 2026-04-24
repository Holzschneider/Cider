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
            config: sampleConfig(),
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

        // cider.json went into the renamed bundle (sibling of Contents/),
        // applicationPath = "Application", and the Application/Game/
        // tree got materialised.
        let inBundleConfig = final.appendingPathComponent("cider.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inBundleConfig.path))
        let written = try CiderConfig.read(from: inBundleConfig)
        XCTAssertEqual(written.applicationPath, "Application")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("Application/Game/start.exe").path))
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

    func testApplyBundleKeepsInBundleCiderJSON() async throws {
        // Pre-seed too — Bundle mode rewrites it; just make sure we don't
        // accidentally delete it before the Installer writes the new one.
        let stale = fakeBundle.appendingPathComponent("cider.json")
        try Data("stale".utf8).write(to: stale)

        let folder = try makeFolder(named: "Game", files: ["start.exe": "x"])
        let plan = InstallPlan(config: sampleConfig(), mode: .bundle, source: .folder(folder))
        let final = try await DropZoneController.performApply(
            plan: plan, target: .applyInPlace,
            currentBundle: fakeBundle, icnsURL: nil, progress: { _ in }
        )
        let cider = final.appendingPathComponent("cider.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cider.path))
        let written = try CiderConfig.read(from: cider)
        XCTAssertEqual(written.applicationPath, "Application",
                       "the new (Bundle-mode) config replaced the stale one")
    }
}
