import Foundation
import Combine
import CiderModels
import CiderCore

// Schema-v2 form state for MoreDialog.
//
// The form exposes two paths that look similar but serve different roles:
//
//   * `sourcePath` — where the installer should pull data from. Folder,
//     zip, or http(s):// URL. Only meaningful at Apply time. Phase 8 hands
//     it to Installer.run() as a SourceAcquisition.
//
//   * `applicationPath` — what ends up inside the persisted cider.json.
//     For Link mode this IS the source (we point at it in place). For
//     Install/Bundle the Installer computes the final value (target dir
//     under AppSupport or bundle's Application/); the form leaves it
//     alone so edit-save round-trips don't destroy it.
//
// Install mode picker wiring: Install → copy into AppSupport,
// Bundle → copy into <bundle>/Application/, Link → run the folder in
// place. The picker defaults from the dropped source kind (folder→Link,
// zip/URL→Install) but the user is free to pick any mode.
@MainActor
final class MoreDialogViewModel: ObservableObject {
    // Basic
    @Published var displayName: String = ""
    @Published var exe: String = ""
    @Published var argsText: String = ""

    // Install plan
    @Published var installMode: InstallMode = .install
    @Published var sourcePath: String = ""

    // Persisted config path. Hidden from the form UI in Phase 6 — only
    // touched when loading an existing config or when Link mode needs
    // its value mirrored from sourcePath.
    @Published var applicationPath: String = ""
    @Published var originURL: String = ""

    // Engine
    @Published var engineName: String = ""
    @Published var engineURL: String = ""
    @Published var engineSha256: String = ""

    // Engine catalogue (per-row state for the "Wine engine" section).
    @Published var useCustomRepository: Bool = false
    @Published var customRepositoryURL: String = ""
    @Published var availableEngines: [EngineCatalog.Entry] = []
    @Published var isFetchingEngines: Bool = false
    @Published var catalogError: String? = nil
    private var lastFetchedRepositoryURL: String? = nil

    var effectiveRepositoryURL: String {
        useCustomRepository
            ? customRepositoryURL
            : EngineCatalog.defaultRepositoryPageURL
    }

    func refreshEngineCatalog(initial: Bool = false) {
        let url = effectiveRepositoryURL
        guard !url.isEmpty else {
            availableEngines = []
            catalogError = nil
            return
        }
        if isFetchingEngines, lastFetchedRepositoryURL == url { return }
        lastFetchedRepositoryURL = url
        isFetchingEngines = true
        catalogError = nil
        Task { @MainActor [weak self] in
            do {
                let entries = try await EngineCatalog.fetch(repositoryPageURL: url)
                guard let self else { return }
                self.availableEngines = entries
                if initial || self.engineName.isEmpty
                   || !entries.contains(where: { $0.name == self.engineName }) {
                    if let pick = EngineCatalog.suggestedDefault(from: entries) {
                        self.engineName = pick.name
                        self.engineURL = pick.downloadURL
                    }
                }
                self.isFetchingEngines = false
            } catch {
                guard let self else { return }
                self.availableEngines = []
                self.catalogError = String(describing: error)
                self.isFetchingEngines = false
            }
        }
    }

    // Wrapper template (rarely edited — Cider's baked-in default is fine)
    @Published var templateVersion: String = CiderConfig.TemplateRef.default.version
    @Published var templateURL: String = CiderConfig.TemplateRef.default.url
    @Published var templateSha256: String = ""

    // Graphics
    @Published var graphics: GraphicsDriverKind = .defaultForThisMachine

    // Wine options
    @Published var wineEsync: Bool = true
    @Published var wineMsync: Bool = true
    @Published var wineUseWinedbg: Bool = false
    @Published var wineConsole: Bool = false
    @Published var wineInheritConsole: Bool = false
    @Published var winetricksText: String = ""

    // Presentation
    @Published var splashFile: String = ""
    @Published var splashTransparent: Bool = true
    @Published var iconFile: String = ""

    // MARK: - Round-trip

    func load(from config: CiderConfig) {
        displayName = config.displayName
        applicationPath = config.applicationPath
        // Heuristic: deduce install mode from the persisted applicationPath.
        // This is best-effort — the user can override via the picker.
        installMode = Self.inferMode(from: config.applicationPath)
        // For Link mode, the source IS the applicationPath (the folder
        // we're pointing at). For Install/Bundle the source isn't recorded
        // in cider.json (the data is already in place); leave sourcePath
        // empty until the user drops a new source.
        sourcePath = installMode == .link ? config.applicationPath : ""
        exe = config.exe
        argsText = config.args.joined(separator: " ")

        engineName = config.engine.name
        engineURL = config.engine.url
        engineSha256 = config.engine.sha256 ?? ""

        templateVersion = config.wrapperTemplate.version
        templateURL = config.wrapperTemplate.url
        templateSha256 = config.wrapperTemplate.sha256 ?? ""

        graphics = config.graphics

        wineEsync = config.wine.esync
        wineMsync = config.wine.msync
        wineUseWinedbg = config.wine.useWinedbg
        wineConsole = config.wine.console
        wineInheritConsole = config.wine.inheritConsole
        winetricksText = config.wine.winetricks.joined(separator: " ")

        splashFile = config.splash?.file ?? ""
        splashTransparent = config.splash?.transparent ?? true
        iconFile = config.icon ?? ""
        originURL = config.originURL ?? ""
    }

