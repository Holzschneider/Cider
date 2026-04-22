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
        let wine64 = try engineManager.wine64Path(in: engineDest)

        // 2. Stage Windows payload.
        let staged = try PayloadStaging.stage(input: config.input)
        defer { if staged.isTemporary { try? FileManager.default.removeItem(at: staged.root) } }

        // 3. Initialise Wine prefix and copy payload into drive_c/Program Files.
        let prefix = resources.appendingPathComponent("wineprefix", isDirectory: true)
        let prefixInit = PrefixInitializer(prefix: prefix, wine64: wine64)
        try prefixInit.initialise(skip: !config.preInitPrefix)
        let winExePath = try prefixInit.stagePayload(
            from: staged.root,
            exeRelativePath: config.exe,
            programName: config.name
        )

        // 4. Install graphics driver DLLs.
        let graphics = GraphicsDriver(
            kind: config.graphics,
            prefix: prefix,
            engineRoot: engineDest
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
        try LauncherScript.render(
            .init(
                bundleId: config.bundleId,
                winExePath: winExePath,
                exeArgs: config.args,
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
}
