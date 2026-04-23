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
        Cider.main(Array(argv.dropFirst()))
    }

    private static func shouldRunGUI(argv: [String]) -> Bool {
        if argv.count > 1 { return false }
        // Launched from Finder/launchd → no controlling TTY on stdin.
        return isatty(fileno(stdin)) == 0
    }
}

// Default GUI flow: show splash if a config is found, otherwise print a
// placeholder until Phase 8 lands the drop zone.
@MainActor
enum GUIEntry {
    static func run() {
        let env = BundleEnvironment.resolve()
        let store = ConfigStore(
            inBundleConfigFile: env.inBundleConfigFile,
            appSupportConfigFile: env.appSupportConfigFile
        )
        guard let resolved = try? store.locate() else {
            FileHandle.standardError.write(Data(
                "cider: no config for bundle '\(env.bundleName)'. Drop-zone window lands in Phase 8.\n".utf8))
            return
        }
        let cfg = resolved.config
        let splashURL = splashURL(for: cfg, configSource: resolved.source)
        guard let controller = SplashController.load(
            splashFile: splashURL,
            transparentHint: cfg.splash?.transparent ?? false
        ) else {
            FileHandle.standardError.write(Data(
                "cider: no splash image found for bundle '\(env.bundleName)'.\n".utf8))
            return
        }
        controller.runEventLoop()
    }

    // Splash + icon paths in cider.json are resolved relative to the
    // directory the cider.json itself lives in.
    private static func splashURL(
        for cfg: CiderConfig,
        configSource: ConfigStore.Resolved.Source
    ) -> URL? {
        guard let file = cfg.splash?.file else { return nil }
        let baseDir: URL
        switch configSource {
        case .inBundleOverride(let url): baseDir = url.deletingLastPathComponent()
        case .appSupport(let url): baseDir = url.deletingLastPathComponent()
        }
        return baseDir.appendingPathComponent(file)
    }
}

struct Cider: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cider",
        abstract: "Cider — wrap Windows apps as macOS .app bundles via Wine.",
        subcommands: [Apply.self, Clone.self, Config.self, Engines.self, PreviewSplash.self]
    )
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

    // Apply, Clone, Engines are stubs landed for CLI shape; their bodies
    // get filled in by Phases 6 and 7.
    struct Apply: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "apply",
            abstract: "(stub) In-place transmogrify this bundle from a cider.json."
        )
        @Option(name: .shortAndLong, help: "Path to a cider.json file.")
        var config: String

        func run() throws {
            FileHandle.standardError.write(Data(
                "cider apply: not yet implemented (Phase 7). Would apply \(config).\n".utf8))
        }
    }

    struct Clone: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clone",
            abstract: "(stub) Clone this bundle to a new path with a cider.json applied."
        )
        @Option(name: .shortAndLong, help: "Destination .app path.")
        var to: String
        @Option(name: .shortAndLong, help: "Path to a cider.json file.")
        var config: String

        func run() throws {
            FileHandle.standardError.write(Data(
                "cider clone: not yet implemented (Phase 7). Would clone to \(to).\n".utf8))
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
