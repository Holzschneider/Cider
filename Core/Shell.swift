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

// MARK: - Copy with polled progress

public extension Shell {
    // Spawns a copy command (cp -R, cp -a, ditto, …) and reports a
    // 0–1 fraction by polling the destination's `du -sk` against a
    // pre-computed source size every ~250 ms. Imprecise (du visits the
    // whole tree on each poll) but works with stock macOS tools and
    // gracefully degrades on very large trees — the user sees a bar
    // that keeps moving instead of an indeterminate spinner. Cancellation
    // works the same way as runAsync — SIGTERM the copy child, throw
    // CancellationError.
    @discardableResult
    static func runCopyWithPolledProgress(
        executable: String,
        arguments: [String],
        sourcePath: String,
        destinationPath: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Result {
        // Pre-compute source size in 1KB blocks. If du fails (broken
        // permissions, etc.) we fall back to indeterminate by reporting
        // no fraction events.
        let sourceKB = try? duSizeKB(of: sourcePath)
        let totalKB = sourceKB ?? 0

        // Spawn the polling task; it lives until the copy completes or
        // we cancel.
        let pollTask = Task<Void, Never>(priority: .background) {
            guard totalKB > 0 else { return }
            while !Task.isCancelled {
                let doneKB = (try? duSizeKB(of: destinationPath)) ?? 0
                let fraction = min(max(Double(doneKB) / Double(totalKB), 0), 0.999)
                progress(fraction)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { pollTask.cancel() }

        let result = try await runAsync(executable, arguments)
        // One last 100% beat so the bar settles.
        if totalKB > 0 { progress(1.0) }
        return result
    }

    // `du -sk path` → kilobytes used. Returns 0 when du can't read the
    // path (e.g. it doesn't exist yet — true for the destination on
    // the first few polls).
    private static func duSizeKB(of path: String) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(),
                         as: UTF8.self)
        // Output looks like:  "12345\t/path/to/dir"
        let firstField = out.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
        return firstField.flatMap { Int64($0) } ?? 0
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
