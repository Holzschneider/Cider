import Foundation

// Thin wrapper around Process for synchronous command invocation.
public enum Shell {
    public struct Result {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        captureOutput: Bool = false
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            environment.forEach { merged[$0.key] = $0.value }
            process.environment = merged
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        if captureOutput {
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        Log.debug("$ \(executable) \(arguments.joined(separator: " "))")
        try process.run()
        process.waitUntilExit()

        let stdout = captureOutput
            ? String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            : ""
        let stderr = captureOutput
            ? String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            : ""

        let result = Result(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        if result.status != 0 {
            throw ShellError.nonZeroExit(command: executable, status: result.status, stderr: stderr)
        }
        return result
    }
}

public enum ShellError: Error, CustomStringConvertible {
    case nonZeroExit(command: String, status: Int32, stderr: String)

    public var description: String {
        switch self {
        case let .nonZeroExit(cmd, status, stderr):
            let tail = stderr.isEmpty ? "" : "\n---\n\(stderr)"
            return "\(cmd) exited with status \(status).\(tail)"
        }
    }
}
