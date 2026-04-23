import Foundation

// Resolves the on-disk locations of Cider's shared user-level state.
// Replaces the old CachePaths / Cider-Caches story: under the new GUI
// architecture, engines/templates/prefixes/configs/stats all live here so
// multiple .app bundles can share them.
public enum AppSupport {
    public static var root: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Cider", isDirectory: true)
    }

    public static var engines: URL { root.appendingPathComponent("Engines", isDirectory: true) }
    public static var templates: URL { root.appendingPathComponent("Templates", isDirectory: true) }
    public static var prefixes: URL { root.appendingPathComponent("Prefixes", isDirectory: true) }
    public static var configs: URL { root.appendingPathComponent("Configs", isDirectory: true) }
    public static var runtimeStats: URL { root.appendingPathComponent("RuntimeStats", isDirectory: true) }
    public static var downloadCache: URL {
        root.appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    public static func prefix(forBundleNamed name: String) -> URL {
        prefixes.appendingPathComponent(name, isDirectory: true)
    }

    public static func config(forBundleNamed name: String) -> URL {
        configs.appendingPathComponent("\(name).json")
    }

    public static func runtimeStats(forBundleNamed name: String) -> URL {
        runtimeStats.appendingPathComponent("\(name).json")
    }

    public static func ensureExists(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
