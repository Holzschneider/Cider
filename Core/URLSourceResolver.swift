import Foundation
import CiderModels

// Phase 5: when a user drops / pastes a remote URL into the drop zone, we
// may not yet know whether that URL returns a zip (the app's data) or a
// cider.json (a distribution manifest that in turn references a zip).
//
// `URLSourceResolver.resolve` HEADs the URL, looks at Content-Type and
// falls back to URL-extension heuristics if the server doesn't set the
// MIME type clearly. It then fetches the small JSON (if applicable) or
// downloads the zip into AppSupport/Cache/Downloads.
//
// Used by:
//   - DropZoneViewModel (at drop time, to pre-fill MoreDialog with the
//     fetched config)
//   - Installer (at install time, to resolve a `.url` source into a local
//     zip path it can extract).
public enum URLSourceResolver {

    // Outcome of resolving a dropped URL. Callers route to the zip-extract
    // path with the cached local URL; or use the fetched CiderConfig to
    // pre-fill MoreDialog and then recurse via `dataURL`.
    public enum Resolved {
        case zip(localURL: URL)
        case ciderJSON(config: CiderConfig, dataURL: URL?, originURL: URL)
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case badStatus(URL, Int)
        case undecidableContent(URL, contentType: String?)
        case malformedConfig(URL, underlying: Swift.Error)
        case ciderJSONWithoutDistributionURL(URL)

        public var description: String {
            switch self {
            case .badStatus(let url, let code):
                return "HTTP \(code) for \(url.absoluteString)"
            case .undecidableContent(let url, let ct):
                return "Could not decide if \(url.absoluteString) is a zip or cider.json (Content-Type: \(ct ?? "—"))."
            case .malformedConfig(let url, let err):
                return "Malformed cider.json at \(url.absoluteString): \(err)"
            case .ciderJSONWithoutDistributionURL(let url):
                return "cider.json at \(url.absoluteString) has no distributionURL — nowhere to get the app data from."
            }
        }
    }

    // Public entry point. `progress` is forwarded to the zip download
    // case; JSON fetches are small enough to skip progress reporting.
    public static func resolve(
        url: URL,
        progress: Downloader.ProgressHandler? = nil
    ) async throws -> Resolved {
        let kind = try await detectKind(of: url)
        switch kind {
        case .zip:
            let local = try await downloadZipToCache(url, progress: progress)
            return .zip(localURL: local)
        case .ciderJSON:
            let (config, dataURL) = try await fetchCiderJSON(url)
            return .ciderJSON(config: config, dataURL: dataURL, originURL: url)
        }
    }

    // MARK: - Kind detection

    private enum Kind { case zip, ciderJSON }

    // Best-effort Content-Type discovery:
    //   1. HEAD the URL and check Content-Type.
    //   2. If the server doesn't help (missing or generic octet-stream),
    //      fall back to the URL's path extension.
    private static func detectKind(of url: URL) async throws -> Kind {
        let contentType = try await headContentType(url)
        if let kind = kind(fromContentType: contentType) {
            return kind
        }
        if let kind = kind(fromExtension: url.pathExtension) {
            return kind
        }
        throw Error.undecidableContent(url, contentType: contentType)
    }

    private static func kind(fromContentType raw: String?) -> Kind? {
        guard let raw else { return nil }
        // Strip any `; charset=…` suffix and lowercase.
        let mime = raw.split(separator: ";").first.map { String($0) } ?? raw
        let m = mime.trimmingCharacters(in: .whitespaces).lowercased()
        if m.contains("json") {
            return .ciderJSON
        }
        if m == "application/zip" || m == "application/x-zip-compressed" {
            return .zip
        }
        return nil
    }

    private static func kind(fromExtension ext: String) -> Kind? {
        switch ext.lowercased() {
        case "json": return .ciderJSON
        case "zip":  return .zip
        default:     return nil
        }
    }

    private static func headContentType(_ url: URL) async throws -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        // Some hosts (e.g. GitHub Releases) refuse HEAD on the final asset
        // URL; treat network errors here as "no Content-Type" rather than
        // failing the whole resolve — the extension fallback will try.
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if !(200..<400).contains(http.statusCode) {
                return nil
            }
            return http.value(forHTTPHeaderField: "Content-Type")
        } catch {
            return nil
        }
    }

    // MARK: - JSON fetch

    private static func fetchCiderJSON(_ url: URL) async throws -> (CiderConfig, URL?) {
        Log.info("fetching cider.json from \(url.absoluteString)")
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Error.badStatus(url, http.statusCode)
        }
        let config: CiderConfig
        do {
            config = try CiderConfig.decode(data)
        } catch {
            throw Error.malformedConfig(url, underlying: error)
        }
        let dataURL = config.distributionURL.flatMap { URL(string: $0) }
        return (config, dataURL)
    }

    // MARK: - Zip download

    private static func downloadZipToCache(
        _ url: URL,
        progress: Downloader.ProgressHandler?
    ) async throws -> URL {
        let cache = AppSupport.downloadCache
        try AppSupport.ensureExists(cache)
        // Deterministic filename based on the URL (so repeated downloads
        // of the same URL hit the same path; Phase 6's patcher can wipe it
        // when the upstream sha256 changes).
        let name = stableFilename(for: url)
        let destination = cache.appendingPathComponent(name)
        _ = try await Downloader.file(from: url, to: destination, progress: progress)
        return destination
    }

    private static func stableFilename(for url: URL) -> String {
        // Keep the upstream extension (`.zip`) so unzip picks the right
        // format; prefix with a short hash of the full URL for uniqueness.
        let absolute = url.absoluteString
        var hasher = Hasher()
        hasher.combine(absolute)
        let h = UInt(bitPattern: hasher.finalize())
        let prefix = String(h, radix: 16).prefix(12)
        let ext = url.pathExtension.isEmpty ? "zip" : url.pathExtension
        return "\(prefix).\(ext)"
    }
}
