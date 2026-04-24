import Foundation
import CiderModels

// Three strategies for materialising a SourceAcquisition into the
// applicationPath that Cider's launcher will resolve at runtime.
public enum InstallMode: String, Codable, CaseIterable {
    // Copy/extract into ~/Library/Application Support/Cider/Program Files/
    // <displayName>/. cider.json sits in AppSupport/Configs/<name>.json
    // with an absolute applicationPath pointing at the copied data.
    case install
    // Copy/extract into <bundle>/Application/. cider.json sits at
    // <bundle>/cider.json (sibling of Contents/) with relative
    // applicationPath = "Application/<source-name>". Bundle stays
    // self-contained and portable.
    case bundle
    // No copy / no extract. cider.json sits in AppSupport/Configs/
    // <name>.json with absolute applicationPath = the original folder
    // on disk. Only valid for SourceAcquisition.folder.
    case link
}

// Result of an Installer.run call: where the cider.json ended up + the
// computed applicationPath that was stored in it. Caller can use this
// to relaunch the bundle, set the icon, etc.
public struct InstallResult {
    public let configFileURL: URL
    public let applicationPath: String
    public let mode: InstallMode

    public init(configFileURL: URL, applicationPath: String, mode: InstallMode) {
        self.configFileURL = configFileURL
        self.applicationPath = applicationPath
        self.mode = mode
    }
}

// Coarse-grained progress signal — Phase 7 hooks this into the modal
// progress sheet (download / extract / copy each appearing as a stage).
public enum InstallProgress {
    case stage(String, detail: String)
    case fraction(Double)
}

public typealias InstallProgressCallback = @Sendable (InstallProgress) -> Void

// Materialises a SourceAcquisition + a base CiderConfig (without
// applicationPath) into the on-disk layout dictated by the chosen
// InstallMode. The base config supplies displayName, exe, engine,
// graphics, etc.; the Installer fills in applicationPath and writes
// the cider.json to the right location.
public struct Installer {
    public init() {}

    public func run(
        source: SourceAcquisition,
        mode: InstallMode,
        baseConfig: CiderConfig,
        bundleURL: URL,
        progress: InstallProgressCallback? = nil
    ) async throws -> InstallResult {
        switch mode {
        case .link:
            return try installLink(source: source, baseConfig: baseConfig)
        case .install:
            return try installInstall(source: source, baseConfig: baseConfig, progress: progress)
        case .bundle:
            return try installBundle(source: source, baseConfig: baseConfig,
                                     bundleURL: bundleURL, progress: progress)
        }
    }

    // MARK: - Link

    private func installLink(
        source: SourceAcquisition,
        baseConfig: CiderConfig
    ) throws -> InstallResult {
        // Link only makes sense for a local folder — there's nothing to
        // link to for zips or remote URLs.
        guard case .folder(let folder) = source else {
            throw Error.linkRequiresFolderSource
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw Error.sourceFolderMissing(folder)
        }

        let displayName = sanitised(baseConfig.displayName)
        guard !displayName.isEmpty else { throw Error.invalidDisplayName }

        // Per the AppSupport-layout decision (Configs/<name>.json + data
        // only in Program Files/<name>/), the cider.json sits in
        // Configs/<name>.json regardless of mode. Link's applicationPath
        // is the original absolute folder.
        let configURL = AppSupport.config(forBundleNamed: displayName)
        var config = baseConfig
        config.applicationPath = folder.standardizedFileURL.path

        try config.write(to: configURL)

        // Even though Link doesn't write any data, create an empty
        // marker directory under Program Files/ so the user can find
        // their configured app at the conventional location and so
        // the rename + cleanup in Phase 10 has something to move.
        let marker = AppSupport.programFiles(forBundleNamed: displayName)
        try? fm.createDirectory(at: marker, withIntermediateDirectories: true)

        return InstallResult(
            configFileURL: configURL,
            applicationPath: config.applicationPath,
            mode: .link
        )
    }

    // MARK: - Install (folder copy + local zip extract → AppSupport)

    private func installInstall(
        source: SourceAcquisition,
        baseConfig: CiderConfig,
        progress: InstallProgressCallback?
    ) throws -> InstallResult {
        let displayName = sanitised(baseConfig.displayName)
        guard !displayName.isEmpty else { throw Error.invalidDisplayName }

        let target = AppSupport.programFiles(forBundleNamed: displayName)
        try materialise(source: source, into: target, progress: progress)

        // cider.json sits in Configs/<name>.json with applicationPath = the
        // absolute path to the materialised data. The exe path stays
        // relative to applicationPath, exactly as the user typed it in
        // the More dialog.
        let configURL = AppSupport.config(forBundleNamed: displayName)
        var config = baseConfig
        config.applicationPath = target.standardizedFileURL.path
        try config.write(to: configURL)

        progress?(.stage("Done", detail: ""))
        return InstallResult(
            configFileURL: configURL,
            applicationPath: config.applicationPath,
            mode: .install
        )
    }

