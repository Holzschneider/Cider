import Foundation
import CiderModels

// End-to-end "config → wine running" orchestrator. Drives the splash via
// progressCallback (the GUI plugs in a closure that updates ProgressModel)
// and signals settle/exit so the splash can be hidden / the app can quit.
//
// All async; designed to be kicked off from a Task while NSApp.run() is
// driving the AppKit event loop.
public final class LaunchPipeline {
    public typealias ProgressCallback = @Sendable (String, String, Double?) -> Void
    public typealias SettleCallback = @Sendable () -> Void
    public typealias ErrorCallback = @Sendable (Swift.Error) -> Void

    public let config: CiderConfig
    public let configFileURL: URL          // location the cider.json was loaded from
    public let bundleURL: URL
    public let bundleName: String

    private let progress: ProgressCallback
    private let settle: SettleCallback
    private let onError: ErrorCallback

    public init(
        config: CiderConfig,
        configFileURL: URL,
        bundleURL: URL,
        bundleName: String,
        progress: @escaping ProgressCallback,
        settle: @escaping SettleCallback,
        onError: @escaping ErrorCallback
    ) {
        self.config = config
        self.configFileURL = configFileURL
        self.bundleURL = bundleURL
        self.bundleName = bundleName
        self.progress = progress
        self.settle = settle
        self.onError = onError
    }

    // Returns wine's exit code. Throws on any pre-launch failure (engine
    // download, prefix init, etc.). Once wine actually starts, errors are
    // surfaced via the lineStream and the wine exit code.
    public func runEndToEnd() async throws -> Int32 {
        var stats = CiderRuntimeStats.loadOrDefault(
            from: AppSupport.runtimeStats(forBundleNamed: bundleName))

        // 1. Resolve application directory from cider.json's applicationPath
        //    (relative to the cider.json's own location, or absolute for
        //    Link mode). Validate it exists — Phase 9 surfaces this as an
        //    in-form error; for now we throw.
        let applicationDir = config.resolvedApplicationDirectory(configFile: configFileURL)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: applicationDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw PipelineError.applicationDirectoryMissing(applicationDir)
        }
        progress("Resolved source", applicationDir.lastPathComponent, nil)

        // 2. Engine.
        progress("Preparing engine", config.engine.name, nil)
        let engineRoot = try await EngineManager().ensure(
            config.engine,
            forceRefresh: false,
            progress: { p in self.report(p, asTitle: "Downloading engine") }
        )

        // 3. Wrapper template.
        progress("Preparing wrapper template", config.wrapperTemplate.version, nil)
        let templateApp = try await TemplateManager().ensure(
            config.wrapperTemplate,
            progress: { p in self.report(p, asTitle: "Downloading template") }
        )
        // Template Frameworks must sit next to wswine.bundle/ so wine's
        // @loader_path/../../ rpath resolves libinotify, libgnutls, etc.
        try copyTemplateFrameworks(into: engineRoot, from: templateApp)

        // 4. Locate wine binary.
        let wineBinary = try EngineManager().wineBinaryPath(in: engineRoot)

        // 5. Prefix.
        let prefix = AppSupport.prefix(forBundleNamed: bundleName)
        let prefixInit = PrefixInitializer(prefix: prefix, wineBinary: wineBinary)
        if !stats.prefixInitialised {
            progress("Initialising Wine prefix", "first run only — ~30s", nil)
            try prefixInit.initialise(skip: false)
            stats.prefixInitialised = true
            try? stats.write(to: AppSupport.runtimeStats(forBundleNamed: bundleName))
        }

        // 6. Stage payload (symlinks).
        progress("Linking source into prefix", "", nil)
        let winExePath = try prefixInit.stagePayload(
            from: applicationDir,
            exeRelativePath: config.exe,
            programName: bundleName,
            mode: .symlinks
        )

        // 7. Graphics driver DLLs.
        progress("Installing graphics driver", config.graphics.rawValue, nil)
        let graphicsResult = try GraphicsDriver(
            kind: config.graphics,
            prefix: prefix,
            templateApp: templateApp,
            templateManager: TemplateManager()
        ).install()

