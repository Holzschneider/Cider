import ArgumentParser
import Foundation

let ciderVersion = "0.1.0"

@main
struct Cider: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cider",
        abstract: "Bundle Windows apps into macOS .app wrappers using Wine.",
        version: ciderVersion,
        subcommands: [
            BundleCommand.self,
            EnginesCommand.self,
            InspectCommand.self,
            CacheCommand.self
        ]
    )
}

struct VerbosityOptions: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Print verbose output.")
    var verbose: Bool = false

    func apply() {
        Log.verbose = verbose
    }
}
