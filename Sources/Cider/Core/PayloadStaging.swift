import Foundation

// Extracts a user-supplied --input (directory or zip) into a staging directory
// so the bundler can treat both cases uniformly downstream.
enum PayloadStaging {
    struct Staged {
        let root: URL
        let isTemporary: Bool
    }

    static func stage(input: URL) throws -> Staged {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: input.path, isDirectory: &isDir) else {
            throw Error.inputMissing(input)
        }
        if isDir.boolValue {
            return Staged(root: input, isTemporary: false)
        }

        // Treat as archive — only .zip supported for user input at the moment.
        let ext = input.pathExtension.lowercased()
        guard ext == "zip" else {
            throw Error.unsupportedArchive(ext)
        }

        let tmp = fm.temporaryDirectory
            .appendingPathComponent("cider-input-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Shell.run("/usr/bin/unzip", ["-q", input.path, "-d", tmp.path], captureOutput: true)

        // If the zip contained a single top-level directory, use that as the root.
        let entries = try fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.isDirectoryKey])
        if entries.count == 1,
           let isEntryDir = try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
           isEntryDir {
            return Staged(root: entries[0], isTemporary: true)
        }
        return Staged(root: tmp, isTemporary: true)
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case inputMissing(URL)
        case unsupportedArchive(String)
        var description: String {
            switch self {
            case .inputMissing(let url): return "Input does not exist: \(url.path)"
            case .unsupportedArchive(let ext):
                return "Unsupported archive type '.\(ext)'. Supply a .zip or a directory."
            }
        }
    }
}
