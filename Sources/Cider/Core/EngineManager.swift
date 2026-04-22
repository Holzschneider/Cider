import Foundation

struct EngineManager {
    struct CachedEngine {
        let name: String
        let path: URL
    }

    let cacheRoot: URL

    init(cacheRoot: URL = CachePaths.engines) {
        self.cacheRoot = cacheRoot
    }

    func listCached() throws -> [CachedEngine] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cacheRoot.path) else { return [] }
        let entries = try fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
        return entries
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { CachedEngine(name: $0.lastPathComponent, path: $0) }
    }

    // Ensures the engine is extracted into `cacheRoot/<name>/` and returns that path.
    // Downloads from Sikarugir-App/Engines if missing.
    @discardableResult
    func ensure(_ engine: EngineName, forceRefresh: Bool = false) async throws -> URL {
        try CachePaths.ensureExists(cacheRoot)
        let target = cacheRoot.appendingPathComponent(engine.raw, isDirectory: true)
        let marker = target.appendingPathComponent(".cider-extracted")

        if !forceRefresh, FileManager.default.fileExists(atPath: marker.path) {
            Log.debug("engine \(engine.raw) already cached at \(target.path)")
            return target
        }

        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let archive = cacheRoot.appendingPathComponent(engine.archiveFilename)
        try await Download.file(from: engine.releaseDownloadURL, to: archive)

        Log.info("extracting \(engine.archiveFilename)")
        try Shell.run("/usr/bin/tar", ["-xJf", archive.path, "-C", target.path])
        try? FileManager.default.removeItem(at: archive)

        try Data().write(to: marker)
        return target
    }

    // Resolve the wine binary inside an extracted engine. Modern CrossOver
    // engines ship a single unified `wine` (no `wine64`); older builds and
    // Wineskin-style layouts vary. We probe a known set of layouts, then fall
    // back to a recursive search.
    func wineBinaryPath(in engineRoot: URL) throws -> URL {
        let layouts = [
            "wswine.bundle/bin/wine",       // Sikarugir / modern CrossOver (Wineskin S12)
            "wswine.bundle/bin/wine64",
            "wine-home/usr/bin/wine64",
            "wine-home/usr/bin/wine",
            "wine-home/bin/wine64",
            "wine-home/bin/wine",
            "Wineskin.app/Contents/Resources/wine-home/usr/bin/wine64",
            "Wine64.app/Contents/Resources/wine/bin/wine64",
            "bin/wine64",
            "bin/wine"
        ]
        for rel in layouts {
            let candidate = engineRoot.appendingPathComponent(rel)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        if let found = try findExecutable(named: "wine64", in: engineRoot)
            ?? findExecutable(named: "wine", in: engineRoot) {
            return found
        }
        throw Error.wineBinaryNotFound(engineRoot)
    }

    private func findExecutable(named name: String, in root: URL) throws -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name,
               let isExec = try? url.resourceValues(forKeys: [.isExecutableKey]).isExecutable,
               isExec {
                return url
            }
        }
        return nil
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case wineBinaryNotFound(URL)
        var description: String {
            switch self {
            case .wineBinaryNotFound(let root):
                return "Could not locate wine or wine64 binary inside \(root.path). Engine may be corrupted."
            }
        }
    }
}
