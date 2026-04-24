import Foundation

// Resolves a "repository URL" to a list of engines. Today only GitHub
// release pages are supported (e.g. https://github.com/Sikarugir-App/
// Engines/releases/tag/v1.0); the format the URL bar takes is whatever
// you'd paste from a browser. The fetcher translates that to the GitHub
// API endpoint and parses the assets.
enum EngineCatalog {
    struct Entry: Hashable, Identifiable {
        let name: String                  // "WS12WineCX24.0.7_7"
        let downloadURL: String           // full URL to the .tar.xz
        var id: String { name }
    }

    static let defaultRepositoryPageURL =
        "https://github.com/Sikarugir-App/Engines/releases/tag/v1.0"

    enum FetchError: Swift.Error, CustomStringConvertible {
        case unsupportedRepositoryURL(String)
        case http(Int)
        case decodingFailed
        case noAssets
        var description: String {
            switch self {
            case .unsupportedRepositoryURL(let s):
                return "Don't know how to enumerate engines from: \(s). Paste a GitHub release page URL (e.g. .../releases/tag/v1.0)."
            case .http(let code):
                return "GitHub API returned HTTP \(code)."
            case .decodingFailed:
                return "Could not decode the GitHub API response."
            case .noAssets:
                return "Repository has no .tar.xz assets."
            }
        }
    }

    // Fetch the engine catalogue from a "https://github.com/<owner>/<repo>/
    // releases/tag/<tag>" URL. Returns engines sorted with the newest
    // first (newest WineCX, then newest other variants).
    static func fetch(repositoryPageURL pageURL: String) async throws -> [Entry] {
        guard let api = githubAPI(forReleasePageURL: pageURL) else {
            throw FetchError.unsupportedRepositoryURL(pageURL)
        }
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.http(http.statusCode)
        }

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        struct Release: Decodable {
            let assets: [Asset]
        }

        let decoder = JSONDecoder()
        guard let release = try? decoder.decode(Release.self, from: data) else {
            throw FetchError.decodingFailed
        }
        let entries = release.assets
            .filter { $0.name.lowercased().hasSuffix(".tar.xz") }
            .map { asset -> Entry in
                let name = String(asset.name.dropLast(".tar.xz".count))
                return Entry(name: name, downloadURL: asset.browser_download_url)
            }
        if entries.isEmpty {
            throw FetchError.noAssets
        }
        return entries.sorted(by: orderNewestFirst)
    }

    // Pick the newest WineCX engine, or the first entry if none.
    static func suggestedDefault(from entries: [Entry]) -> Entry? {
        entries.first(where: { $0.name.contains("WineCX") }) ?? entries.first
    }

    // MARK: - URL translation

    // Accepts: https://github.com/<owner>/<repo>/releases/tag/<tag>
    //      or: https://github.com/<owner>/<repo>/releases/tags/<tag>
    // Returns: https://api.github.com/repos/<owner>/<repo>/releases/tags/<tag>
    static func githubAPI(forReleasePageURL raw: String) -> URL? {
        guard var components = URLComponents(string: raw),
              components.host?.lowercased() == "github.com" else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        // Expected: <owner>/<repo>/releases/tag(s)/<tag>
        guard parts.count >= 5,
              parts[2].lowercased() == "releases",
              parts[3].lowercased() == "tag" || parts[3].lowercased() == "tags"
        else { return nil }
        let owner = parts[0], repo = parts[1], tag = parts[4]
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repo)/releases/tags/\(tag)"
        components.fragment = nil
        components.query = nil
        return components.url
    }

    // Sort newest first using Foundation's numeric string comparison —
    // "WS12WineCX24.0.7_7" > "WS12WineCX24.0.7_6" > "WS12WineCX23.7.1".
    private static func orderNewestFirst(_ a: Entry, _ b: Entry) -> Bool {
        a.name.compare(b.name, options: .numeric) == .orderedDescending
    }
}
