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

    // Sendable bridge to the SwiftUI LoadingProgressModel that lives
    // in the app target. Lets Core push raw wine-stdout lines and
    // determinate progress straight at the loading window without
    // depending on AppKit/SwiftUI types.
    public struct LoadingBridge: Sendable {
        public let setLine: @Sendable (String) -> Void
        public let setProgress: @Sendable (Double?) -> Void
        public init(
            setLine: @escaping @Sendable (String) -> Void,
            setProgress: @escaping @Sendable (Double?) -> Void
        ) {
            self.setLine = setLine
            self.setProgress = setProgress
        }
    }

    // Thread-safe holder for the running wine Process so the loading
    // window's (X) hover button can SIGTERM it after launch. The
    // handle is created up front by the caller; the pipeline
    // .install()s the wine Process into it as soon as WineLauncher
    // hands one back.
    public final class CancelHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        public init() {}

        public func install(_ p: Process) {
            lock.lock(); defer { lock.unlock() }
            process = p
        }

        // Sends SIGTERM. Returns true if a process was alive to
        // signal. The caller decides whether to follow up with
        // SIGKILL after a grace period (~5 s).
        @discardableResult
        public func sigterm() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let p = process, p.isRunning else { return false }
            p.terminate()
            return true
        }

        public func sigkill() {
            lock.lock(); defer { lock.unlock() }
            guard let p = process, p.isRunning else { return }
            kill(p.processIdentifier, SIGKILL)
        }

        public var isAlive: Bool {
            lock.lock(); defer { lock.unlock() }
            return process?.isRunning ?? false
        }
    }

    public let config: CiderConfig
    public let configFileURL: URL          // location the cider.json was loaded from
    public let bundleURL: URL
    public let bundleName: String

    private let progress: ProgressCallback
    private let settle: SettleCallback
    private let onError: ErrorCallback
    private let loading: LoadingBridge?
    private let cancelHandle: CancelHandle?

    public init(
        config: CiderConfig,
        configFileURL: URL,
        bundleURL: URL,
        bundleName: String,
        progress: @escaping ProgressCallback,
        settle: @escaping SettleCallback,
        onError: @escaping ErrorCallback,
        loading: LoadingBridge? = nil,
        cancelHandle: CancelHandle? = nil
    ) {
        self.config = config
        self.configFileURL = configFileURL
        self.bundleURL = bundleURL
        self.bundleName = bundleName
        self.progress = progress
        self.settle = settle
        self.onError = onError
        self.loading = loading
        self.cancelHandle = cancelHandle
    }

    // Returns wine's exit code. Throws on any pre-launch failure (engine
    // download, prefix init, etc.). Once wine actually starts, errors are
    // surfaced via the lineStream and the wine exit code.
    public func runEndToEnd() async throws -> Int32 {
        var stats = CiderRuntimeStats.loadOrDefault(
            from: AppSupport.runtimeStats(forBundleNamed: bundleName))

        // 1. Resolve application directory from cider.json's applicationPath
        //    (relative to the cider.json's own location, or absolute for
        //    Link mode). Validate it exists AND that the configured exe
        //    sits where it claims to. The CLI / launcher catches these
        //    typed errors and routes the user through the in-Configure
        //    recovery flow with the offending field flagged red.
        let applicationDir = config.resolvedApplicationDirectory(configFile: configFileURL)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: applicationDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw PipelineError.applicationDirectoryMissing(applicationDir)
        }
        let exeURL = config.resolvedExecutable(configFile: configFileURL)
        if !FileManager.default.fileExists(atPath: exeURL.path) {
            throw PipelineError.executableMissing(exeURL)
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

        // 5. Prefix — either an in-bundle "System" prefix (Bundle mode)
        //    or a shared AppSupport prefix keyed by config-derived hash
        //    (Install / Link). The prefix's own "is initialised?" marker
        //    is the wineboot output (drive_c/windows). We don't trust
        //    RuntimeStats here because shared prefixes can be initialised
        //    by a different bundle and we'd never see the flag.
        let prefix = Self.selectPrefix(config: config, configFile: configFileURL)
        let prefixInit = PrefixInitializer(prefix: prefix, wineBinary: wineBinary)
        let alreadyInitialised = FileManager.default.fileExists(
            atPath: prefix.appendingPathComponent("drive_c/windows").path)
        if !alreadyInitialised {
            progress("Initialising Wine prefix", "first run only — ~30s", nil)
            try prefixInit.initialise(skip: false)
            stats.prefixInitialised = true
            try? stats.write(to: AppSupport.runtimeStats(forBundleNamed: bundleName))
        }

        // 6. Stage payload — single symlink Program Files/<bundleName>
        //    → applicationDir. Skipped for in-bundle prefixes (Bundle
        //    mode), where applicationDir is already at exactly that
        //    spot inside the prefix and Wine sees it natively.
        let winExePath: String
        if isInBundlePrefix(config: config, configFile: configFileURL) {
            winExePath = "C:\\Program Files\\\(bundleName)\\"
                + config.exe.replacingOccurrences(of: "/", with: "\\")
        } else {
            progress("Linking source into prefix", "", nil)
            winExePath = try prefixInit.stagePayload(
                from: applicationDir,
                exeRelativePath: config.exe,
                programName: bundleName
            )
        }

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
        // For .logFile loading source: wipe any pre-existing file so
        // we don't read stale lines from a previous session as if
        // they were live.
        let loadingConfig = config.loading ?? .default
        let logFileURL = resolvedLogFileURL(loadingConfig: loadingConfig,
                                            applicationDir: applicationDir)
        if loadingConfig.source == .logFile, let logFileURL {
            LogFileTailer.resetFile(at: logFileURL)
        }
        let running = try WineLauncher(plan: plan).launch()
        cancelHandle?.install(running.process)

        // 9. Pump lines from the configured source through the
        //    line counter, drive splash overlay + loading window.
        let counter = ConsoleLineCounter(
            baseline: stats.loadLineCount,
            explicitTarget: loadingConfig.expectedLineCount
        )
        let counterRef = ConsoleLineCounterBox(counter: counter)
        let lineSource: AsyncStream<String>
        if loadingConfig.source == .logFile, let logFileURL {
            lineSource = LogFileTailer(url: logFileURL).lines()
        } else {
            lineSource = running.lineStream
        }
        let loadingBridge = self.loading
        let lineTask = Task { [progress, counterRef, loadingBridge] in
            var batch: [String] = []
            for await line in lineSource {
                batch.append(line)
                // Push the latest raw line straight to the loading
                // window's status row. Doing it per-line keeps the
                // status reactive even when batches haven't flushed.
                loadingBridge?.setLine(line)
                if batch.count >= 8 {
                    let snap = counterRef.record(batch)
                    batch.removeAll(keepingCapacity: true)
                    progress("Loading", "\(snap.lineCount) lines", snap.progress)
                    loadingBridge?.setProgress(snap.progress)
                }
            }
            if !batch.isEmpty {
                let snap = counterRef.record(batch)
                loadingBridge?.setProgress(snap.progress)
            }
        }
        // Periodic ticker for settle detection. Hides the overlay (via the
        // settle callback) once line rate has dropped — Phase 5's
        // ConsoleLineCounter handles the timing. Also enforces the
        // explicit autoHideOnTarget rule from cider.json.
        let settleTask = Task { [counterRef, settle, loadingBridge] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let snap = counterRef.tick()
                if let progress = snap.progress {
                    loadingBridge?.setProgress(progress)
                }
                if loadingConfig.autoHideOnTarget,
                   let target = loadingConfig.expectedLineCount,
                   target > 0,
                   snap.lineCount >= target {
                    settle()
                    return
                }
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

    // Resolves cider.json's loading.logFilePath against the
    // application directory (relative paths) or as-is (absolute / ~).
    // Returns nil when the path is unset / blank — caller treats that
    // the same as "log file source disabled".
    private func resolvedLogFileURL(loadingConfig: CiderConfig.Loading,
                                    applicationDir: URL) -> URL? {
        guard loadingConfig.source == .logFile,
              let raw = loadingConfig.logFilePath?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return applicationDir.appendingPathComponent(expanded)
    }

    // The prefix this config should run in. cider.json's `prefixPath`
    // (set by Bundle mode to "System") points at an in-bundle prefix;
    // anything else uses an AppSupport prefix slot keyed by config-
    // derived identity so identical wine setups can share a prefix
    // across multiple bundles.
    public static func selectPrefix(config: CiderConfig, configFile: URL) -> URL {
        if let bundlePrefix = config.resolvedPrefixDirectory(configFile: configFile) {
            return bundlePrefix
        }
        let identity = PrefixIdentity.compute(for: config)
        return AppSupport.prefix(forIdentityKey: identity.key)
    }

    // True when the config's prefix lives inside the .app bundle
    // (Bundle mode). In that layout the application data is already
    // sitting under the prefix's drive_c/Program Files/<programName>/
    // — no staging symlink needed.
    private func isInBundlePrefix(config: CiderConfig, configFile: URL) -> Bool {
        config.resolvedPrefixDirectory(configFile: configFile) != nil
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
    case executableMissing(URL)
    public var description: String {
        switch self {
        case .applicationDirectoryMissing(let url):
            return "Application directory missing: \(url.path)"
        case .executableMissing(let url):
            return "Executable not found: \(url.path)"
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
