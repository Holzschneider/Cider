import Foundation
import CryptoKit

// Downloads files with optional sha256 verification. Designed so the same
// path serves the CLI (terminal progress on stderr) and the GUI (a progress
// callback feeding the splash overlay).
public enum Downloader {
    public struct HTTPError: Swift.Error, CustomStringConvertible {
        public let url: URL
        public let status: Int
        public var description: String { "Download failed (HTTP \(status)) for \(url.absoluteString)" }
    }

    public struct IntegrityError: Swift.Error, CustomStringConvertible {
        public let url: URL
        public let expected: String
        public let actual: String
        public var description: String {
            "Sha256 mismatch for \(url.absoluteString):\n  expected \(expected)\n  got      \(actual)"
        }
    }

    public struct Progress {
        public let bytes: Int64
        public let total: Int64    // 0 if Content-Length absent
    }

    public typealias ProgressHandler = (Progress) -> Void

    // Streaming download into `destination`. If `expectedSha256` is provided,
    // the bytes are hashed during streaming and checked at the end (file is
    // deleted on mismatch). Returns the final hash so the caller can pin it
    // when the user didn't supply one upfront.
    @discardableResult
    public static func file(
        from url: URL,
        to destination: URL,
        expectedSha256: String? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> String {
        Log.info("downloading \(url.absoluteString)")

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(url: url, status: http.statusCode)
        }
        let total = response.expectedContentLength

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let tempURL = fm.temporaryDirectory
            .appendingPathComponent("cider-dl-\(UUID().uuidString)")
        fm.createFile(atPath: tempURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        let reportTerminal = progress == nil && isatty(fileno(stderr)) != 0

        func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            hasher.update(data: buffer)
            written += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            let snapshot = Progress(bytes: written, total: total)
            progress?(snapshot)
            if reportTerminal { reportToTerminal(snapshot) }
        }

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 { try flush() }
        }
        try flush()
        try handle.close()
        if reportTerminal { FileHandle.standardError.write(Data("\n".utf8)) }

        let digest = hasher.finalize()
        let actual = digest.map { String(format: "%02x", $0) }.joined()

        if let expectedSha256, expectedSha256.lowercased() != actual {
            try? fm.removeItem(at: tempURL)
            throw IntegrityError(url: url, expected: expectedSha256.lowercased(), actual: actual)
        }

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)
        return actual
    }

    private static func reportToTerminal(_ p: Progress) {
        let mbRead = Double(p.bytes) / 1_048_576
        let line: String
        if p.total > 0 {
            let mbTotal = Double(p.total) / 1_048_576
            let pct = Int((Double(p.bytes) / Double(p.total)) * 100)
            line = String(format: "\r  %3d%%  %6.1f / %6.1f MB", pct, mbRead, mbTotal)
        } else {
            line = String(format: "\r  %6.1f MB", mbRead)
        }
        FileHandle.standardError.write(Data(line.utf8))
    }
}

// Convenience for hashing local files (used by IntegrityChecker on cached
// engine archives, bundled game payloads, etc.).
public enum SHA256Hasher {
    public static func hash(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
