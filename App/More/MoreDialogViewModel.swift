import Foundation
import Combine
import CiderModels

// Schema-v2 form state for MoreDialog. The "source" half of the v1 schema
// (mode/path/url/inBundleFolder/sha256) is gone — the user picks an
// install mode at config time and the result is captured as a single
// `applicationPath` (relative or absolute) in cider.json.
//
// For Phase 1 the install-mode picker isn't built yet (Phase 6); the form
// shows a single editable Application path that the user can adjust.
@MainActor
final class MoreDialogViewModel: ObservableObject {
    // Basic
    @Published var displayName: String = ""
    @Published var exe: String = ""
    @Published var argsText: String = ""

    // Application directory (resolved on launch). Relative or absolute.
    // Phase 6 will hide this behind the install-mode picker; for now it's
    // editable so we can keep the schema testable end-to-end.
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

    // Seed sensible defaults from a folder/zip drop. Until Phase 2-4 wire
    // the Installer up, applicationPath is just the dropped item's name —
    // good enough for Link mode and a sensible starting point for the
    // proper install-mode picker in Phase 6.
    func seed(fromDrop dropped: DropZoneViewModel.DroppedSource) {
        switch dropped {
        case .folder(let url):
            applicationPath = url.path  // absolute → Link-mode default
            if displayName.isEmpty { displayName = url.lastPathComponent }
        case .zip(let url):
            applicationPath = url.path  // absolute, but no on-disk dir; Phase 3 will install
            if displayName.isEmpty {
                displayName = url.deletingPathExtension().lastPathComponent
            }
        case .bareConfig, .none:
            break
        }
    }

    // Returns the URL the user can browse for an executable, or nil if
    // browsing isn't applicable (path empty / not on disk).
    var sourceForBrowsing: URL? {
        let trimmed = applicationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return url }
        return url.pathExtension.lowercased() == "zip" ? url : nil
    }

    func buildConfig() -> CiderConfig {
        CiderConfig(
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            applicationPath: applicationPath.trimmingCharacters(in: .whitespaces),
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

    var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !exe.trimmingCharacters(in: .whitespaces).isEmpty &&
        !engineName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !engineURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !applicationPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func emptyToNil(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func tokenise(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
