import Foundation
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
            // GUI is wired in Phase 4; for now print a placeholder.
            FileHandle.standardError.write(Data(
                "cider: GUI launched (no args). UI lands in Phase 4.\n".utf8))
            return
        }
        Cider.main(Array(argv.dropFirst()))
    }

    private static func shouldRunGUI(argv: [String]) -> Bool {
        if argv.count > 1 { return false }
        // launched from Finder/launchd → no controlling TTY on stdin
        return isatty(fileno(stdin)) == 0
    }
}

struct Cider: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cider",
        abstract: "Cider — wrap Windows apps as macOS .app bundles via Wine.",
        subcommands: [Apply.self, Clone.self, Config.self, Engines.self]
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
}