    // Seed sensible defaults from a drop. Sets sourcePath for the
    // Installer, picks a default install mode that fits the source kind,
    // and guesses a display name from the source's last path component.
    func seed(fromDrop dropped: DropZoneViewModel.DroppedSource) {
        switch dropped {
        case .folder(let url):
            sourcePath = url.path
            // Folder drops default to Link — the natural "run from where
            // it sits" mode. User can switch to Install/Bundle if they
            // want a copy.
            installMode = .link
            if displayName.isEmpty { displayName = url.lastPathComponent }
        case .zip(let url):
            sourcePath = url.path
            // Zip can't be Linked — pre-pick Install.
            installMode = .install
            if displayName.isEmpty {
                displayName = url.deletingPathExtension().lastPathComponent
            }
        case .url(let url):
            sourcePath = url.absoluteString
            // URL can't be Linked — pre-pick Install.
            installMode = .install
            if displayName.isEmpty {
                let stem = url.deletingPathExtension().lastPathComponent
                displayName = stem.isEmpty ? (url.host ?? "") : stem
            }
        case .bareConfig, .none:
            break
        }
    }

    // Returns the URL the user can browse for an executable, or nil if
    // browsing isn't applicable (path empty / not on disk / URL). The
    // picker uses sourcePath first (pre-install), then falls back to
    // applicationPath (post-install edit).
    var sourceForBrowsing: URL? {
        let candidate = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? applicationPath : sourcePath
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Remote URLs can't be browsed for an exe — user types it.
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return nil
        }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return url }
        return url.pathExtension.lowercased() == "zip" ? url : nil
    }

    // Interprets `sourcePath` as a SourceAcquisition the Installer can
    // consume. Nil when the input isn't understandable (empty, bogus URL,
    // or a file path that doesn't exist and isn't a .zip).
    var sourceAcquisition: SourceAcquisition? {
        let trimmed = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .url(url)
        }
        let path = (trimmed as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
        if exists, isDir.boolValue { return .folder(fileURL) }
        if exists, fileURL.pathExtension.lowercased() == "zip" { return .zip(fileURL) }
        return nil
    }

    func buildConfig() -> CiderConfig {
        // For Link mode, cider.json's applicationPath is the source folder
        // itself (absolute). For Install/Bundle it stays at whatever was
        // already loaded — the Installer overwrites it at apply time.
        let effectiveAppPath: String = {
            if installMode == .link {
                let trimmed = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? applicationPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    : (trimmed as NSString).expandingTildeInPath
            }
            return applicationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        return CiderConfig(
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            applicationPath: effectiveAppPath,
            exe: exe.trimmingCharacters(in: .whitespaces),
            args: tokenise(argsText),
            engine: CiderConfig.EngineRef(
                name: engineName.trimmingCharacters(in: .whitespaces),
                url: engineURL.trimmingCharacters(in: .whitespaces),
                sha256: emptyToNil(engineSha256)
            ),
            wrapperTemplate: CiderConfig.TemplateRef(
                version: templateVersion,
                url: templateURL,
                sha256: emptyToNil(templateSha256)
            ),
            graphics: graphics,
            wine: CiderConfig.WineOptions(
                esync: wineEsync,
                msync: wineMsync,
                useWinedbg: wineUseWinedbg,
                winetricks: tokenise(winetricksText),
                console: wineConsole,
                inheritConsole: wineInheritConsole
            ),
            splash: splashFile.isEmpty ? nil : CiderConfig.Splash(
                file: splashFile,
                transparent: splashTransparent
            ),
            icon: emptyToNil(iconFile),
            originURL: emptyToNil(originURL)
        )
    }

    // MARK: - Per-field validation (Phase 9)

    // Stored "general" error surfaced in the dialog when an Apply / Create
    // attempt failed. Set by DropZoneController right before re-opening
    // the dialog; cleared on the next successful Save.
    @Published var generalError: String? = nil

    var displayNameError: String? {
        displayName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Display name is required."
            : nil
    }

    var exeError: String? {
        exe.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Executable path is required."
            : nil
    }

    var engineNameError: String? {
        engineName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Engine name is required."
            : nil
    }

    var engineURLError: String? {
        let trimmed = engineURL.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Engine download URL is required." }
        if URL(string: trimmed)?.scheme == nil {
            return "Engine URL must include a scheme (https://…)."
        }
        return nil
    }

    var sourceError: String? {
        let trimmed = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        switch installMode {
        case .link:
            if trimmed.isEmpty { return "Pick the folder Cider should run in place." }
            if case .folder = sourceAcquisition { return nil }
            return "Link mode needs an existing local folder (not a zip or URL)."
        case .install, .bundle:
            // Either a fresh source must be set, or the user is editing
            // an existing config (applicationPath populated from load()).
            let hasExistingTarget = !applicationPath.trimmingCharacters(in: .whitespaces).isEmpty
            if trimmed.isEmpty {
                return hasExistingTarget ? nil : "Drop a folder, .zip, or paste a URL."
            }
            if sourceAcquisition == nil {
                return "Source must be an existing folder, .zip, or http(s):// URL."
            }
            return nil
        }
    }

    var isValid: Bool {
        displayNameError == nil
            && exeError == nil
            && engineNameError == nil
            && engineURLError == nil
            && sourceError == nil
    }

    // MARK: - Helpers

    // Absolute-looking path → Link; "Application" or "Application/..." →
    // Bundle; anything else relative → Install. Empty → Install (default).
    static func inferMode(from applicationPath: String) -> InstallMode {
        let p = applicationPath.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return .install }
        if p.hasPrefix("/") || p.hasPrefix("~") { return .link }
        if p == "Application" || p.hasPrefix("Application/") { return .bundle }
        return .install
    }

    private func emptyToNil(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func tokenise(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
