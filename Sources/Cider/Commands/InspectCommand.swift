import ArgumentParser
import Foundation

struct InspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Print Cider metadata for a built .app bundle."
    )

    @Argument(help: "Path to a .app bundle produced by Cider.")
    var bundle: String

    @OptionGroup var verbosity: VerbosityOptions

    func run() async throws {
        verbosity.apply()
        let bundleURL = URL(fileURLWithPath: bundle)
        let metaURL = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("cider.json")
        let data = try Data(contentsOf: metaURL)
        let metadata = try JSONDecoder.cider.decode(BundleConfig.BundleMetadata.self, from: data)
        print("Engine:       \(metadata.engine)")
        print("Graphics:     \(metadata.graphics.rawValue)")
        print("Exe (Win):    \(metadata.winExePath)")
        print("Args:         \(metadata.exeArgs.joined(separator: " "))")
        print("Created:      \(ISO8601DateFormatter().string(from: metadata.createdAt))")
        print("Cider:        \(metadata.ciderVersion)")
    }
}

extension JSONDecoder {
    static let cider: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let cider: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
