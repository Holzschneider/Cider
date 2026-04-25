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

// Progress events flowing from the orchestrator / Installer / Preflight
// chain into the modal progress sheet.
//
// `.stage` and `.fraction` are the legacy ad-hoc events — they update
// the sheet's status line and bar without belonging to any specific
// phase, so existing emitters continue to work.
//
// The phase-list events drive a checklist UI: callers declare the
// phases up front via `.phasesDeclared`, then bracket each unit of
// work with `.phaseStarted` / `.phaseProgress` / `.phaseDone` (or
// `.phaseFailed` on error). Phases the caller already knows are done
// — engine cached, template extracted — can be marked
// `alreadyDone: true` in the descriptor so the sheet renders them
// ticked-off without animating.
public enum InstallProgress {
    case stage(String, detail: String)
    case fraction(Double)

    case phasesDeclared([PhaseDescriptor])
    case phaseStarted(id: String)
    case phaseProgress(id: String, fraction: Double, detail: String)
    case phaseDone(id: String)
    case phaseFailed(id: String, message: String)
}

public struct PhaseDescriptor: Equatable, Sendable {
    public let id: String
    public let label: String
    public let kind: Kind
    public let alreadyDone: Bool

    public enum Kind: Sendable { case determinate, indeterminate }

    public init(id: String, label: String, kind: Kind, alreadyDone: Bool = false) {
        self.id = id
        self.label = label
        self.kind = kind
        self.alreadyDone = alreadyDone
    }
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
        // Phase 5: a remote URL source is resolved here (outside the
        // mode-specific paths). The result is always a local zip that
        // the downstream install/bundle code can unzip like any other
        // dropped archive. For link mode this is nonsensical — link
        // requires a local folder — so we pass through and let
        // installLink reject it.
        let (effectiveSource, effectiveBase) = try await resolveURLSourceIfNeeded(
            source: source, baseConfig: baseConfig, mode: mode, progress: progress
        )
        try Task.checkCancellation()
        switch mode {
        case .link:
            return try installLink(source: effectiveSource, baseConfig: effectiveBase)
        case .install:
            return try await installInstall(source: effectiveSource, baseConfig: effectiveBase,
                                            progress: progress)
        case .bundle:
            return try await installBundle(source: effectiveSource, baseConfig: effectiveBase,
                                           bundleURL: bundleURL, progress: progress)
        }
    }

    // MARK: - URL resolution (Phase 5)

    // For non-link modes: turn a `.url(URL)` source into a local zip on
    // disk. Handles both the direct-zip case and the cider.json
    // indirection case. Records originURL + distributionURL on the
    // baseConfig so the persisted cider.json carries the provenance.
    private func resolveURLSourceIfNeeded(
        source: SourceAcquisition,
        baseConfig: CiderConfig,
        mode: InstallMode,
        progress: InstallProgressCallback?
    ) async throws -> (SourceAcquisition, CiderConfig) {
        guard case .url(let url) = source, mode != .link else {
            return (source, baseConfig)
        }
        progress?(.stage("Resolving URL", detail: url.absoluteString))
        let resolved = try await URLSourceResolver.resolve(url: url) { p in
            // Surface Downloader byte-progress as a simple fraction. The
            // Installer's `progress` callback distinguishes stage vs
            // fraction; reporting both keeps the UI honest.
            if p.total > 0 {
                let frac = Double(p.bytes) / Double(p.total)
                progress?(.fraction(min(max(frac, 0), 1)))
            }
        }
        switch resolved {
        case .zip(let local):
            var cfg = baseConfig
            cfg.distributionURL = url.absoluteString
            return (.zip(local), cfg)

        case .ciderJSON(_, let dataURL, let originURL):
            guard let dataURL else {
                throw URLSourceResolver.Error.ciderJSONWithoutDistributionURL(originURL)
            }
            progress?(.stage("Downloading app data", detail: dataURL.absoluteString))
            let nested = try await URLSourceResolver.resolve(url: dataURL) { p in
                if p.total > 0 {
                    let frac = Double(p.bytes) / Double(p.total)
                    progress?(.fraction(min(max(frac, 0), 1)))
                }
            }
            guard case .zip(let local) = nested else {
                // A cider.json's distributionURL that itself returns
                // cider.json is almost certainly a loop; refuse to chase.
                throw URLSourceResolver.Error.undecidableContent(dataURL, contentType: "application/json")
            }
            var cfg = baseConfig
            cfg.originURL = originURL.absoluteString
            cfg.distributionURL = dataURL.absoluteString
            return (.zip(local), cfg)
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
    ) async throws -> InstallResult {
        let displayName = sanitised(baseConfig.displayName)
        guard !displayName.isEmpty else { throw Error.invalidDisplayName }

        let target = AppSupport.programFiles(forBundleNamed: displayName)
        // Install mode keeps the source folder name as the top-level
        // entry under target/ — that's how the existing tests + form
        // pre-fill the exe path ("MyGame/Game.exe").
        try await materialise(source: source, into: target,
                              preserveSourceFolderName: true, progress: progress)

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

    // MARK: - Bundle (folder copy + local zip extract → <bundle>/System/…)

    // Schema-v3 unified layout: the .app bundle holds both the wine
    // prefix and the application data under a single "System" folder.
    // The user's source files land directly in
    //   <bundle>/System/drive_c/Program Files/<programName>/...
    // and the cider.json next to Contents/ records both:
    //   prefixPath:      "System"
    //   applicationPath: "System/drive_c/Program Files/<programName>"
    // so the launcher can find the prefix AND the app data without
    // touching anything outside the bundle.
    //
    // Touches only siblings of Contents/, so the existing codesign /
    // notarization on Contents/ stays valid.
    private func installBundle(
        source: SourceAcquisition,
        baseConfig: CiderConfig,
        bundleURL: URL,
        progress: InstallProgressCallback?
    ) async throws -> InstallResult {
        let programName = sanitised(baseConfig.displayName)
        guard !programName.isEmpty else { throw Error.invalidDisplayName }

        let systemDir = bundleURL.appendingPathComponent("System", isDirectory: true)
        let appDir = systemDir
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent("Program Files", isDirectory: true)
            .appendingPathComponent(programName, isDirectory: true)

        // Drop CONTENTS of the source into Program Files/<programName>/
        // — no source-folder nesting. The user's exe field is relative
        // to that program directory.
        try await materialise(source: source, into: appDir,
                              preserveSourceFolderName: false, progress: progress)

        let configURL = bundleURL.appendingPathComponent("cider.json")
        var config = baseConfig
        config.prefixPath = "System"
        config.applicationPath = "System/drive_c/Program Files/\(programName)"
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
        preserveSourceFolderName: Bool,
        progress: InstallProgressCallback?
    ) async throws {
        try Task.checkCancellation()
        try resetDirectory(target)

        switch source {
        case .folder(let src):
            try ensureExists(src, kind: .folder)
            progress?(.stage("Copying source", detail: src.lastPathComponent))
            // Polled progress driver — the active phase in the sheet
            // shows a real bar instead of an indeterminate spinner.
            // For the source-name-preserving path the destination
            // folder cp creates is target/<src.lastname>/; for the
            // contents-only path it's target/ itself. du polls the
            // post-copy parent so both cases produce a sensible
            // fraction.
            let pollDest: String = preserveSourceFolderName
                ? target.appendingPathComponent(src.lastPathComponent).path
                : target.path
            let copyExe: String   = preserveSourceFolderName ? "/bin/cp" : "/usr/bin/ditto"
            let copyArgs: [String] = preserveSourceFolderName
                ? ["-R", src.path, target.path]
                : [src.path, target.path]
            try await Shell.runCopyWithPolledProgress(
                executable: copyExe,
                arguments: copyArgs,
                sourcePath: src.path,
                destinationPath: pollDest,
                progress: { f in progress?(.fraction(f)) }
            )
        case .zip(let zip):
            try ensureExists(zip, kind: .zip)
            progress?(.stage("Extracting archive", detail: zip.lastPathComponent))
            // Whatever the zip contains (flat or with a single top-level
            // dir) ends up directly under target/. preserveSourceFolderName
            // is intentionally ignored here — there's no folder to
            // preserve, only whatever the archive author chose.
            try await Shell.runAsync("/usr/bin/unzip", ["-q", zip.path, "-d", target.path], captureOutput: true)
        case .url:
            // Unreachable: run() resolves `.url` into a local zip via
            // URLSourceResolver before dispatching here.
            throw Error.urlSourceNotResolved
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
        case linkRequiresFolderSource
        case sourceFolderMissing(URL)
        case sourceZipMissing(URL)
        case urlSourceNotResolved
        case invalidDisplayName

        public var description: String {
            switch self {
            case .linkRequiresFolderSource:
                return "Link mode only works with a local folder source."
            case .sourceFolderMissing(let url):
                return "Source folder doesn't exist: \(url.path)"
            case .sourceZipMissing(let url):
                return "Source zip doesn't exist: \(url.path)"
            case .urlSourceNotResolved:
                return "Internal error: URL source should have been resolved before dispatch."
            case .invalidDisplayName:
                return "Application Name is empty."
            }
        }
    }
}
