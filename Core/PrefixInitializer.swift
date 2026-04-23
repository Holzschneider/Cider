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

    public enum StagingMode {
        // Default. Each entry under `source/` becomes a symlink under
        // drive_c/Program Files/<programName>/. Honours the spec's
        // "never copy by default" rule and is instant.
        case symlinks
        // Copy each entry. Slower, more disk, but the bundle keeps
        // working if the user moves/deletes the source folder.
        case copy
    }

    // Stages the Windows payload as siblings under
    // drive_c/Program Files/<programName>/, either via symlinks (default)
    // or recursive copy. Returns the Windows-style absolute path to the
    // exe inside the prefix (e.g. "C:\\Program Files\\MyGame\\Game.exe").
    @discardableResult
    public func stagePayload(
        from source: URL,
        exeRelativePath: String,
        programName: String,
        mode: StagingMode = .symlinks
    ) throws -> String {
        let targetDir = prefix
            .appendingPathComponent("drive_c")
            .appendingPathComponent("Program Files")
            .appendingPathComponent(programName)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        try refreshContents(of: source, into: targetDir, mode: mode)

        let exeWithinTarget = targetDir.appendingPathComponent(exeRelativePath)
        let resolved = (try? exeWithinTarget.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        // Symlinks resolve under fileExists, but isRegularFile follows the
        // link to confirm the underlying file is real.
        guard FileManager.default.fileExists(atPath: exeWithinTarget.path) || resolved else {
            throw Error.exeNotFound(exeRelativePath, targetDir)
        }

        let winPath = "C:\\Program Files\\\(programName)\\"
            + exeRelativePath.replacingOccurrences(of: "/", with: "\\")
        return winPath
    }

    private func refreshContents(of source: URL, into target: URL, mode: StagingMode) throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for entry in entries {
            let dest = target.appendingPathComponent(entry.lastPathComponent)
            if fm.fileExists(atPath: dest.path) || (try? fm.attributesOfItem(atPath: dest.path)) != nil {
                // Remove pre-existing entries (including stale symlinks).
                try fm.removeItem(at: dest)
            }
            switch mode {
            case .symlinks:
                try fm.createSymbolicLink(at: dest, withDestinationURL: entry)
            case .copy:
                try fm.copyItem(at: entry, to: dest)
            }
        }
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
