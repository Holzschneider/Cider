import Foundation

// Sikarugir engines depend on a set of helper dylibs (libinotify, libsdl,
// libgnutls, …) that ship in the Wrapper Template. The wine binaries' RPATH
// is `@loader_path/../../`, so those dylibs need to sit next to wswine.bundle/.
// TemplateManager fetches the template, extracts its Frameworks, and exposes
// them so BundleBuilder can deposit them alongside the engine.
struct TemplateManager {
    static var defaultVersion: String {
        ProcessInfo.processInfo.environment["CIDER_TEMPLATE_VERSION"] ?? "1.0.11"
    }

    static var releaseTag: String {
        ProcessInfo.processInfo.environment["CIDER_WRAPPER_TAG"] ?? "v1.0"
    }

    let cacheRoot: URL

    init(cacheRoot: URL = CachePaths.root.appendingPathComponent("Templates", isDirectory: true)) {
        self.cacheRoot = cacheRoot
    }

    // Returns the path to the extracted `Template-<version>.app` directory.
    @discardableResult
    func ensure(version: String = TemplateManager.defaultVersion) async throws -> URL {
        try CachePaths.ensureExists(cacheRoot)
        let target = cacheRoot.appendingPathComponent("Template-\(version)", isDirectory: true)
        let marker = target.appendingPathComponent(".cider-extracted")
        if FileManager.default.fileExists(atPath: marker.path) {
            return template(in: target, version: version)
        }

        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let archive = cacheRoot.appendingPathComponent("Template-\(version).tar.xz")
        let url = URL(string: "https://github.com/Sikarugir-App/Wrapper/releases/download/\(Self.releaseTag)/Template-\(version).tar.xz")!
        try await Download.file(from: url, to: archive)

        Log.info("extracting Template-\(version).tar.xz")
        try Shell.run("/usr/bin/tar", ["-xJf", archive.path, "-C", target.path])
        try? FileManager.default.removeItem(at: archive)
        try Data().write(to: marker)

        return template(in: target, version: version)
    }

    // Path to the extracted Frameworks directory (the support dylibs).
    func frameworksDirectory(of templateApp: URL) -> URL {
        templateApp.appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
    }

    enum WineArch: String {
        case x86_64 = "x86_64-windows"
        case i386 = "i386-windows"
    }

    // The template ships per-renderer DLLs at:
    //   Contents/Frameworks/renderer/<kind>/wine/<arch>/
    // Returns nil if the directory does not exist (e.g. D3DMetal is x86_64
    // only — there is no i386-windows folder for it).
    func rendererDirectory(
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
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func template(in dir: URL, version: String) -> URL {
        dir.appendingPathComponent("Template-\(version).app", isDirectory: true)
    }
}
