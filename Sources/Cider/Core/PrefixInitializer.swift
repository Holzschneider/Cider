import Foundation

struct PrefixInitializer {
    let prefix: URL
    let wine64: URL

    // Runs wineboot -u to populate `prefix` with a minimal Windows environment.
    // Safe to skip if `skip` is true — the bottle will then be initialised on
    // first launch instead.
    func initialise(skip: Bool = false) throws {
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        guard !skip else {
            Log.info("skipping prefix pre-initialisation (--no-prefix-init)")
            return
        }
        Log.info("initialising Wine prefix (first run may take ~30s)")
        try Shell.run(wine64.path, ["wineboot", "-u"], environment: [
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": "-all"
        ], captureOutput: true)
    }

    // Copies the Windows payload into drive_c/Program Files/<name>/. Returns the
    // absolute Windows-style path to the .exe inside the bottle.
    func stagePayload(from source: URL, exeRelativePath: String, programName: String) throws -> String {
        let targetDir = prefix
            .appendingPathComponent("drive_c")
            .appendingPathComponent("Program Files")
            .appendingPathComponent(programName)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        try copyContents(of: source, into: targetDir)

        let exeWithinTarget = targetDir.appendingPathComponent(exeRelativePath)
        guard FileManager.default.fileExists(atPath: exeWithinTarget.path) else {
            throw Error.exeNotFound(exeRelativePath, targetDir)
        }

        let winPath = "C:\\Program Files\\\(programName)\\"
            + exeRelativePath.replacingOccurrences(of: "/", with: "\\")
        return winPath
    }

    private func copyContents(of source: URL, into target: URL) throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for entry in entries {
            let dest = target.appendingPathComponent(entry.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: entry, to: dest)
        }
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case exeNotFound(String, URL)
        var description: String {
            switch self {
            case let .exeNotFound(rel, base):
                return "Executable '\(rel)' not found inside staged payload at \(base.path)."
            }
        }
    }
}
