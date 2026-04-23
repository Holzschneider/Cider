import Foundation
import CiderModels

public struct EngineManager {
    public struct CachedEngine {
        public let name: String
        public let path: URL
    }

    public let cacheRoot: URL

    public init(cacheRoot: URL = AppSupport.engines) {
        self.cacheRoot = cacheRoot
    }

    public func listCached() throws -> [CachedEngine] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cacheRoot.path) else { return [] }
        let entries = try fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { CachedEngine(name: $0.lastPathComponent, path: $0) }
    }

    // Ensures `ref` is extracted into `cacheRoot/<name>/`. Downloads from the
    // ref's URL if missing. Verifies sha256 if supplied. Reports download
    // progress via the handler.
    @discardableResult
    public func ensure(
        _ ref: CiderConfig.EngineRef,
        forceRefresh: Bool = false,
        progress: Downloader.ProgressHandler? = nil
    ) async throws -> URL {
        try AppSupport.ensureExists(cacheRoot)
        let target = cacheRoot.appendingPathComponent(ref.name, isDirectory: true)
        let marker = target.appendingPathComponent(".cider-extracted")

        if !forceRefresh, FileManager.default.fileExists(atPath: marker.path) {
            Log.debug("engine \(ref.name) already cached at \(target.path)")
            return target
        }

        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let archive = cacheRoot.appendingPathComponent("\(ref.name).tar.xz")
        guard let url = URL(string: ref.url) else {
            throw Error.invalidURL(ref.url)
        }
        _ = try await Downloader.file(
            from: url,
            to: archive,
            expectedSha256: ref.sha256,
            progress: progress
        )

        Log.info("extracting \(ref.name).tar.xz")
        try Shell.run("/usr/bin/tar", ["-xJf", archive.path, "-C", target.path])
        try? FileManager.default.removeItem(at: archive)

        try Data().write(to: marker)
        return target
    }

    // Resolve the wine binary inside an extracted engine. Modern CrossOver
    // engines ship a single unified `wine` (no `wine64`); older builds and
    // Wineskin-style layouts vary. Probe a known set of layouts, then fall
    // back to a recursive search.
    public func wineBinaryPath(in engineRoot: URL) throws -> URL {
        let layouts = [
            "wswine.bundle/bin/wine",
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

    public enum Error: Swift.Error, CustomStringConvertible {
        case wineBinaryNotFound(URL)
        case invalidURL(String)
        public var description: String {
            switch self {
            case .wineBinaryNotFound(let root):
                return "Could not locate wine or wine64 binary inside \(root.path). Engine may be corrupted."
            case .invalidURL(let s):
                return "Invalid engine URL: \(s)"
            }
        }
    }
}
