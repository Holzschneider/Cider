import ArgumentParser
import Foundation

struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "Inspect or clean the Cider cache.",
        subcommands: [Path.self, Prune.self]
    )

    struct Path: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "path",
            abstract: "Print the cache root."
        )

        func run() async throws {
            print(CachePaths.root.path)
        }
    }

    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Delete cached engines not referenced by any known bundle."
        )

        @Flag(name: .long, help: "List what would be deleted without removing anything.")
        var dryRun: Bool = false

        @OptionGroup var verbosity: VerbosityOptions

        func run() async throws {
            verbosity.apply()
            Log.warn("cache prune: reference tracking not yet implemented; listing cached engines only.")
            let manager = EngineManager()
            for entry in try manager.listCached() {
                print(entry.name)
            }
            if !dryRun {
                Log.warn("pass --dry-run until prune logic lands.")
            }
        }
    }
}
