import Foundation
import CiderModels

// Locates and persists `cider.json`. The lookup order on launch is:
//   1. In-bundle override at <bundle>/CiderConfig/cider.json
//   2. AppSupport at ~/Library/Application Support/Cider/Configs/<name>.json
// `Resolved` exposes which source the config came from so callers can know
// where to write changes back to.
public struct ConfigStore {
    public struct Resolved {
        public enum Source: Equatable {
            case inBundleOverride(URL)         // path to the cider.json file
            case appSupport(URL)
        }
        public let config: CiderConfig
        public let source: Source
    }

    public let inBundleConfigFile: URL
    public let appSupportConfigFile: URL

    public init(inBundleConfigFile: URL, appSupportConfigFile: URL) {
        self.inBundleConfigFile = inBundleConfigFile
        self.appSupportConfigFile = appSupportConfigFile
    }

    // Returns the resolved config if either source is present, else nil.
    public func locate() throws -> Resolved? {
        let fm = FileManager.default
        if fm.fileExists(atPath: inBundleConfigFile.path) {
            let cfg = try CiderConfig.read(from: inBundleConfigFile)
            return Resolved(config: cfg, source: .inBundleOverride(inBundleConfigFile))
        }
        if fm.fileExists(atPath: appSupportConfigFile.path) {
            let cfg = try CiderConfig.read(from: appSupportConfigFile)
            return Resolved(config: cfg, source: .appSupport(appSupportConfigFile))
        }
        return nil
    }

    // Writes a new config back to its preferred destination. The default is
    // the in-bundle override if the bundle is writable; otherwise AppSupport.
    public enum WriteTarget {
        case inBundleOverride
        case appSupport
        case explicit(URL)
    }

    @discardableResult
    public func write(_ config: CiderConfig, to target: WriteTarget) throws -> URL {
        let url: URL
        switch target {
        case .inBundleOverride: url = inBundleConfigFile
        case .appSupport: url = appSupportConfigFile
        case .explicit(let u): url = u
        }
        try config.write(to: url)
        return url
    }

    public func remove(from target: WriteTarget) throws {
        let url: URL
        switch target {
        case .inBundleOverride: url = inBundleConfigFile
        case .appSupport: url = appSupportConfigFile
        case .explicit(let u): url = u
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
