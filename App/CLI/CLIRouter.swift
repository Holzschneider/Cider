import Foundation
import AppKit
import ArgumentParser
import CiderCore
import CiderModels

// `cider` is the same Mach-O whether launched by Finder/launchd or invoked
// from a terminal. CLIRouter decides which mode to run in:
//  - explicit subcommand on argv → CLI
//  - "no args" (Finder/launchd double-click) → GUI
struct CLIRouter {
    static func run() {
        let argv = CommandLine.arguments
        if shouldRunGUI(argv: argv) {
            MainActor.assumeIsolated { GUIEntry.run() }
            return
        }
        // AsyncParsableCommand requires the parent's main() be awaited.
        // Bridge from sync CiderApp.main() via DispatchSemaphore.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await Cider.main(Array(argv.dropFirst()))
            semaphore.signal()
        }
        semaphore.wait()
    }

    private static func shouldRunGUI(argv: [String]) -> Bool {
        if argv.count > 1 { return false }
        // Launched from Finder/launchd → no controlling TTY on stdin.
        return isatty(fileno(stdin)) == 0
    }
}

// Default GUI flow:
//   - config found      → splash window (and from there, Phase 10 launches wine)
//   - config not found  → drop zone window (configure-and-apply UX)
@MainActor
enum GUIEntry {
    static func run() {
        let env = BundleEnvironment.resolve()
        let store = ConfigStore(
            inBundleConfigFile: env.inBundleConfigFile,
            appSupportConfigFile: env.appSupportConfigFile
        )
        let resolved = (try? store.locate()) ?? nil
        let shell = AppShell()

        if let resolved {
            // Configured bundle → splash + LaunchPipeline.
            let cfg = resolved.config
            let configBaseDir = configBaseDir(for: resolved.source)
            let splashURL = splashURL(for: cfg, baseDir: configBaseDir)
            let iconURL = iconURL(for: cfg, baseDir: configBaseDir)

            // First-launch (or per-launch) icon refresh: cheap; just
            // re-apply on every launch so the user always sees the icon
            // their cider.json says they should see.
            applyIconIfPresent(iconURL, to: env.bundleURL)

            let controller = SplashController.load(
                splashFile: splashURL,
                transparentHint: cfg.splash?.transparent ?? false
            )
            controller?.onDoubleClick = { [weak controller] in
                let outcome = MoreDialogController.present(prefill: cfg, dropped: .none)
                if case .saved(let updated, _) = outcome {
                    do {
                        switch resolved.source {
                        case .inBundleOverride(let url):
                            try updated.write(to: url)
                        case .appSupport(let url):
                            try updated.write(to: url)
                        }
                        controller?.requestClose()
                    } catch {
                        let alert = NSAlert()
                        alert.messageText = "Could not save updated configuration"
                        alert.informativeText = String(describing: error)
                        alert.runModal()
                    }
                }
            }
            shell.run { _ in
                controller?.attach()
                runLaunchPipeline(
                    config: cfg,
                    bundleURL: env.bundleURL,
                    bundleName: env.bundleName,
                    splash: controller
                )
            }
        } else {
            // Unconfigured bundle → drop zone window.
            let controller = DropZoneController(bundleEnv: env)
            shell.run { _ in controller.attach() }
        }
    }

    private static func configBaseDir(for source: ConfigStore.Resolved.Source) -> URL {
        switch source {
        case .inBundleOverride(let url): return url.deletingLastPathComponent()
        case .appSupport(let url): return url.deletingLastPathComponent()
        }
    }

    private static func splashURL(for cfg: CiderConfig, baseDir: URL) -> URL? {
        guard let file = cfg.splash?.file else { return nil }
        return baseDir.appendingPathComponent(file)
    }

    private static func iconURL(for cfg: CiderConfig, baseDir: URL) -> URL? {
        guard let file = cfg.icon else { return nil }
        return baseDir.appendingPathComponent(file)
    }