    // MARK: - Bundle (folder copy + local zip extract → <bundle>/Application/)

    // Same materialisation rules as Install, but the data lands inside
    // the .app bundle (sibling of Contents/) and the cider.json sits at
    // <bundle>/cider.json with a relative applicationPath = "Application".
    // Result: bundle stays self-contained, can be moved between disks /
    // Macs without breaking the path.
    //
    // Touches only siblings of Contents/, so the existing codesign /
    // notarization on Contents/ stays valid (per the same rule
    // BundleTransmogrifier already relies on for the Finder custom icon
    // and the in-bundle cider.json).
    private func installBundle(
        source: SourceAcquisition,
        baseConfig: CiderConfig,
        bundleURL: URL,
        progress: InstallProgressCallback?
    ) throws -> InstallResult {
        let displayName = sanitised(baseConfig.displayName)
        guard !displayName.isEmpty else { throw Error.invalidDisplayName }

        let applicationDir = bundleURL.appendingPathComponent("Application", isDirectory: true)
        try materialise(source: source, into: applicationDir, progress: progress)

        let configURL = bundleURL.appendingPathComponent("cider.json")
        var config = baseConfig
        config.applicationPath = "Application"
        try config.write(to: configURL)

        progress?(.stage("Done", detail: ""))
        return InstallResult(
            configFileURL: configURL,
            applicationPath: config.applicationPath,
            mode: .bundle
        )
    }

    // MARK: - Materialisation (shared by Install + Bundle)

    private func materialise(
        source: SourceAcquisition,
        into target: URL,
        progress: InstallProgressCallback?
    ) throws {
        try resetDirectory(target)

        switch source {
        case .folder(let src):
            try ensureExists(src, kind: .folder)
            progress?(.stage("Copying source", detail: src.lastPathComponent))
            // cp -R preserves the source's name as the top-level entry
            // under target/, so the user-spec rule holds:
            //   /tmp/MyGame copied into target/  →  target/MyGame/
            try Shell.run("/bin/cp", ["-R", src.path, target.path], captureOutput: true)
        case .zip(let zip):
            try ensureExists(zip, kind: .zip)
            progress?(.stage("Extracting archive", detail: zip.lastPathComponent))
            // Whatever the zip contains (flat or with a single top-level
            // dir) ends up directly under target/.
            try Shell.run("/usr/bin/unzip", ["-q", zip.path, "-d", target.path], captureOutput: true)
        case .url:
            // Phase 5 hooks the download path in here (downloads to
            // AppSupport/Cache, then routes through the .zip path above).
            throw Error.urlSourceRequiresPhase5
        }
    }

    // MARK: - Common helpers

    private enum FilesystemKind { case folder, zip }

    private func ensureExists(_ url: URL, kind: FilesystemKind) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            switch kind {
            case .folder: throw Error.sourceFolderMissing(url)
            case .zip:    throw Error.sourceZipMissing(url)
            }
        }
        switch kind {
        case .folder where !isDir.boolValue:
            throw Error.sourceFolderMissing(url)
        case .zip where isDir.boolValue:
            throw Error.sourceZipMissing(url)
        default: break
        }
    }

    // Wipe + recreate target dir so re-install doesn't merge with stale data.
    private func resetDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Helpers

    // Filesystem-safe display name. Mirrors the rule used by
    // BundleTransmogrifier.sanitiseBundleName so cider.json paths and
    // .app filenames stay in sync.
    private func sanitised(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\"?*<>|")
        var s = raw.unicodeScalars
            .map { invalid.contains($0) ? Character(" ") : Character($0) }
            .reduce(into: "") { $0.append($1) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(120))
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case notYetImplemented(InstallMode)
        case linkRequiresFolderSource
        case sourceFolderMissing(URL)
        case sourceZipMissing(URL)
        case urlSourceRequiresPhase5
        case invalidDisplayName

        public var description: String {
            switch self {
            case .notYetImplemented(let m):
                return "Installer.\(m.rawValue) is not yet implemented."
            case .linkRequiresFolderSource:
                return "Link mode only works with a local folder source."
            case .sourceFolderMissing(let url):
                return "Source folder doesn't exist: \(url.path)"
            case .sourceZipMissing(let url):
                return "Source zip doesn't exist: \(url.path)"
            case .urlSourceRequiresPhase5:
                return "URL sources are not yet supported (Phase 5)."
            case .invalidDisplayName:
                return "Display name is empty."
            }
        }
    }
}
