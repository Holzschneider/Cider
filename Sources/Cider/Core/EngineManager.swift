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

    // Resolve the wine64 binary path inside an extracted engine.
    // Sikarugir engines typically place wine64 at wine-home/usr/bin/wine64 or
    // Wine64.app/Contents/Resources/wine/bin/wine64. We probe both.
    func wine64Path(in engineRoot: URL) throws -> URL {
        let candidates = [
            "wine-home/usr/bin/wine64",
            "wine-home/bin/wine64",
            "Wineskin.app/Contents/Resources/wine-home/usr/bin/wine64",
            "Wine64.app/Contents/Resources/wine/bin/wine64",
            "bin/wine64"
        ]
        for rel in candidates {
            let candidate = engineRoot.appendingPathComponent(rel)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // Fallback: search for any executable named wine64.
        if let found = try findExecutable(named: "wine64", in: engineRoot) {
            return found
        }
        throw Error.wine64NotFound(engineRoot)
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
        case wine64NotFound(URL)
        var description: String {
            switch self {
            case .wine64NotFound(let root):
                return "Could not locate wine64 binary inside \(root.path). Engine may be corrupted."
            }
        }
    }
}
