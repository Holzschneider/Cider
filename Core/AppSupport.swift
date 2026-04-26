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
    public static var programFiles: URL { root.appendingPathComponent("Program Files", isDirectory: true) }
    public static var runtimeStats: URL { root.appendingPathComponent("RuntimeStats", isDirectory: true) }
    public static var downloadCache: URL {
        root.appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    // Per-bundle scratch space for assets the orchestrator copies in
    // for a configured app — the splash image goes here for Install
    // mode (next to the cider.json in Configs/) so launching the
    // configured bundle still finds the splash even if the user moves
    // / deletes the source folder. Keyed by sanitised bundle name to
    // match Configs/<name>.json.
    public static var assets: URL {
        root.appendingPathComponent("Assets", isDirectory: true)
    }

    public static func assets(forBundleNamed name: String) -> URL {
        assets.appendingPathComponent(name, isDirectory: true)
    }

    public static func prefix(forBundleNamed name: String) -> URL {
        prefixes.appendingPathComponent(name, isDirectory: true)
    }

    // Shared-prefix slot, keyed by a config-derived identity (computed
    // by PrefixIdentity). The same `key` reused across multiple
    // bundles → all bundles share the prefix and hence its windows/
    // state, graphics DLLs, registry, etc.
    public static func prefix(forIdentityKey key: String) -> URL {
        prefixes.appendingPathComponent(key, isDirectory: true)
    }

    public static func config(forBundleNamed name: String) -> URL {
        configs.appendingPathComponent("\(name).json")
    }

    // The directory Install / Link mode uses for a given bundle name. For
    // Install, this contains the copied/extracted source. For Link, this
    // is empty (the cider.json's applicationPath points elsewhere).
    public static func programFiles(forBundleNamed name: String) -> URL {
        programFiles.appendingPathComponent(name, isDirectory: true)
    }

    public static func runtimeStats(forBundleNamed name: String) -> URL {
        runtimeStats.appendingPathComponent("\(name).json")
    }

    public static func ensureExists(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