    private static func applyIconIfPresent(_ iconURL: URL?, to bundleURL: URL) {
        guard let iconURL,
              FileManager.default.fileExists(atPath: iconURL.path)
        else { return }
        let icnsURL: URL
        if iconURL.pathExtension.lowercased() == "icns" {
            icnsURL = iconURL
        } else {
            // Convert to a temp .icns; success or failure both non-fatal.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("cider-icon-\(UUID().uuidString).icns")
            do {
                try IconConverter.convert(png: iconURL, destination: tmp)
                icnsURL = tmp
            } catch {
                Log.warn("could not convert icon to .icns: \(error)")
                return
            }
        }
        _ = IconConverter.applyAsCustomIcon(at: icnsURL, to: bundleURL)
    }

    // Kicks off LaunchPipeline on a background Task while AppKit drives
    // the splash. On normal exit, terminates the app with wine's exit
    // code (best-effort — NSApplication.terminate doesn't accept a code,
    // so we exit() if non-zero).
    private static func runLaunchPipeline(
        config: CiderConfig,
        bundleURL: URL,
        bundleName: String,
        splash: SplashController?
    ) {
        let pipeline = LaunchPipeline(
            config: config,
            bundleURL: bundleURL,
            bundleName: bundleName,
            progress: { title, detail, fraction in
                FileHandle.standardError.write(Data(
                    "• \(title)\(detail.isEmpty ? "" : ": \(detail)")\(fraction.map { String(format: "  (%.0f%%)", $0 * 100) } ?? "")\n".utf8))
                guard let splash else { return }
                Task { @MainActor in
                    splash.progress.show(title: title, detail: detail, fraction: fraction)
                }
            },
            settle: {
                Task { @MainActor in
                    splash?.progress.hide()
                }
            },
            onError: { error in
                FileHandle.standardError.write(Data("✗ launch failed: \(error)\n".utf8))
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = "Launch failed"
                    alert.informativeText = String(describing: error)
                    alert.alertStyle = .warning
                    alert.runModal()
                    NSApplication.shared.terminate(nil)
                }
            }
        )

        Task.detached {
            do {
                let exitCode = try await pipeline.runEndToEnd()
                Log.info("wine exited with status \(exitCode)")
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }
                if exitCode != 0 { exit(exitCode) }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Launch failed"
                    alert.informativeText = String(describing: error)
                    alert.alertStyle = .warning
                    alert.runModal()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}

struct Cider: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cider",
        abstract: "Cider — wrap Windows apps as macOS .app bundles via Wine.",
        subcommands: [Apply.self, Clone.self, Config.self, Engines.self, Launch.self, PreviewSplash.self]
    )
}

// Shared between `apply` and `clone`. Resolves config + optional icon
// (PNG → .icns conversion if needed), runs BundleTransmogrifier, and
// reports the resulting paths.
private func transmogrify(
    configPath: String,
    iconPath: String?,
    storage: BundleTransmogrifier.ConfigStorage,
    force: Bool,
    mode: BundleTransmogrifier.Mode
) throws {
    let configURL = URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
    let cfg = try CiderConfig.read(from: configURL)

    let env = BundleEnvironment.resolve()
    var icnsURL: URL?
    if let iconPath {
        let iconURL = URL(fileURLWithPath: (iconPath as NSString).expandingTildeInPath)
        if iconURL.pathExtension.lowercased() == "icns" {
            icnsURL = iconURL
        } else {
            let tmpIcns = FileManager.default.temporaryDirectory
                .appendingPathComponent("cider-icon-\(UUID().uuidString).icns")
            try IconConverter.convert(png: iconURL, destination: tmpIcns)
            icnsURL = tmpIcns
        }
    }

    let result = try BundleTransmogrifier(
        currentBundle: env.bundleURL,
        config: cfg,
        icnsURL: icnsURL,
        storage: storage,
        allowOverwrite: force
    ).transmogrify(mode: mode)

    let actionLabel: String
    switch mode {
    case .applyInPlace: actionLabel = "applied (in place)"
    case .cloneTo: actionLabel = "cloned"
    }
    FileHandle.standardError.write(Data(
        "cider: \(actionLabel) → \(result.finalBundleURL.path)\n".utf8))
    FileHandle.standardError.write(Data(
        "       config: \(result.configWrittenTo.path)\n".utf8))
    if icnsURL != nil {
        FileHandle.standardError.write(Data(
            "       icon: \(result.iconApplied ? "applied" : "FAILED")\n".utf8))
    }
}

