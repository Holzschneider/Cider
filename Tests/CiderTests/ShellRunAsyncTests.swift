import XCTest
@testable import CiderCore

final class ShellRunAsyncTests: XCTestCase {

    func testRunsToCompletion() async throws {
        let result = try await Shell.runAsync("/bin/echo", ["hello"], captureOutput: true)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testNonZeroExitThrowsShellError() async {
        do {
            _ = try await Shell.runAsync("/bin/sh", ["-c", "exit 7"])
            XCTFail("expected ShellError.nonZeroExit")
        } catch ShellError.nonZeroExit(_, let status, _) {
            XCTAssertEqual(status, 7)
        } catch {
            XCTFail("expected ShellError.nonZeroExit, got \(error)")
        }
    }

    func testTaskCancellationKillsRunningProcess() async throws {
        // Spawn a long-running sleep, cancel after a short delay, expect
        // CancellationError within roughly the time it takes for SIGTERM
        // to propagate (well under sleep's 60s).
        let started = Date()
        let task = Task<Void, Swift.Error> {
            _ = try await Shell.runAsync("/bin/sleep", ["60"])
        }
        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
        task.cancel()

        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // ok
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 5.0, "cancel should propagate within seconds, not wait for sleep")
    }

    func testAlreadyCancelledTaskThrowsBeforeSpawning() async {
        let task = Task<Void, Swift.Error> {
            // Cancel ourselves before invoking Shell — runAsync's leading
            // checkCancellation should fire.
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await Shell.runAsync("/bin/sleep", ["60"])
        }
        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // ok
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}
