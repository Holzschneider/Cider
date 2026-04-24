import Foundation
import CiderModels

// What the user dropped / pasted onto the drop zone. The Installer turns
// this into an on-disk application directory using one of the InstallMode
// strategies. Phase 5 adds `.ciderJSON(URL)` for the remote-cider.json
// indirection (drop a URL → fetch JSON → recurse with its install URL).
public enum SourceAcquisition: Equatable {
    case folder(URL)            // local directory
    case zip(URL)               // local .zip file
    case url(URL)               // remote URL pointing at a zip (or, Phase 5, a cider.json)

    // The local on-disk URL, if available right now (folder or local zip).
    // Returns nil for remote URLs since they need to be fetched first.
    public var localURL: URL? {
        switch self {
        case .folder(let url), .zip(let url): return url
        case .url: return nil
        }
    }

    // Last path component, used to derive a default display name and the
    // sub-directory name when materialising the source under Install /
    // Bundle modes.
    public var sourceName: String {
        switch self {
        case .folder(let url):
            return url.lastPathComponent
        case .zip(let url), .url(let url):
            return url.deletingPathExtension().lastPathComponent
        }
    }
}
