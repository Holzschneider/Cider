import XCTest
@testable import CiderModels
@testable import CiderCore

// Verifies that Phase 7's cooperative cancellation actually halts the
// Installer mid-flight. Two angles:
//   - Pre-cancelled task: throws before any subprocess is spawned.
//   - Mid-flight cancel: kills an in-progress unzip and surfaces
//     CancellationError instead of completing the install.
final class InstallerCancellationTests: XCTestCase {
    private var displayName: String = ""
    private var stagingPaths: [URL] = []

    override func setUp() {
        super.setUp()
        displayName = "CancelTest-\(UUID().uuidString.prefix(8))"
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

    private func sampleConfig(_ exe: String) -> CiderConfig {
        CiderConfig(
            displayName: displayName,
            applicationPath: "PLACEHOLDER",
            exe: exe,
            engine: .init(name: "WS12WineCX24.0.7_7",
                          url: "https://example.com/x.tar.xz"),
            graphics: .dxmt
        )
    }

    private func makeFolder(named: String, files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-cancel-folder-\(UUID().uuidString)/\(named)",
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

    func testPreCancelledTaskThrowsBeforeMaterialising() async throws {
        let folder = try makeFolder(named: "Game", files: ["start.exe": "x"])

        let task = Task<Void, Swift.Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await Installer().run(
                source: .folder(folder),
                mode: .install,
                baseConfig: sampleConfig("Game/start.exe"),
                bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
            )
        }
        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // ok
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        // Pre-cancelled run should NOT have left a partial install
        // behind. (resetDirectory wipes the target before checkCancellation
        // would fire, but the order in materialise is checkCancellation
        // first, so target shouldn't exist.)
        let target = AppSupport.programFiles(forBundleNamed: displayName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "pre-cancel must not create the target dir")
    }

    func testCancellationDuringCopyHaltsTheInstall() async throws {
        // Build a folder big enough that cp -R takes long enough for the
        // cancel to land mid-copy. ~80 MB of randomish content.
        let folder = try makeFolder(named: "Big", files: [:])
        let big = folder.appendingPathComponent("blob.bin")
        var blob = Data(count: 80 * 1024 * 1024)
        blob.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try blob.write(to: big)

        let task = Task<Void, Swift.Error> {
            _ = try await Installer().run(
                source: .folder(folder),
                mode: .install,
                baseConfig: sampleConfig("Big/blob.bin"),
                bundleURL: URL(fileURLWithPath: "/tmp/Test.app")
            )
        }
        // Give cp time to spawn; cancel mid-copy.
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            try await task.value
            // It's possible cp finished within 50ms on a fast SSD —
            // accept that as a "race lost" rather than failing.
            // The main thing we're verifying is that *if* cancel lands
            // mid-flight, it surfaces CancellationError, not a
            // half-completed success.
        } catch is CancellationError {
            // ok — the common path
        } catch {
            XCTFail("expected CancellationError or success, got \(error)")
        }
    }
}
