import ArgumentParser
import Foundation

struct EnginesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engines",
        abstract: "Manage the local engine cache.",
        subcommands: [List.self, Pull.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List cached Wine engines."
        )

        @OptionGroup var verbosity: VerbosityOptions

        func run() async throws {
            verbosity.apply()
            let manager = EngineManager()
            let cached = try manager.listCached()
            if cached.isEmpty {
                print("(no cached engines)")
                return
            }
            for entry in cached {
                print("\(entry.name)\t\(entry.path.path)")
            }
        }
    }

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pull",
            abstract: "Download a Wine engine into the cache."
        )

        @Argument(help: "Engine name, e.g. WS12WineCX24.0.7_7.")
        var name: String

        @Flag(name: .long, help: "Re-download even if cached.")
        var force: Bool = false

        @OptionGroup var verbosity: VerbosityOptions

        func run() async throws {
            verbosity.apply()
            let engine = try EngineName(name)
            let manager = EngineManager()
            let path = try await manager.ensure(engine, forceRefresh: force)
            print(path.path)
        }
    }
}
