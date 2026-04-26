import XCTest
@testable import CiderCore

final class LogFileTailerTests: XCTestCase {

    private func tempLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-tail-\(UUID().uuidString).log")
    }

    func testResetFileRemovesPreviousContent() throws {
        let url = tempLogURL()
        try Data("stale\n".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        LogFileTailer.resetFile(at: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTailerYieldsAppendedLines() async throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Pre-create the file so the tailer doesn't have to wait for it.
        try Data().write(to: url)

        let tailer = LogFileTailer(url: url, pollSeconds: 0.05)
        var received: [String] = []

        let collectTask = Task<Void, Never> {
            for await line in tailer.lines() {
                received.append(line)
                if received.count >= 3 { break }
            }
        }

        // Append three lines across two writes.
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        try handle.write(contentsOf: Data("line one\nline two\n".utf8))
        try? await Task.sleep(nanoseconds: 200_000_000)
        try handle.write(contentsOf: Data("line three\n".utf8))

        // Bound the wait; cancel either way.
        let timeoutTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            collectTask.cancel()
        }
        await collectTask.value
        timeoutTask.cancel()

        XCTAssertEqual(received, ["line one", "line two", "line three"])
    }

    func testPartialLineBufferedUntilNewline() async throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        let tailer = LogFileTailer(url: url, pollSeconds: 0.05)

        var received: [String] = []
        let collectTask = Task<Void, Never> {
            for await line in tailer.lines() {
                received.append(line)
                if !received.isEmpty { break }
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        try handle.write(contentsOf: Data("partial".utf8))   // no newline yet
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(received.isEmpty,
                      "tailer should buffer partial lines until newline arrives")
        try handle.write(contentsOf: Data(" rest\n".utf8))
        let timeoutTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            collectTask.cancel()
        }
        await collectTask.value
        timeoutTask.cancel()
        XCTAssertEqual(received.first, "partial rest")
    }
}
