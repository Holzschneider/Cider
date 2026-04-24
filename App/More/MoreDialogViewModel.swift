import Foundation
import Combine
import CiderModels

// Form state for MoreDialog. One-to-one mapping with CiderConfig fields,
// flattened for direct SwiftUI binding (args → "argsText" joined by space,
// winetricks list → "winetricksText" joined by space). The fromConfig()
// and buildConfig() round-trip between this and CiderConfig.
@MainActor
final class MoreDialogViewModel: ObservableObject {
    // Basic
    @Published var displayName: String = ""
    @Published var exe: String = ""
    @Published var argsText: String = ""

    // Source
    @Published var sourceMode: CiderConfig.Source.Mode = .path
    @Published var sourcePath: String = ""
    @Published var sourceInBundleFolder: String = "Game"
    @Published var sourceURL: String = ""
    @Published var sourceSha256: String = ""

    // Engine
    @Published var engineName: String = ""
    @Published var engineURL: String = ""
    @Published var engineSha256: String = ""

    // Engine catalogue (per-row state for the "Wine engine" section).
    // The user toggles `useCustomRepository`; when off, the standard
    // Sikarugir Engines page URL is shown read-only and is what we list
    // against. When on, `customRepositoryURL` is editable.
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

    // Re-runs the catalog fetch for the current effectiveRepositoryURL.
    // No-ops if a fetch for the same URL is already in flight.
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
                // Pick a sensible default the FIRST time we populate the
                // list (or any time the engineName is empty / no longer
                // present in the new catalog).
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

    // Storage choice: default to AppSupport; toggling on stores cider.json
    // in the source folder so distributors can ship a folder that carries
    // its own config.
    @Published var storeInSourceFolder: Bool = false

    // MARK: - Round-trip

    func load(from config: CiderConfig) {
        displayName = config.displayName
        exe = config.exe
        argsText = config.args.joined(separator: " ")

        sourceMode = config.source.mode
        sourcePath = config.source.path ?? ""
        sourceInBundleFolder = config.source.inBundleFolder ?? "Game"
        sourceURL = config.source.url ?? ""
        sourceSha256 = config.source.sha256 ?? ""

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
    }

    // Seed sensible defaults from a folder/zip drop. Called when the user
    // drops something that has no embedded cider.json.
    func seed(fromDrop dropped: DropZoneViewModel.DroppedSource) {
        switch dropped {
        case .folder(let url):
            sourceMode = .path
            sourcePath = url.path
            if displayName.isEmpty { displayName = url.lastPathComponent }
        case .zip(let url):
            sourceMode = .path
            sourcePath = url.path
            if displayName.isEmpty {
                displayName = url.deletingPathExtension().lastPathComponent
            }
        case .bareConfig, .none:
            break
        }
    }

    func buildConfig() -> CiderConfig {
        CiderConfig(
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            exe: exe.trimmingCharacters(in: .whitespaces),
            args: tokenise(argsText),
            source: CiderConfig.Source(
                mode: sourceMode,
                path: sourceMode == .path ? emptyToNil(sourcePath) : nil,
                inBundleFolder: sourceMode == .inBundle ? emptyToNil(sourceInBundleFolder) : nil,
                url: sourceMode == .url ? emptyToNil(sourceURL) : nil,
                sha256: emptyToNil(sourceSha256)
            ),
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
            icon: emptyToNil(iconFile)
        )
    }

    var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !exe.trimmingCharacters(in: .whitespaces).isEmpty &&
        !engineName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !engineURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        sourceHasPayload
    }

    private var sourceHasPayload: Bool {
        switch sourceMode {
        case .path: return !sourcePath.trimmingCharacters(in: .whitespaces).isEmpty
        case .inBundle: return !sourceInBundleFolder.trimmingCharacters(in: .whitespaces).isEmpty
        case .url: return !sourceURL.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func emptyToNil(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func tokenise(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
