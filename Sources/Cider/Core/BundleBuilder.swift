import Foundation

struct BundleBuilder {
    let config: BundleConfig

    func build() async throws -> URL {
        let output = config.output
        try prepareOutputDirectory(output)

        let contents = output.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        // 1. Ensure engine is cached, copy into bundle.
        let engineManager = EngineManager()
        let cachedEngine = try await engineManager.ensure(config.engine)
        let engineDest = resources.appendingPathComponent("engine", isDirectory: true)
        Log.info("copying engine \(config.engine.raw) into bundle")
        try copyDirectory(from: cachedEngine, to: engineDest)

        // 1b. Ensure the Sikarugir Wrapper Template is cached and copy its
        // Frameworks alongside wswine.bundle/ so the wine binaries' rpath
        // (@loader_path/../../) resolves libinotify, libsdl, libgnutls, etc.
        let templateManager = TemplateManager()
        let templateApp = try await templateManager.ensure()
        try copyContents(
            of: templateManager.frameworksDirectory(of: templateApp),
            into: engineDest
        )

        let wineBinary = try engineManager.wineBinaryPath(in: engineDest)
        let wineRel = wineBinary.path.replacingOccurrences(
            of: engineDest.path + "/", with: "")

        // 2. Stage Windows payload.
        let staged = try PayloadStaging.stage(input: config.input)
        defer { if staged.isTemporary { try? FileManager.default.removeItem(at: staged.root) } }

        // 3. Initialise Wine prefix and copy payload into drive_c/Program Files.
        let prefix = resources.appendingPathComponent("wineprefix", isDirectory: true)
        let prefixInit = PrefixInitializer(prefix: prefix, wineBinary: wineBinary)
        try prefixInit.initialise(skip: !config.preInitPrefix)
        let winExePath = try prefixInit.stagePayload(
            from: staged.root,
            exeRelativePath: config.exe,
            programName: config.name
        )

        // 4. Install graphics driver DLLs (both arches into system32 + syswow64).
        let graphics = GraphicsDriver(
            kind: config.graphics,
            prefix: prefix,
            templateApp: templateApp,
            templateManager: templateManager
        )
        let graphicsResult = try graphics.install()

        // 5. Icon.
        var iconFileName: String?
        if let iconSrc = config.icon {
            let destIcns = resources.appendingPathComponent("AppIcon.icns")
            Log.info("converting icon \(iconSrc.lastPathComponent)")
            try IconConverter.convert(png: iconSrc, destination: destIcns)
            iconFileName = "AppIcon"
        }

        // 6. Info.plist + PkgInfo.
        try InfoPlistWriter.write(
            .init(
                bundleName: config.name,
                bundleIdentifier: config.bundleId,
                bundleVersion: "1.0",
                iconFileName: iconFileName,
                minimumSystemVersion: "12.0",
                executableName: "Launcher",
                category: "public.app-category.games"
            ),
            to: contents.appendingPathComponent("Info.plist")
        )
        try InfoPlistWriter.writePkgInfo(to: contents.appendingPathComponent("PkgInfo"))

        // 7. Launcher.
        // Working dir for the launcher: the macOS-side equivalent of the
        // Windows directory containing the .exe. e.g. "Program Files/Test"
        // when --exe is "foo.exe" at the root, "Program Files/Test/RagnarokPlus"
        // when --exe is "RagnarokPlus/ragnarok-plus-patcher.exe".
        let exeRelDir = (config.exe as NSString).deletingLastPathComponent
        let exeWorkingDir = exeRelDir.isEmpty
            ? "Program Files/\(config.name)"
            : "Program Files/\(config.name)/\(exeRelDir)"

        // Console / TUI apps: emit a run.bat next to the exe with stdout
        // redirected to all.txt, then have the launcher invoke
        // `cmd.exe /c run.bat`. Without a real Windows console allocated by
        // cmd.exe, console-subsystem (and some hybrid GUI/console) apps die
        // in CRT init when they try to write to stdout.
        let launchVariant: LauncherScript.LaunchVariant
        if config.console {
            let exeDirOnHost = prefix
                .appendingPathComponent("drive_c")
                .appendingPathComponent(exeWorkingDir)
            try writeRunBat(
                at: exeDirOnHost.appendingPathComponent("run.bat"),
                winExePath: winExePath,
                args: config.args,
                inheritConsole: config.inheritConsole
            )
            let batWinPath = "C:\\\(exeWorkingDir.replacingOccurrences(of: "/", with: "\\"))\\run.bat"
            launchVariant = .viaCmd(batWindowsPath: batWinPath)
        } else {
            launchVariant = .direct
        }

        try LauncherScript.render(
            .init(
                bundleId: config.bundleId,
                wineBinaryRelativePath: wineRel,
                winExePath: winExePath,
                exeWorkingDirRelativeToDriveC: exeWorkingDir,
                exeArgs: config.args,
                launch: launchVariant,
                dllOverrides: graphicsResult.dllOverrides,
                extraEnv: graphicsResult.extraEnv
            ),
            to: macOS.appendingPathComponent("Launcher")
        )

        // 8. Metadata file for `cider inspect`.
        let metadata = BundleConfig.BundleMetadata(
            engine: config.engine.raw,
            graphics: config.graphics,
            winExePath: winExePath,
            exeArgs: config.args,
            createdAt: Date(),
            ciderVersion: ciderVersion
        )
        let metaData = try JSONEncoder.cider.encode(metadata)
        try metaData.write(to: resources.appendingPathComponent("cider.json"))

        // 9. Sign.
        try CodeSigner.sign(bundle: output, identity: config.signIdentity)
        try CodeSigner.verify(bundle: output)

        Log.info("built \(output.path)")
        return output
    }

