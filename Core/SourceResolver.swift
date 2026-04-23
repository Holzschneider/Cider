import Foundation
import CiderModels

// Resolves CiderConfig.Source.{path, inBundle, url} to a concrete on-disk
// directory containing the Windows files. The directory is what
// PrefixInitializer.stagePayload symlinks into drive_c/Program Files/<name>/.
//
// .path     → the URL on disk (no copy, per the spec).
// .inBundle → <bundle>/<inBundleFolder>/ (sibling of Contents/).
// .url      → fetched via IntegrityChecker.ensureCached into
//             AppSupport/Cache/Downloads/<sha>.zip; if it's a zip, lazily
//             extracted into a sibling <sha>/ directory and that path is
//             returned. Patcher behaviour: re-checks the upstream on every
//             call and re-extracts when the upstream changes.
public struct SourceResolver {
    public let bundleURL: URL
    public let bundleName: String

    public init(bundleURL: URL, bundleName: String) {
        self.bundleURL = bundleURL
        self.bundleName = bundleName
    }

    public struct Result {
        public let directory: URL
        public let updatedCacheMeta: CiderRuntimeStats.CachedArtifact?
    }

    public func resolve(
        _ source: CiderConfig.Source,
        priorCache: CiderRuntimeStats.CachedArtifact? = nil,
        progress: Downloader.ProgressHandler? = nil
    ) async throws -> Result {
        switch source.mode {
        case .path:
            guard let path = source.path, !path.isEmpty else {
                throw Error.missingPath
            }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try ensureExistsAndIsDirOrZip(url)
            // If the user pointed at a zip, extract it lazily into AppSupport.
            if url.pathExtension.lowercased() == "zip" {
                let extracted = try extractZipIfNeeded(zip: url)
                return Result(directory: extracted, updatedCacheMeta: nil)
            }
            return Result(directory: url, updatedCacheMeta: nil)

        case .inBundle:
            guard let folder = source.inBundleFolder, !folder.isEmpty else {
                throw Error.missingInBundleFolder
            }
            let url = bundleURL.appendingPathComponent(folder, isDirectory: true)
            try ensureExistsAndIsDirOrZip(url)
            return Result(directory: url, updatedCacheMeta: nil)

        case .url:
            guard let urlString = source.url, let remoteURL = URL(string: urlString) else {
                throw Error.invalidURL(source.url ?? "")
            }
            // Cache local file by sha256 if pinned, otherwise by the URL's
            // last path component.
            let cacheRoot = AppSupport.downloadCache
            try AppSupport.ensureExists(cacheRoot)
            let localFile = cacheRoot.appendingPathComponent(remoteURL.lastPathComponent)

            let updatedMeta = try await IntegrityChecker.ensureCached(
                remoteURL: remoteURL,
                localFile: localFile,
                expectedSha256: source.sha256,
                priorCache: priorCache,
                progress: progress
            )

            // Extract if zip, else hand back the file's parent dir (rare).
            if localFile.pathExtension.lowercased() == "zip" {
                let extracted = try extractZipIfNeeded(zip: localFile)
                return Result(directory: extracted, updatedCacheMeta: updatedMeta)
            }
            return Result(directory: localFile.deletingLastPathComponent(),
                          updatedCacheMeta: updatedMeta)
        }
    }

    // MARK: - Helpers

    private func ensureExistsAndIsDirOrZip(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw Error.notFound(url)
        }
        if !isDir.boolValue && url.pathExtension.lowercased() != "zip" {
            throw Error.notDirectoryOrZip(url)
        }
    }

    // Extracts <zip> into a sibling directory named after the zip's stem,
    // skipping the work if a marker file says it's already extracted for
    // the same byte size (so re-launches are instant). If the zip's
    // top-level entry is a single directory, we return THAT directory
    // (matches the staging convention).
    private func extractZipIfNeeded(zip: URL) throws -> URL {
        let fm = FileManager.default
        let stem = zip.deletingPathExtension().lastPathComponent
        let targetRoot = AppSupport.downloadCache
            .appendingPathComponent("extracted", isDirectory: true)
            .appendingPathComponent(stem, isDirectory: true)
        let marker = targetRoot.appendingPathComponent(".cider-extracted")

        let zipSize = (try? fm.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? 0
        let priorSize = (try? String(contentsOf: marker, encoding: .utf8)).flatMap { Int64($0) }
        if priorSize == zipSize, fm.fileExists(atPath: targetRoot.path) {
            Log.debug("source zip already extracted at \(targetRoot.path)")
            return resolveSingleTopLevelDir(targetRoot)
        }

        if fm.fileExists(atPath: targetRoot.path) {
            try fm.removeItem(at: targetRoot)
        }
        try fm.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        Log.info("extracting source \(zip.lastPathComponent)")
        try Shell.run("/usr/bin/unzip", ["-q", zip.path, "-d", targetRoot.path], captureOutput: true)
        try String(zipSize).write(to: marker, atomically: true, encoding: .utf8)
        return resolveSingleTopLevelDir(targetRoot)
    }

    // Convention from the old PayloadStaging code: if the zip's top level
    // is a single directory, treat that as the source root so the user's
    // exe-relative path doesn't have to start with "Foo/...".
    private func resolveSingleTopLevelDir(_ root: URL) -> URL {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.isDirectoryKey]),
              entries.count == 1,
              let isDir = try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
              isDir
        else {
            return root
        }
        return entries[0]
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case missingPath
        case missingInBundleFolder
        case invalidURL(String)
        case notFound(URL)
        case notDirectoryOrZip(URL)
        public var description: String {
            switch self {
            case .missingPath: return "source.mode is .path but source.path is empty."
            case .missingInBundleFolder: return "source.mode is .inBundle but source.inBundleFolder is empty."
            case .invalidURL(let s): return "source.url is not a valid URL: \(s)"
            case .notFound(let u): return "Source not found: \(u.path)"
            case .notDirectoryOrZip(let u): return "Source must be a directory or .zip file: \(u.path)"
            }
        }
    }
}
