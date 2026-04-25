import Foundation
import CiderModels

// Runs the long-lead-time setup work that used to be deferred to first
// launch — engine + template download, wineboot prefix initialisation,
// graphics driver install — at Create / Apply time so the resulting
// .app bundle is ready to double-click without a second long wait.
//
// Each step is idempotent: the engine/template caches honour the
// `.cider-extracted` marker, the prefix init is gated on
// `drive_c/windows`, the graphics driver re-copies the same DLLs every
// time (cheap). LaunchPipeline still calls the same managers as a
// safety net, so a Bundle distributed unzipped onto a fresh Mac that
// never went through Create still works — it just experiences the
// download/init at first launch like before.
//
// All steps report progress through the supplied callback. The phase
// IDs are stable strings the UI uses to drive its checklist (see the
// PhaseID enum).
public struct PreflightRunner {
    public enum PhaseID: String, CaseIterable {
        case engineDownload  = "preflight.engine"
        case templateDownload = "preflight.template"
        case prefixInit      = "preflight.prefix"
        case graphicsInstall = "preflight.graphics"

        public var label: String {
            switch self {
            case .engineDownload:  return "Downloading wine engine"
            case .templateDownload: return "Downloading wrapper template"
            case .prefixInit:      return "Initialising wine prefix"
            case .graphicsInstall: return "Installing graphics driver"
            }
        }

        public var kind: PhaseKind {
            switch self {
            case .engineDownload, .templateDownload: return .determinate
            case .prefixInit, .graphicsInstall:      return .indeterminate
            }
        }
    }

    public enum PhaseKind { case determinate, indeterminate }

    public let engineManager: EngineManager
    public let templateManager: TemplateManager

    public init(
        engineManager: EngineManager = EngineManager(),
        templateManager: TemplateManager = TemplateManager()
    ) {
        self.engineManager = engineManager
        self.templateManager = templateManager
    }

    // The phases this run will actually execute, in the order they'll
    // run. Steps that are already satisfied (engine cached, prefix
    // already initialised) still appear in the list but with `state:
    // .done` so the UI can render them as ticked-off without waiting
    // for them.
    public struct PlannedPhase {
        public let id: PhaseID
        public let label: String
        public let kind: PhaseKind
        public let alreadyDone: Bool
    }

    public func plan(for config: CiderConfig, configFile: URL) -> [PlannedPhase] {
        let prefix = LaunchPipeline.selectPrefix(config: config, configFile: configFile)
        let engineCached = isEngineCached(config.engine)
        let templateCached = isTemplateCached(config.wrapperTemplate)
        let prefixReady = isPrefixInitialised(prefix)
        return PhaseID.allCases.map { id in
            let alreadyDone: Bool
            switch id {
            case .engineDownload:   alreadyDone = engineCached
            case .templateDownload: alreadyDone = templateCached
            case .prefixInit:       alreadyDone = prefixReady
            case .graphicsInstall:  alreadyDone = false  // cheap, always re-run
            }
            return PlannedPhase(id: id, label: id.label, kind: id.kind,
                                alreadyDone: alreadyDone)
        }
    }

    // Run all phases. The callback is invoked with phase events (start
    // / progress / done) using the PhaseID raw value as the id. Stops
    // and rethrows on the first error.
    public func run(
        for config: CiderConfig,
        configFile: URL,
        progress: @escaping (Event) -> Void
    ) async throws {
        try Task.checkCancellation()

        // 1. Engine.
        let engineRoot: URL
        if isEngineCached(config.engine) {
            engineRoot = engineManager.cacheRoot
                .appendingPathComponent(config.engine.name, isDirectory: true)
        } else {
            progress(.started(.engineDownload))
            engineRoot = try await engineManager.ensure(
                config.engine,
                progress: { p in progress(.progress(.engineDownload, fraction(p))) }
            )
            progress(.done(.engineDownload))
        }
        try Task.checkCancellation()

        // 2. Template.
        let templateApp: URL
        if isTemplateCached(config.wrapperTemplate) {
            templateApp = templateManager.cacheRoot
                .appendingPathComponent("Template-\(config.wrapperTemplate.version)",
                                        isDirectory: true)
                .appendingPathComponent("Template-\(config.wrapperTemplate.version).app",
                                        isDirectory: true)
        } else {
            progress(.started(.templateDownload))
            templateApp = try await templateManager.ensure(
                config.wrapperTemplate,
                progress: { p in progress(.progress(.templateDownload, fraction(p))) }
            )
            progress(.done(.templateDownload))
        }
        try Task.checkCancellation()

        // 3. Prefix init (wineboot -u).
        let wineBinary = try engineManager.wineBinaryPath(in: engineRoot)
        let prefix = LaunchPipeline.selectPrefix(config: config, configFile: configFile)
        let prefixInit = PrefixInitializer(prefix: prefix, wineBinary: wineBinary)
        if !isPrefixInitialised(prefix) {
            progress(.started(.prefixInit))
            try prefixInit.initialise(skip: false)
            progress(.done(.prefixInit))
        }
        try Task.checkCancellation()

        // 4. Graphics driver DLLs. Cheap and safe to re-run, so we
        //    always do it — guarantees the prefix carries the renderer
        //    the user picked, even if a previous bundle in this same
        //    shared prefix configured a different one.
        progress(.started(.graphicsInstall))
        _ = try GraphicsDriver(
            kind: config.graphics,
            prefix: prefix,
            templateApp: templateApp,
            templateManager: templateManager
        ).install()
        progress(.done(.graphicsInstall))
    }

    // MARK: - Events

    public enum Event {
        case started(PhaseID)
        case progress(PhaseID, Double)
        case done(PhaseID)
    }

    // MARK: - Cache state probes

    private func isEngineCached(_ ref: CiderConfig.EngineRef) -> Bool {
        let marker = engineManager.cacheRoot
            .appendingPathComponent(ref.name, isDirectory: true)
            .appendingPathComponent(".cider-extracted")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    private func isTemplateCached(_ ref: CiderConfig.TemplateRef) -> Bool {
        let marker = templateManager.cacheRoot
            .appendingPathComponent("Template-\(ref.version)", isDirectory: true)
            .appendingPathComponent(".cider-extracted")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    private func isPrefixInitialised(_ prefix: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: prefix.appendingPathComponent("drive_c/windows").path)
    }

    private func fraction(_ p: Downloader.Progress) -> Double {
        guard p.total > 0 else { return 0 }
        return min(max(Double(p.bytes) / Double(p.total), 0), 1)
    }
}