extension Cider {
    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "config",
            abstract: "Inspect or manipulate this bundle's cider.json.",
            subcommands: [Show.self]
        )

        struct Show: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "show",
                abstract: "Print the resolved cider.json (in-bundle override beats AppSupport)."
            )

            func run() throws {
                let env = BundleEnvironment.resolve()
                let store = ConfigStore(
                    inBundleConfigFile: env.inBundleConfigFile,
                    appSupportConfigFile: env.appSupportConfigFile
                )
                guard let resolved = try store.locate() else {
                    FileHandle.standardError.write(Data(
                        "cider: no config found for bundle '\(env.bundleName)'.\n".utf8))
                    FileHandle.standardError.write(Data(
                        "       checked: \(env.inBundleConfigFile.path)\n".utf8))
                    FileHandle.standardError.write(Data(
                        "                \(env.appSupportConfigFile.path)\n".utf8))
                    throw ExitCode(1)
                }
                let label: String
                switch resolved.source {
                case .inBundleOverride(let url): label = "in-bundle override at \(url.path)"
                case .appSupport(let url): label = "AppSupport at \(url.path)"
                }
                FileHandle.standardError.write(Data("cider: source: \(label)\n".utf8))
                let data = try resolved.config.encoded()
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
    }

    enum StorageOption: String, EnumerableFlag {
        case appSupport
        case inBundleOverride
        var storage: BundleTransmogrifier.ConfigStorage {
            switch self {
            case .appSupport: return .appSupport
            case .inBundleOverride: return .inBundleOverride
            }
        }
        static func name(for value: Self) -> NameSpecification {
            switch value {
            case .appSupport: return [.customLong("app-support")]
            case .inBundleOverride: return [.customLong("in-bundle")]
            }
        }
        static func help(for value: Self) -> ArgumentHelp? {
            switch value {
            case .appSupport:
                return "Store cider.json under ~/Library/Application Support/Cider/Configs/<bundle>.json (default)."
            case .inBundleOverride:
                return "Store cider.json inside the bundle as <bundle>/CiderConfig/cider.json."
            }
        }
    }

    struct Apply: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "apply",
            abstract: "Transmogrify this bundle in place: rename it, set its custom icon, persist its cider.json."
        )

        @Option(name: .shortAndLong, help: "Path to the cider.json to apply.")
        var config: String

        @Option(name: .long, help: "Pre-converted .icns to apply as the Finder custom icon.")
        var icon: String?

        @Flag(help: "Where to write cider.json.")
        var storage: StorageOption = .appSupport

        @Flag(name: .long, help: "Replace an existing target bundle / config without prompting.")
        var force: Bool = false

        func run() throws {
            try transmogrify(
                configPath: config,
                iconPath: icon,
                storage: storage.storage,
                force: force,
                mode: .applyInPlace
            )
        }
    }

    struct Clone: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clone",
            abstract: "Clone this bundle to a new path with a cider.json applied. Original stays untouched."
        )

        @Option(name: .shortAndLong, help: "Destination .app path (e.g. ~/Apps/MyGame.app).")
        var to: String

        @Option(name: .shortAndLong, help: "Path to the cider.json to apply.")
        var config: String

        @Option(name: .long, help: "Pre-converted .icns to apply as the Finder custom icon.")
        var icon: String?

        @Flag(help: "Where to write cider.json.")
        var storage: StorageOption = .appSupport

        @Flag(name: .long, help: "Replace an existing destination without prompting.")
        var force: Bool = false

        func run() throws {
            let dest = URL(fileURLWithPath: (to as NSString).expandingTildeInPath)
            try transmogrify(
                configPath: config,
                iconPath: icon,
                storage: storage.storage,
                force: force,
                mode: .cloneTo(dest)
            )
        }
    }

    struct Engines: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "engines",
            abstract: "Manage the shared engine cache.",
            subcommands: [List.self]
        )

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list",
                abstract: "List engines under ~/Library/Application Support/Cider/Engines/."
            )

            func run() throws {
                let cached = try EngineManager().listCached()
                if cached.isEmpty {
                    FileHandle.standardOutput.write(Data("(no cached engines)\n".utf8))
                    return
                }
                for entry in cached {
                    FileHandle.standardOutput.write(Data("\(entry.name)\t\(entry.path.path)\n".utf8))
                }
            }
        }
    }

    // Diagnostic: runs the LaunchPipeline against this bundle's resolved
    // config (in-bundle override → AppSupport-by-name) without showing
    // the splash. Useful for shaking out wine launch problems without the
    // GUI getting in the way. Wine output is echoed to stderr so the user
    // can watch the trace.
    struct Launch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "launch",
            abstract: "(diagnostic) Run the configured LaunchPipeline headlessly (no splash)."
        )

        func run() async throws {
            let env = BundleEnvironment.resolve()
            let store = ConfigStore(
                inBundleConfigFile: env.inBundleConfigFile,
                appSupportConfigFile: env.appSupportConfigFile
            )
            guard let resolved = try store.locate() else {
                FileHandle.standardError.write(Data(
                    "cider launch: no config for bundle '\(env.bundleName)'.\n".utf8))
                throw ExitCode(1)
            }
            let pipeline = LaunchPipeline(
                config: resolved.config,
                bundleURL: env.bundleURL,
                bundleName: env.bundleName,
                progress: { title, detail, fraction in
                    let pct = fraction.map { String(format: "  (%.0f%%)", $0 * 100) } ?? ""
                    FileHandle.standardError.write(Data(
                        "• \(title)\(detail.isEmpty ? "" : ": \(detail)")\(pct)\n".utf8))
                },
                settle: {
                    FileHandle.standardError.write(Data("• game settled\n".utf8))
                },
                onError: { error in
                    FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
                }
            )
            let exit = try await pipeline.runEndToEnd()
            FileHandle.standardError.write(Data("• wine exited with status \(exit)\n".utf8))
            throw ExitCode(exit)
        }
    }

    // Diagnostic: opens the borderless transparent splash window with a
    // given image so visual layout / transparency can be eyeballed without
    // a full launch flow. Not for end-users.
    struct PreviewSplash: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "preview-splash",
            abstract: "(diagnostic) Open the splash window for a given image.",
            shouldDisplay: false
        )

        @Option(name: .long, help: "Path to a PNG/JPG image to display.")
        var image: String

        @Flag(name: .long, help: "Treat as transparent (PNG with alpha).")
        var transparent: Bool = false

        @Flag(name: .long, help: "After ~1s, simulate progress overlay.")
        var withProgress: Bool = false

        func run() throws {
            let url = URL(fileURLWithPath: image)
            let withProgress = self.withProgress
            let transparent = self.transparent
            try MainActor.assumeIsolated {
                guard let controller = SplashController.load(
                    splashFile: url,
                    transparentHint: transparent
                ) else {
                    FileHandle.standardError.write(Data(
                        "preview-splash: could not load image at \(url.path)\n".utf8))
                    throw ExitCode(1)
                }
                if withProgress {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        controller.progress.show(
                            title: "Downloading engine",
                            detail: "WS12WineCX24.0.7_7.tar.xz",
                            fraction: 0.0
                        )
                        for i in 1...20 {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            controller.progress.update(fraction: Double(i) / 20.0)
                        }
                        controller.progress.show(
                            title: "Loading game",
                            detail: "",
                            fraction: nil
                        )
                    }
                }
                controller.runEventLoop()
            }
        }
    }
}