    private func prepareOutputDirectory(_ output: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) {
            Log.warn("output \(output.lastPathComponent) exists — replacing.")
            try fm.removeItem(at: output)
        }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
    }

    private func copyDirectory(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        // Use `cp -a` to preserve symlinks and permissions, which matters for
        // Wine engine payloads (they symlink wine64 → wine, etc.).
        try Shell.run("/bin/cp", ["-a", source.path, destination.path], captureOutput: true)
    }

    // Bat that cmd.exe /c will run.
    //   - stdin from NUL so console-style "press any key" stdin reads return
    //     EOF immediately. (Console-API reads bypass this; that is on the app.)
    //   - stdout/stderr to all.txt so console-subsystem apps have a real
    //     writable handle (the original reason we wrap in cmd at all).
    //   - When inheritConsole is true, prefix with `start "" /B /WAIT`. This
    //     mirrors Sikarugir and makes the exe inherit cmd's text-mode console
    //     instead of allocating its own graphical conhost. Suppresses the
    //     "Wine console" pop-up window but propagates CREATE_NO_WINDOW to the
    //     exe's children — apps that spawn separate child windows (e.g. a
    //     patcher launching a game) may break. Off by default.
    private func writeRunBat(
        at url: URL,
        winExePath: String,
        args: [String],
        inheritConsole: Bool
    ) throws {
        let argLine = args.map { #""\#($0)""# }.joined(separator: " ")
        let prefix = inheritConsole ? #"start "" /B /WAIT "# : ""
        let bat = """
        @echo off
        \(prefix)\"\(winExePath)\" \(argLine) < NUL > all.txt 2>&1

        """
        // Bat files use CRLF and CP-1252-ish encoding by convention.
        let crlf = bat.replacingOccurrences(of: "\n", with: "\r\n")
        try Data(crlf.utf8).write(to: url)
    }

    private func copyContents(of source: URL, into destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for entry in entries {
            let dest = destination.appendingPathComponent(entry.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try Shell.run("/bin/cp", ["-a", entry.path, dest.path], captureOutput: true)
        }
    }
}