        // 8. Launch wine.
        let plan = WineLauncher.Plan(
            wineBinary: wineBinary,
            engineRoot: engineRoot,
            prefix: prefix,
            displayName: bundleName,
            exeRelative: config.exe,
            exeArgs: config.args,
            wine: config.wine,
            dllOverrides: graphicsResult.dllOverrides,
            graphicsExtraEnv: graphicsResult.extraEnv
        )
        _ = winExePath
        progress("Launching", config.displayName, nil)
        let running = try WineLauncher(plan: plan).launch()

        // 9. Pump stdout/err through the line counter, drive splash overlay.
        let counter = ConsoleLineCounter(baseline: stats.loadLineCount)
        let counterRef = ConsoleLineCounterBox(counter: counter)
        let lineTask = Task { [progress, counterRef] in
            var batch: [String] = []
            for await line in running.lineStream {
                batch.append(line)
                if batch.count >= 8 {
                    let snap = counterRef.record(batch)
                    batch.removeAll(keepingCapacity: true)
                    progress("Loading", "\(snap.lineCount) lines", snap.progress)
                }
            }
            if !batch.isEmpty {
                _ = counterRef.record(batch)
            }
        }
        // Periodic ticker for settle detection. Hides the overlay (via the
        // settle callback) once line rate has dropped — Phase 5's
        // ConsoleLineCounter handles the timing.
        let settleTask = Task { [counterRef, settle] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let snap = counterRef.tick()
                if snap.settled {
                    settle()
                    return
                }
            }
        }

        let exitCode = await running.waitForExit()
        lineTask.cancel()
        settleTask.cancel()
        // Final settle in case wine exited before the settle threshold.
        settle()

        // 10. Persist stats.
        let finalCount = counterRef.tick().lineCount
        if finalCount > 0 {
            stats.loadLineCount.record(finalCount)
        }
        try? stats.write(to: AppSupport.runtimeStats(forBundleNamed: bundleName))

        return exitCode
    }

    // Mirror Downloader progress → splash overlay text + fraction.
    private func report(_ p: Downloader.Progress, asTitle title: String) {
        let fraction: Double? = p.total > 0 ? Double(p.bytes) / Double(p.total) : nil
        let detail: String
        if p.total > 0 {
            let mb = Double(p.bytes) / 1_048_576
            let totalMB = Double(p.total) / 1_048_576
            detail = String(format: "%.1f / %.1f MB", mb, totalMB)
        } else {
            let mb = Double(p.bytes) / 1_048_576
            detail = String(format: "%.1f MB", mb)
        }
        progress(title, detail, fraction)
    }

    // Copy the template's Frameworks/ next to wswine.bundle/ inside the
    // engine cache. Idempotent: skips entries that already exist.
    private func copyTemplateFrameworks(into engineRoot: URL, from templateApp: URL) throws {
        let frameworks = templateApp
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
        guard FileManager.default.fileExists(atPath: frameworks.path) else { return }
        let entries = try FileManager.default.contentsOfDirectory(
            at: frameworks,
            includingPropertiesForKeys: nil
        )
        for entry in entries {
            let dest = engineRoot.appendingPathComponent(entry.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            try Shell.run("/bin/cp", ["-a", entry.path, dest.path], captureOutput: true)
        }
    }
}

public enum PipelineError: Swift.Error, CustomStringConvertible {
    case applicationDirectoryMissing(URL)
    public var description: String {
        switch self {
        case .applicationDirectoryMissing(let url):
            return "Application directory missing: \(url.path)"
        }
    }
}

// Sendable wrapper around ConsoleLineCounter (which is reference-counted
// but not annotated). Lets the line / settle Tasks share state without
// fighting the compiler.
final class ConsoleLineCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private let counter: ConsoleLineCounter

    init(counter: ConsoleLineCounter) {
        self.counter = counter
    }

    @discardableResult
    func record(_ batch: [String]) -> ConsoleLineCounter.Snapshot {
        lock.lock(); defer { lock.unlock() }
        return counter.record(lines: batch)
    }

    @discardableResult
    func tick() -> ConsoleLineCounter.Snapshot {
        lock.lock(); defer { lock.unlock() }
        return counter.tick()
    }
}
