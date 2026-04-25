import XCTest
@testable import CiderModels
@testable import CiderCore

final class PreflightRunnerTests: XCTestCase {
    private var stagingPaths: [URL] = []

    override func tearDown() {
        for p in stagingPaths { try? FileManager.default.removeItem(at: p) }
        super.tearDown()
    }

    // MARK: - Fixtures

    // Build a fake Sikarugir-style engine cache that the PreflightRunner
    // can probe without going to the network. Lays out:
    //   <root>/<engineName>/.cider-extracted
    //   <root>/<engineName>/wswine.bundle/bin/wine     (executable shim)
    private func makeEngineCache(named engineName: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-engine-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stagingPaths.append(root)

        let engine = root.appendingPathComponent(engineName, isDirectory: true)
        let bin = engine.appendingPathComponent("wswine.bundle/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        // Tiny shim that pretends to be `wine`. PreflightRunner only
        // execs it for `wineboot -u` and `reg add`; both must succeed
        // and create drive_c/windows so the "is initialised?" probe
        // flips to true on subsequent runs.
        let wine = bin.appendingPathComponent("wine")
        let shim = """
        #!/bin/bash
        # PreflightRunner shim — emulates wineboot -u + reg add by
        # creating drive_c/windows under $WINEPREFIX. Anything else is
        # a silent no-op.
        if [ "$1" = "wineboot" ]; then
            mkdir -p "$WINEPREFIX/drive_c/windows/system32"
            mkdir -p "$WINEPREFIX/drive_c/windows/syswow64"
        fi
        exit 0
        """
        try shim.write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wine.path)

        let marker = engine.appendingPathComponent(".cider-extracted")
        try Data().write(to: marker)
        return root
    }

    private func makeTemplateCache(version: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-template-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stagingPaths.append(root)

        let templateDir = root.appendingPathComponent("Template-\(version)",
                                                      isDirectory: true)
        let templateApp = templateDir.appendingPathComponent("Template-\(version).app",
                                                             isDirectory: true)
        // Lay out the renderer/d3dmetal/wine/x86_64-windows tree with
        // a single fake .dll so GraphicsDriver finds something to copy.
        let renderer = templateApp
            .appendingPathComponent("Contents/Frameworks/renderer/d3dmetal/wine/x86_64-windows",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try Data("dll".utf8).write(to: renderer.appendingPathComponent("d3d11.dll"))

        try Data().write(to: templateDir.appendingPathComponent(".cider-extracted"))
        return root
    }

    private func tempPrefixDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-pf-prefix-\(UUID().uuidString)",
                                    isDirectory: true)
        stagingPaths.append(url)
        return url
    }

    private func sampleConfig(
        engineName: String = "FakeEngine",
        prefixPath: String? = nil
    ) -> CiderConfig {
        CiderConfig(
            displayName: "PreflightTest",
            applicationPath: "Anywhere",
            exe: "Game.exe",
            engine: .init(name: engineName, url: "https://example.com/engine.tar.xz"),
            graphics: .d3dmetal,
            prefixPath: prefixPath
        )
    }

    private func runner(engineRoot: URL, templateRoot: URL) -> PreflightRunner {
        PreflightRunner(
            engineManager: EngineManager(cacheRoot: engineRoot),
            templateManager: TemplateManager(cacheRoot: templateRoot)
        )
    }

    // MARK: - Plan

    func testPlanReportsAlreadyDoneForCachedEngineAndTemplate() throws {
        let engineRoot = try makeEngineCache(named: "FakeEngine")
        let templateRoot = try makeTemplateCache(
            version: CiderConfig.TemplateRef.default.version)

        let r = runner(engineRoot: engineRoot, templateRoot: templateRoot)
        // Send the prefix into a fresh dir so prefixInit shows as not done.
        let prefix = tempPrefixDir()
        let configFile = prefix.appendingPathComponent("cider.json")  // not created
        var config = sampleConfig()
        config.prefixPath = prefix.lastPathComponent  // resolves to `prefix`
        let plan = r.plan(for: config, configFile: configFile)

        let byID = Dictionary(uniqueKeysWithValues: plan.map { ($0.id, $0) })
        XCTAssertEqual(byID[.engineDownload]?.alreadyDone, true)
        XCTAssertEqual(byID[.templateDownload]?.alreadyDone, true)
        XCTAssertEqual(byID[.prefixInit]?.alreadyDone, false,
                       "fresh prefix dir → wineboot still required")
        XCTAssertEqual(byID[.graphicsInstall]?.alreadyDone, false,
                       "graphics is cheap and always re-runs")
    }

    // MARK: - End-to-end

    func testRunPopulatesPrefixViaShimAndInstallsGraphics() async throws {
        let engineRoot = try makeEngineCache(named: "FakeEngine")
        let templateRoot = try makeTemplateCache(
            version: CiderConfig.TemplateRef.default.version)

        // Use an in-bundle prefix so we don't pollute AppSupport.
        let prefix = tempPrefixDir()
        let configFile = prefix.appendingPathComponent("cider.json")
        var config = sampleConfig()
        config.prefixPath = prefix.path  // absolute → resolved as-is

        var events: [String] = []
        try await runner(engineRoot: engineRoot, templateRoot: templateRoot)
            .run(for: config, configFile: configFile) { e in
                switch e {
                case .started(let id): events.append("start:\(id.rawValue)")
                case .progress:        break
                case .done(let id):    events.append("done:\(id.rawValue)")
                }
            }

        // Engine + template were already cached → no start/done for them.
        XCTAssertFalse(events.contains("start:preflight.engine"))
        XCTAssertFalse(events.contains("start:preflight.template"))
        XCTAssertTrue(events.contains("start:preflight.prefix"))
        XCTAssertTrue(events.contains("done:preflight.prefix"))
        XCTAssertTrue(events.contains("start:preflight.graphics"))
        XCTAssertTrue(events.contains("done:preflight.graphics"))

        // The shim created drive_c/windows.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prefix.appendingPathComponent("drive_c/windows").path))
        // Graphics step copied the fake .dll into system32.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prefix.appendingPathComponent("drive_c/windows/system32/d3d11.dll").path))
    }

    func testRunIsIdempotentWhenEverythingIsAlreadyDone() async throws {
        let engineRoot = try makeEngineCache(named: "FakeEngine")
        let templateRoot = try makeTemplateCache(
            version: CiderConfig.TemplateRef.default.version)

        let prefix = tempPrefixDir()
        let configFile = prefix.appendingPathComponent("cider.json")
        var config = sampleConfig()
        config.prefixPath = prefix.path

        let r = runner(engineRoot: engineRoot, templateRoot: templateRoot)
        // First pass — does the work.
        try await r.run(for: config, configFile: configFile) { _ in }
        // Second pass — engine/template/prefix already done; only the
        // (cheap) graphics step should fire start+done.
        var events: [String] = []
        try await r.run(for: config, configFile: configFile) { e in
            switch e {
            case .started(let id): events.append("start:\(id.rawValue)")
            case .progress:        break
            case .done(let id):    events.append("done:\(id.rawValue)")
            }
        }
        XCTAssertEqual(events, [
            "start:preflight.graphics",
            "done:preflight.graphics"
        ], "second-pass with everything already-done should only re-run graphics")
    }
}
