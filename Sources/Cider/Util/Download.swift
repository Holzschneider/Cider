import Foundation

enum Download {
    struct Error: Swift.Error, CustomStringConvertible {
        let url: URL
        let status: Int
        var description: String { "Download failed (HTTP \(status)) for \(url.absoluteString)" }
    }

    // Downloads `url` into `destination`, overwriting if it already exists.
    // Reports progress to stderr on a TTY.
    static func file(from url: URL, to destination: URL) async throws {
        Log.info("downloading \(url.absoluteString)")
        let (tempURL, response) = try await URLSession.shared.download(from: url) { bytes, total in
            reportProgress(bytes: bytes, total: total)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw Error(url: url, status: status)
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tempURL, to: destination)
        if isatty(fileno(stderr)) != 0 {
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }

    private static func reportProgress(bytes: Int64, total: Int64) {
        guard isatty(fileno(stderr)) != 0 else { return }
        let mbRead = Double(bytes) / 1_048_576
        if total > 0 {
            let mbTotal = Double(total) / 1_048_576
            let pct = Int((Double(bytes) / Double(total)) * 100)
            let line = String(format: "\r  %3d%%  %6.1f / %6.1f MB", pct, mbRead, mbTotal)
            FileHandle.standardError.write(Data(line.utf8))
        } else {
            let line = String(format: "\r  %6.1f MB", mbRead)
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}

// URLSession.download with a progress callback (Swift 5.9-compatible, no SwiftNIO).
private extension URLSession {
    func download(
        from url: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        let (bytes, response) = try await self.bytes(from: url)
        let total = response.expectedContentLength

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(written, total)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            progress(written, total)
        }
        try handle.close()

        return (tempURL, response)
    }
}
