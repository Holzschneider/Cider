import Foundation
import CiderModels

// Splash image lifecycle: takes whatever the user typed in the Configure
// form, materialises a per-install-mode copy if needed, and returns the
// path string the orchestrator should write into cider.json's
// `splash.file` field.
//
// Mode rules:
//   * Link mode: the source folder is the application directory and
//     stays put on disk forever. Leave the splash where it is. Store
//     a relative path when the file lives inside the source folder,
//     absolute otherwise.
//   * Install mode: data ends up under
//     ~/Library/Application Support/Cider/Program Files/<name>/.
//     If the splash already lives inside the source folder, store a
//     relative path (it'll travel with the data). If it's an absolute
//     path elsewhere, copy it into AppSupport/Assets/<name>/ under
//     a sanitised name (splash-screen.{ext}) so the configured bundle
//     keeps working after the user moves the original file.
//   * Bundle mode: data lives inside the .app bundle. If the splash
//     is inside the source, store a relative path (gets bundled with
//     the data). Absolute paths get copied next to the cider.json
//     (sibling of Contents/) under splash-screen.{ext} so the bundle
//     stays self-contained.
//
// Sanitised filename: schema-v3 forces splash-screen.{png|jpg|jpeg}
// regardless of what the user picked, defending against creative
// filenames like "..\..\..\Library\Preferences\...".
public enum SplashAssetStager {

    public enum Error: Swift.Error, CustomStringConvertible {
        case sourceMissing(URL)
        case unsupportedExtension(String)
        public var description: String {
            switch self {
            case .sourceMissing(let url):
                return "Splash image not found: \(url.path)"
            case .unsupportedExtension(let ext):
                return "Splash image must be .png / .jpg / .jpeg (got .\(ext))."
            }
        }
    }

    // Resolves what's currently in the form (`splashFile` raw string)
    // against `sourceFolder` (the dropped folder, used to test
    // "is this inside the source"). Returns nil when the form field
    // is empty — the orchestrator then writes config.splash = nil.
    public static func stage(
        rawSplashPath: String,
        mode: InstallMode,
        sourceFolder: URL?,
        bundleName: String,
        bundleURL: URL
    ) throws -> String? {
        let trimmed = rawSplashPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Resolve the user-typed path to an absolute URL. Tilde is
        // expanded; relative paths resolve against sourceFolder.
        let resolved = absoluteURL(trimmed: trimmed, relativeTo: sourceFolder)
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw Error.sourceMissing(resolved)
        }

        // If the splash already sits inside the source folder, every
        // mode just records a relative path. Install / Bundle bundle
        // the source's contents into the application directory; Link
        // points at the source. All three resolve splash relative to
        // the application directory at launch.
        if let sourceFolder, isInside(resolved, of: sourceFolder) {
            let rel = relativePath(of: resolved, under: sourceFolder)
            return rel
        }

        // Outside the source folder. Per-mode handling:
        switch mode {
        case .link:
            // Nothing to copy — the splash will be loaded from where
            // it is on each launch.
            return resolved.path

        case .install:
            // Copy into AppSupport/Assets/<bundleName>/ under a
            // sanitised name. Store an absolute path in cider.json so
            // the launcher (which reads cider.json from
            // Configs/<bundleName>.json) finds it deterministically.
            let target = AppSupport.assets(forBundleNamed: bundleName)
            return try copy(source: resolved, intoDir: target)

        case .bundle:
            // Copy next to cider.json (sibling of Contents/). Store a
            // relative path so the bundle stays self-contained — the
            // launcher resolves splash relative to the application
            // directory, but for in-bundle copies we record the path
            // relative to the cider.json's own directory.
            let copied = try copy(source: resolved, intoDir: bundleURL)
            return URL(fileURLWithPath: copied).lastPathComponent
        }
    }

    // MARK: - Helpers

    private static func absoluteURL(trimmed: String, relativeTo: URL?) -> URL {
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        if let relativeTo {
            return relativeTo.appendingPathComponent(expanded)
                .standardizedFileURL
        }
        return URL(fileURLWithPath: expanded)
    }

    private static func isInside(_ candidate: URL, of folder: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path + "/"
        return candidatePath.hasPrefix(folderPath)
    }

    private static func relativePath(of file: URL, under folder: URL) -> String {
        let folderPath = folder.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        if filePath.hasPrefix(folderPath + "/") {
            return String(filePath.dropFirst(folderPath.count + 1))
        }
        return filePath
    }

    // Copies `source` into `dir`/splash-screen.<ext>, where <ext> is
    // canonicalised to png / jpg / jpeg. Returns the absolute path of
    // the destination. Idempotent (overwrites any prior splash-screen
    // file from a previous Configure round).
    private static func copy(source: URL, intoDir dir: URL) throws -> String {
        let ext = source.pathExtension.lowercased()
        let safeExt: String
        switch ext {
        case "png":         safeExt = "png"
        case "jpg", "jpeg": safeExt = "jpg"
        default:            throw Error.unsupportedExtension(ext)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("splash-screen.\(safeExt)")
        // Wipe any previous splash files (any extension) from a prior
        // round so we don't leave orphans behind.
        for prevExt in ["png", "jpg", "jpeg"] {
            let prev = dir.appendingPathComponent("splash-screen.\(prevExt)")
            try? FileManager.default.removeItem(at: prev)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest.path
    }
}
