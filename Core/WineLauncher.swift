import Foundation
import CiderModels

// In-process Swift replacement for the bash launcher we polished earlier.
// Handles everything the shell launcher did:
//
//   - Env wiring:
//       WINEPREFIX, PATH, DYLD_FALLBACK_LIBRARY_PATH
//       (engine + engine/moltenvkcx + wswine.bundle/lib + standard fallbacks),
//       WINEDLLOVERRIDES, WINEMSYNC=1, WINEESYNC=1, graphics-driver extras.
//   - Working directory: Program Files/<displayName>/<exeParent> inside the
//     prefix so apps that drop side files put them next to the exe.
//   - Console mode: write run.bat next to the exe and invoke via
//     `cmd.exe /c "<winBatPath>"` so console-subsystem / TUI apps get a
//     real Windows console allocated by cmd. Optional `--inheritConsole`
//     prefixes the exe call with `start "" /B /WAIT` (suppresses the
//     graphical conhost pop-up but propagates CREATE_NO_WINDOW to
//     children — document caveats for the UI).
//   - Signal-only wineserver -k teardown on INT/TERM/HUP; normal exit
//     leaves wineserver to self-reap (patcher → game handoff pattern).
public struct WineLauncher {
    public struct Plan {
        // Resolved paths:
        public let wineBinary: URL           // …/wswine.bundle/bin/wine
        public let engineRoot: URL           // parent of wswine.bundle; contains template dylibs
        public let prefix: URL

        // From cider.json:
        public let displayName: String       // becomes "Program Files/<displayName>/" in the prefix
        public let exeRelative: String       // path relative to the source folder / staged payload
        public let exeArgs: [String]
        public let wine: CiderConfig.WineOptions
        public let dllOverrides: String
        public let graphicsExtraEnv: [String: String]
    }

    public let plan: Plan

    public init(plan: Plan) {
        self.plan = plan
    }

    // MARK: - Public API

    // Spawns wine (or cmd+wine when console mode is on) and returns a
    // handle that streams stdout/stderr lines and the eventual exit code.
    public func launch() throws -> Running {
        let env = buildEnvironment()
        let workingDir = self.workingDirInsidePrefix()
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)

        let winExePath = self.winExePath()
        let arguments: [String]

        if plan.wine.console {
            let batOnDisk = workingDir.appendingPathComponent("run.bat")
            try writeRunBat(at: batOnDisk, winExePath: winExePath)
            arguments = [
                #"C:\windows\system32\cmd.exe"#,
                "/c",
                winBatPath()
            ]
        } else {
            arguments = [winExePath] + plan.exeArgs
        }

        // Build a per-launch wrapper .app bundle around the engine's
        // wine binary so macOS reads OUR Info.plist when wine becomes
        // the foreground process — menu-bar app slot now reads the
        // configured Application Name instead of the .exe filename.
        // Wine's @loader_path-relative dylib lookups still resolve in
        // the engine cache (the wrapper is just a symlink).
        let wrapper = try WineWrapperBundle.make(
            displayName: plan.displayName,
            engineWineBinary: plan.wineBinary
        )

