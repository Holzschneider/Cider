import Foundation
import CiderModels

// Decides whether a cached artifact (engine archive, template, slim-mode
// source bundle) needs to be re-downloaded.
//
// Decision priority:
//   1. Local file missing                            → redownload
//   2. expectedSha256 supplied AND mismatches local  → redownload
//   3. expectedSha256 supplied AND matches local     → useExisting
//   4. Prior cached metadata exists, do a HEAD:
//        - ETag changed                              → redownload
//        - Last-Modified changed                     → redownload
//        - Content-Length differs from prior bytes   → redownload
//        - Network error                             → useExisting (fail-open)
//   5. Otherwise (no sha, no prior meta)             → useExisting
//
// `ensureCached` wraps the decision around an actual `Downloader.file(...)`
// call when needed and returns updated metadata for RuntimeStats.
public enum IntegrityChecker {
    public enum Decision: Equatable {
        case useExisting
        case redownload(reason: String)
    }

    // Pure decision (no download). Async because of the optional HEAD.
    public static func decide(
        localFile: URL,
        expectedSha256: String?,
        priorCache: CiderRuntimeStats.CachedArtifact?,
        remoteURL: URL
    ) async -> Decision {
        let fm = FileManager.default
        guard fm.fileExists(atPath: localFile.path) else {
            return .redownload(reason: "no local copy")
        }

        if let expected = expectedSha256?.lowercased() {
            do {
                let actual = try SHA256Hasher.hash(file: localFile)
                if actual.lowercased() != expected {
                    return .redownload(reason: "sha256 mismatch (expected \(expected.prefix(8))…)")
                }
                return .useExisting
            } catch {
                return .redownload(reason: "could not hash local file: \(error)")
            }
        }

        guard let priorCache else {
            // No expected sha and no prior cache: trust the local file.
            return .useExisting
        }

        do {
            let head = try await headRequest(url: remoteURL)
            if let priorETag = priorCache.etag, let etag = head.etag, priorETag != etag {
                return .redownload(reason: "ETag changed")
            }
            if let priorMod = priorCache.lastModified,
               let lastMod = head.lastModified,
               priorMod != lastMod {
                return .redownload(reason: "Last-Modified changed")
            }
            if let length = head.contentLength, length != priorCache.bytes {
                return .redownload(reason: "Content-Length \(priorCache.bytes) → \(length)")
            }
            return .useExisting
        } catch {
            // Network unreachable: don't block the user; trust local copy.
            Log.debug("HEAD failed, trusting local copy: \(error)")
            return .useExisting
        }
    }

    // Decide + (re)download as needed. Returns updated metadata to persist
    // in RuntimeStats. Caller must already have a local file URL chosen
    // and a remote URL to fetch from.
    @discardableResult
    public static func ensureCached(
        remoteURL: URL,
        localFile: URL,
        expectedSha256: String?,
        priorCache: CiderRuntimeStats.CachedArtifact?,
        progress: Downloader.ProgressHandler? = nil
    ) async throws -> CiderRuntimeStats.CachedArtifact {
        let decision = await decide(
            localFile: localFile,
            expectedSha256: expectedSha256,
            priorCache: priorCache,
            remoteURL: remoteURL
        )
        switch decision {
        case .useExisting:
            if let priorCache { return priorCache }
            // No prior cache: hash local and pin (so next launch's HEAD
            // check has a baseline).
            let sha = try SHA256Hasher.hash(file: localFile)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? Int64) ?? 0
            return CiderRuntimeStats.CachedArtifact(sha256: sha, bytes: bytes)
        case .redownload(let reason):
            Log.info("redownloading \(remoteURL.lastPathComponent): \(reason)")
            // Capture HEAD metadata before the download so we don't have
            // to do another round-trip just for ETag/Last-Modified.
            let head = try? await headRequest(url: remoteURL)
            let sha = try await Downloader.file(
                from: remoteURL,
                to: localFile,
                expectedSha256: expectedSha256,
                progress: progress
            )
            let bytes = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? Int64) ?? 0
            return CiderRuntimeStats.CachedArtifact(
                sha256: sha,
                etag: head?.etag,
                lastModified: head?.lastModified,
                bytes: bytes
            )
        }
    }

    // MARK: - HEAD helper

    struct HeadResult {
        let etag: String?
        let lastModified: String?
        let contentLength: Int64?
    }

    static func headRequest(url: URL) async throws -> HeadResult {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if !(200..<400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let length: Int64?
        if let s = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(s) {
            length = n
        } else if http.expectedContentLength > 0 {
            length = http.expectedContentLength
        } else {
            length = nil
        }
        return HeadResult(
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            contentLength: length
        )
    }
}
