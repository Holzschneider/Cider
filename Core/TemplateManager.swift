import Foundation
import CiderModels

// Sikarugir engines depend on a set of helper dylibs (libinotify, libsdl,
// libgnutls, …) that ship in the Wrapper Template. The wine binaries' RPATH
// is `@loader_path/../../`, so those dylibs need to sit next to wswine.bundle/.
// TemplateManager fetches and caches the template under AppSupport/Templates/.
public struct TemplateManager {
    public static var releaseTag: String {
        ProcessInfo.processInfo.environment["CIDER_WRAPPER_TAG"] ?? "v1.0"
    }

    public let cacheRoot: URL

    public init(cacheRoot: URL = AppSupport.templates) {
        self.cacheRoot = cacheRoot
    }

    @discardableResult
    public func ensure(
        _ ref: CiderConfig.TemplateRef = .default,
        progress: Downloader.ProgressHandler? = nil
    ) async throws -> URL {
        try AppSupport.ensureExists(cacheRoot)
        let target = cacheRoot.appendingPathComponent("Template-\(ref.version)", isDirectory: true)
        let marker = target.appendingPathComponent(".cider-extracted")
        if FileManager.default.fileExists(atPath: marker.path) {
            return template(in: target, version: ref.version)
        }

        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let archive = cacheRoot.appendingPathComponent("Template-\(ref.version).tar.xz")
        guard let url = URL(string: ref.url) else {
            throw Error.invalidURL(ref.url)
        }
        _ = try await Downloader.file(
            from: url,
            to: archive,
            expectedSha256: ref.sha256,
            progress: progress
        )

        Log.info("extracting Template-\(ref.version).tar.xz")
        try Shell.run("/usr/bin/tar", ["-xJf", archive.path, "-C", target.path])
        try? FileManager.default.removeItem(at: archive)
        try Data().write(to: marker)

        return template(in: target, version: ref.version)
    }

    public func frameworksDirectory(of templateApp: URL) -> URL {
        templateApp.appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
    }

    public enum WineArch: String {
        case x86_64 = "x86_64-windows"
        case i386 = "i386-windows"
    }

    // The template ships per-renderer DLLs at:
    //   Contents/Frameworks/renderer/<kind>/wine/<arch>/
    // Returns nil when the path doesn't exist OR exists as something
    // other than a directory. The "other than a directory" guard
    // matters for D3DMetal: its template entry for i386-windows may be
    // a placeholder file or a broken symlink (D3DMetal ships x86_64
    // only). Treating that as "no DLLs available" lets installArch's
    // skip-and-warn path kick in instead of crashing on
    // contentsOfDirectory.
    public func rendererDirectory(
        of templateApp: URL,
        kind: GraphicsDriverKind,
        arch: WineArch
    ) -> URL? {
        let url = templateApp
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("renderer", isDirectory: true)
            .appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent("wine", isDirectory: true)
            .appendingPathComponent(arch.rawValue, isDirectory: true)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return (exists && isDir.boolValue) ? url : nil
    }

    private func template(in dir: URL, version: String) -> URL {
        dir.appendingPathComponent("Template-\(version).app", isDirectory: true)
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case invalidURL(String)
        public var description: String {
            switch self {
            case .invalidURL(let s): return "Invalid wrapper-template URL: \(s)"
            }
        }
    }
}