        let process = Process()
        process.executableURL = wrapper.wineURL
        process.arguments = arguments
        process.environment = env
        process.currentDirectoryURL = workingDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = LineBuffer()
        let stream = AsyncStream<String> { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    // Drain any trailing partial line, then finish.
                    buffer.flush().forEach { continuation.yield($0) }
                    continuation.finish()
                    handle.readabilityHandler = nil
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                for line in buffer.feed(text) {
                    continuation.yield(line)
                }
            }
            continuation.onTermination = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
            }
        }

        try process.run()
        Log.info("wine launched (pid \(process.processIdentifier)) via wrapper \(wrapper.bundleURL.lastPathComponent)")
        return Running(process: process, lineStream: stream, plan: plan, wrapper: wrapper)
    }

    // MARK: - Lifecycle handle

    public final class Running {
        public let process: Process
        public let lineStream: AsyncStream<String>
        let plan: Plan
        // Per-launch wrapper bundle the wine binary was spawned
        // through. Cleaned up when this Running drops out of scope.
        let wrapper: WineWrapperBundle.Built

        init(process: Process, lineStream: AsyncStream<String>, plan: Plan,
             wrapper: WineWrapperBundle.Built) {
            self.process = process
            self.lineStream = lineStream
            self.plan = plan
            self.wrapper = wrapper
        }

        deinit {
            // Best-effort cleanup. Survives if the process is still
            // running — the symlink keeps wine's executable alive
            // through its inode reference.
            WineWrapperBundle.cleanup(wrapper)
        }

        // Waits for wine to exit and returns its exit status.
        public func waitForExit() async -> Int32 {
            await withCheckedContinuation { cont in
                process.terminationHandler = { p in
                    cont.resume(returning: p.terminationStatus)
                }
            }
        }

        // Fire-and-forget teardown of the entire wine session. Only call
        // on interrupt (Ctrl-C / app quit while splash still visible) —
        // not on normal exit, or we kill the game the patcher just
        // handed off to.
        public func teardownWineSession() {
            let wineserver = plan.wineBinary
                .deletingLastPathComponent()
                .appendingPathComponent("wineserver")
            _ = try? Shell.run(wineserver.path, ["-k"], environment: [
                "WINEPREFIX": plan.prefix.path,
                "WINEDEBUG": "-all"
            ], captureOutput: true)
        }
    }

    // MARK: - Helpers

    // Mirrors the bash launcher's working-dir computation: the macOS-side
    // directory that maps to the exe's drive_c/Program Files/<displayName>/
    // ancestor, so apps that drop side files put them next to the exe.
    private func workingDirInsidePrefix() -> URL {
        let exeRelDir = (plan.exeRelative as NSString).deletingLastPathComponent
        var wd = plan.prefix
            .appendingPathComponent("drive_c")
            .appendingPathComponent("Program Files")
            .appendingPathComponent(plan.displayName)
        if !exeRelDir.isEmpty {
            wd = wd.appendingPathComponent(exeRelDir)
        }
        return wd
    }

    private func winExePath() -> String {
        // "C:\Program Files\<displayName>\<exeRelative with / → \>"
        let winRel = plan.exeRelative.replacingOccurrences(of: "/", with: #"\"#)
        return #"C:\Program Files\"# + plan.displayName + #"\"# + winRel
    }

    private func winBatPath() -> String {
        let exeRelDir = (plan.exeRelative as NSString).deletingLastPathComponent
        var dir = #"C:\Program Files\"# + plan.displayName
        if !exeRelDir.isEmpty {
            dir += #"\"# + exeRelDir.replacingOccurrences(of: "/", with: #"\"#)
        }
        return dir + #"\run.bat"#
    }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = plan.prefix.path

        let wineBinDir = plan.wineBinary.deletingLastPathComponent().path
        env["PATH"] = wineBinDir + ":" + (env["PATH"] ?? "/usr/bin:/bin")

        // dlopen on macOS doesn't consult the wine binary's LC_RPATH; wine's
        // font driver / vulkan loader / etc. dlopen support dylibs by leaf
        // name, so DYLD_FALLBACK_LIBRARY_PATH must point at:
        //   - $engineRoot            (template Frameworks/* deposited here)
        //   - $engineRoot/moltenvkcx (MoltenVK variant shipped by template)
        //   - wswine.bundle/lib      (wine's own libs)
        let wineLib = plan.wineBinary
            .deletingLastPathComponent()         // bin/
            .deletingLastPathComponent()         // wswine.bundle/
            .appendingPathComponent("lib")
            .path
        let existingFallback = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "/usr/local/lib:/usr/lib"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [
            plan.engineRoot.path,
            plan.engineRoot.appendingPathComponent("moltenvkcx").path,
            wineLib,
            existingFallback
        ].joined(separator: ":")

        env["WINEDLLOVERRIDES"] = plan.dllOverrides
        // Defaults match the working Sikarugir config for 32-bit titles.
        if plan.wine.msync { env["WINEMSYNC"] = "1" }
        if plan.wine.esync { env["WINEESYNC"] = "1" }

        // Graphics-driver extras (DXVK_HUD, MTL_HUD_ENABLED, …).
        for (k, v) in plan.graphicsExtraEnv { env[k] = v }

        // Inject the menu-injector dylib that adds Settings… into
        // wine's app menu. Only effective when the wine binary is
        // entitled with allow-dyld-environment-variables AND
        // disable-library-validation (Sikarugir / CrossOver / Whisky
        // engines all are). Failure is silent — the menu just lacks
        // the extra item; wine still runs.
        if let injector = injectorDylibURL() {
            let existing = env["DYLD_INSERT_LIBRARIES"]
            env["DYLD_INSERT_LIBRARIES"] = existing.map { "\($0):\(injector.path)" }
                ?? injector.path
            env["CIDER_PARENT_PID"] = String(getpid())
            env["CIDER_MENU_NOTIFICATION"] = "app.cider.menu.showSettings"
        }

        return env
    }

    // Looks up the injector dylib bundled at
    //   Cider.app/Contents/MacOS/CiderMenuInjector.dylib
    // — same directory as the cider binary. Returns nil for headless
    // / dev-time runs where the binary isn't running from inside an
    // .app bundle.
    private func injectorDylibURL() -> URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let candidate = exe.deletingLastPathComponent()
            .appendingPathComponent("CiderMenuInjector.dylib")
        return FileManager.default.fileExists(atPath: candidate.path)
            ? candidate : nil
    }

    // Same bat shape as BundleBuilder.writeRunBat in the old CLI, ported
    // faithfully (stdin from NUL, stdout/err to all.txt, optional `start`
    // prefix for --inheritConsole). CRLF + trailing newline for cmd.
    func writeRunBat(at url: URL, winExePath: String) throws {
        let argLine = plan.exeArgs.map { #""\#($0)""# }.joined(separator: " ")
        let prefix = plan.wine.inheritConsole ? #"start "" /B /WAIT "# : ""
        let bat = """
        @echo off
        \(prefix)\"\(winExePath)\" \(argLine) < NUL > all.txt 2>&1

        """
        let crlf = bat.replacingOccurrences(of: "\n", with: "\r\n")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(crlf.utf8).write(to: url)
    }
}

// Splits incoming chunks into whole lines, buffering any trailing partial.
final class LineBuffer {
    private var partial = ""
    private let lock = NSLock()

    func feed(_ chunk: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let combined = partial + chunk
        let pieces = combined.components(separatedBy: "\n")
        partial = pieces.last ?? ""
        let complete = pieces.dropLast()
        return complete.map { line in
            // Strip trailing \r from CRLF sources.
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !partial.isEmpty else { return [] }
        let out = partial
        partial = ""
        return [out]
    }
}
