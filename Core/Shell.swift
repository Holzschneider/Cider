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

// MARK: - Cancellable async variant

public extension Shell {
    // Async variant that respects Swift Task cancellation. On cancel, the
    // child process gets SIGTERM and runAsync throws CancellationError as
    // soon as it exits. Used by the Installer (Phase 7) so a user-clicked
    // Cancel during a multi-GB cp -R or unzip actually halts the work
    // instead of waiting for it to finish.
    @discardableResult
    static func runAsync(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        captureOutput: Bool = false
    ) async throws -> Result {
        try Task.checkCancellation()

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

        // The terminationHandler fires on a Process-internal queue with
        // no surrounding Swift Task, so `Task.isCancelled` always reads
        // false in that context. Track the cancel intent explicitly via
        // a flag the cancel handler flips before sending SIGTERM.
        let cancelFlag = CancelFlag()

        return try await withTaskCancellationHandler {
            try process.run()
            return try await withCheckedThrowingContinuation { cont in
                let box = ContinuationBox(cont)
                process.terminationHandler = { proc in
                    let stdout = captureOutput
                        ? String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        : ""
                    let stderr = captureOutput
                        ? String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        : ""
                    let status = proc.terminationStatus
                    if cancelFlag.isSet {
                        box.resume(throwing: CancellationError())
                    } else if status != 0 {
                        box.resume(throwing: ShellError.nonZeroExit(
                            command: executable, status: status, stderr: stderr))
                    } else {
                        box.resume(returning: Result(status: status, stdout: stdout, stderr: stderr))
                    }
                }
            }
        } onCancel: {
            // Signal-only — let the terminationHandler resume the
            // continuation once the kernel reaps the process.
            cancelFlag.set()
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

// Tiny thread-safe boolean. Only set, never unset.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool = false
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
    func set() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }
}

// Single-shot wrapper around CheckedContinuation so that competing
// resume() calls (one from terminationHandler, one from a hypothetical
// future error path) don't trip Swift's "resumed twice" precondition.
private final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Swift.Error>?

    init(_ cont: CheckedContinuation<T, Swift.Error>) {
        self.cont = cont
    }

    func resume(returning value: T) {
        guard let c = take() else { return }
        c.resume(returning: value)
    }

    func resume(throwing error: Swift.Error) {
        guard let c = take() else { return }
        c.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Swift.Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = cont
        cont = nil
        return c
    }
}
