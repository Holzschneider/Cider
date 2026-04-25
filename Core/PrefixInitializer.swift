import Foundation

public struct PrefixInitializer {
    public let prefix: URL
    public let wineBinary: URL

    public init(prefix: URL, wineBinary: URL) {
        self.prefix = prefix
        self.wineBinary = wineBinary
    }

    // wineboot -u to populate `prefix` with a minimal Windows environment.
    // Safe to skip — the bottle would then be initialised on first launch.
    public func initialise(skip: Bool = false) throws {
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        guard !skip else {
            Log.info("skipping prefix pre-initialisation")
            return
        }
        Log.info("initialising Wine prefix (first run may take ~30s)")
        try Shell.run(wineBinary.path, ["wineboot", "-u"], environment: [
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": "-all"
        ], captureOutput: true)
        try disableAeDebug()
    }

    // Disable Wine's auto-debugger so an unhandled exception in the launched
    // app does not spawn a runaway swarm of winedbg.exe processes.
    private func disableAeDebug() throws {
        Log.debug("disabling AeDebug auto-attach in the bundled prefix")
        try Shell.run(wineBinary.path, [
            "reg", "add",
            #"HKCU\Software\Wine\AeDebug"#,
            "/v", "Auto", "/t", "REG_SZ", "/d", "0", "/f"
        ], environment: [
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": "-all"
        ], captureOutput: true)
    }

    // Stages the Windows payload as a single symbolic link
    //   <prefix>/drive_c/Program Files/<programName>  →  source
    // and returns the Windows-style absolute path to the exe inside it
    // (e.g. "C:\\Program Files\\MyGame\\Game.exe").
    //
    // Idempotent — if a symlink at the target already points at the
    // same source, do nothing; if it points elsewhere or is a stale
    // directory from the old per-entry layout, replace it. Sharing a
    // prefix across multiple bundles works naturally: each bundle
    // owns its own Program Files/<bundleName> entry, but they all
    // share the parent prefix's drive_c/windows, registry, etc.
    @discardableResult
    public func stagePayload(
        from source: URL,
        exeRelativePath: String,
        programName: String
    ) throws -> String {
        let programFilesDir = prefix
            .appendingPathComponent("drive_c")
            .appendingPathComponent("Program Files")
        try FileManager.default.createDirectory(
            at: programFilesDir, withIntermediateDirectories: true)

        let target = programFilesDir.appendingPathComponent(programName)
        try linkOrRebind(target: target, to: source)

        // Check the exe lives at the expected spot inside the staged
        // payload. fileExists follows the symlink we just created;
        // isRegularFile is a backup check for cases where fileExists
        // returns true but the entry is a broken link.
        let exeWithinTarget = target.appendingPathComponent(exeRelativePath)
        let isRegular = (try? exeWithinTarget.resourceValues(forKeys: [.isRegularFileKey])
                                .isRegularFile) ?? false
        guard FileManager.default.fileExists(atPath: exeWithinTarget.path) || isRegular else {
            throw Error.exeNotFound(exeRelativePath, target)
        }

        let winPath = "C:\\Program Files\\\(programName)\\"
            + exeRelativePath.replacingOccurrences(of: "/", with: "\\")
        return winPath
    }

    // Make `target` be a symlink pointing at `source`. If it already is,
    // skip; if it's a different symlink or a real directory left behind
    // by the old per-entry layout, remove and recreate.
    private func linkOrRebind(target: URL, to source: URL) throws {
        let fm = FileManager.default
        let sourcePath = source.standardizedFileURL.path

        // Use lstat (not stat) so we can tell symlinks from real entries.
        // FileManager.attributesOfItem follows symlinks; this combo of
        // destinationOfSymbolicLink + fileExists is the supported way.
        let existingLinkTarget = try? fm.destinationOfSymbolicLink(atPath: target.path)
        if let existingLinkTarget {
            // Resolve the link's destination (it may be relative — though
            // we always write absolute) and compare to the requested
            // source. If they match, no-op.
            let resolved = existingLinkTarget.hasPrefix("/")
                ? existingLinkTarget
                : (target.deletingLastPathComponent()
                        .appendingPathComponent(existingLinkTarget)
                        .standardizedFileURL.path)
            if resolved == sourcePath { return }
            try fm.removeItem(at: target)
        } else if fm.fileExists(atPath: target.path) {
            // Real directory or file at the target — likely the old
            // per-entry layout. Remove it.
            try fm.removeItem(at: target)
        }

        try fm.createSymbolicLink(at: target, withDestinationURL: source)
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case exeNotFound(String, URL)
        public var description: String {
            switch self {
            case let .exeNotFound(rel, base):
                return "Executable '\(rel)' not found inside staged payload at \(base.path)."
            }
        }
    }
}
