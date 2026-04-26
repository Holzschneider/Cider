import Foundation

// Tails a log file for the .logFile loading source. Cider deletes the
// file before launch so we observe only what the launched application
// writes. Polling-based (250ms ticks): the user's app may not flush
// frequently enough for FSEvents to fire reliably for short bursts,
// and 4 reads/sec is fine for a status line.
//
// Yields the *new* full lines that have appeared since the last poll.
// Trailing partial lines are buffered until a newline arrives.
public actor LogFileTailer {
    private let url: URL
    private var handle: FileHandle?
    private var buffer = Data()

    // Default poll interval — fast enough that the loading window
    // status line feels live, slow enough to not chew CPU during
    // long quiet periods.
    public let pollSeconds: Double

    public init(url: URL, pollSeconds: Double = 0.25) {
        self.url = url
        self.pollSeconds = pollSeconds
    }

    // Wipes any pre-existing log file. Caller must do this BEFORE
    // launching the app so we don't read stale lines from a previous
    // session as if they were live.
    public static func resetFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // Async stream of new lines as they appear. The stream stays
    // alive until the caller cancels the surrounding task. If the
    // file doesn't exist yet, the tailer waits for it to appear
    // (the launched app may take a beat to create it).
    public nonisolated func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let newLines = await self.readNewLines()
                    for line in newLines {
                        continuation.yield(line)
                    }
                    try? await Task.sleep(
                        nanoseconds: UInt64(self.pollSeconds * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func readNewLines() -> [String] {
        if handle == nil {
            // First call (or after a previous open failed): try to
            // open the file. Returns no lines until it exists.
            handle = try? FileHandle(forReadingFrom: url)
            if handle == nil { return [] }
        }
        guard let handle else { return [] }
        // Read whatever's available. availableData reads non-blocking.
        let data = handle.availableData
        if data.isEmpty { return [] }
        buffer.append(data)
        return drainCompleteLines()
    }

    private func drainCompleteLines() -> [String] {
        var lines: [String] = []
        let newline = UInt8(ascii: "\n")
        while let nlIdx = buffer.firstIndex(of: newline) {
            let lineData = buffer.subdata(in: 0..<nlIdx)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            lines.append(line)
            buffer.removeSubrange(0...nlIdx)
        }
        return lines
    }
}
