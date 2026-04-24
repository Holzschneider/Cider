import Foundation
import CiderCore

// Resolves "where am I?" for the running cider binary. The same Mach-O is
// the bundle's CFBundleExecutable when launched by Finder/launchd, and a
// raw command-line tool when invoked from a terminal — but in both cases
// we need to know:
//  - the .app bundle URL (to locate sibling `CiderConfig/`, apply icon, …)
//  - the bundle name (key for AppSupport lookups)
//  - whether the bundle's enclosing directory is writable (Apply needs it)
public struct BundleEnvironment {
    public let bundleURL: URL
    public let bundleName: String

    // Resolved by walking up from the executable. Returns a synthetic env
    // when the binary is invoked outside any .app (e.g. plain `swift run`).
    public static func resolve() -> BundleEnvironment {
        if let url = bundleURLByWalkingUp() {
            return BundleEnvironment(
                bundleURL: url,
                bundleName: url.deletingPathExtension().lastPathComponent
            )
        }
        // Headless / dev-time fallback: pretend the bundle is named "cider"
        // so AppSupport lookups still work for testing.
        return BundleEnvironment(
            bundleURL: URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("cider.app"),
            bundleName: "cider"
        )
    }

    // The directory where sibling-of-Contents overrides (e.g. CiderConfig/)
    // and Finder custom-icon metadata live.
    public var bundleRoot: URL { bundleURL }

    // Schema-v2: in-bundle override is a single cider.json sibling of
    // Contents/, not a CiderConfig/ subdirectory.
    public var inBundleConfigFile: URL {
        bundleURL.appendingPathComponent("cider.json")
    }

    // Bundle-mode application data lives in <bundle>/Application/.
    public var bundleApplicationDir: URL {
        bundleURL.appendingPathComponent("Application", isDirectory: true)
    }

    public var appSupportConfigFile: URL {
        AppSupport.config(forBundleNamed: bundleName)
    }

    public var prefixDir: URL {
        AppSupport.prefix(forBundleNamed: bundleName)
    }

    public var runtimeStatsFile: URL {
        AppSupport.runtimeStats(forBundleNamed: bundleName)
    }

    // True if we can drop a CiderConfig/ folder, set the Finder icon, etc.
    // False when the bundle is in /Applications/ owned by another user.
    public var canSelfModify: Bool {
        let parent = bundleURL.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path)
            && FileManager.default.isWritableFile(atPath: bundleURL.path)
    }

    // Walk up from this binary until we find a directory ending in `.app`
    // whose Contents/MacOS contains us. That's our bundle.
    private static func bundleURLByWalkingUp() -> URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            if dir.pathExtension == "app" {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }
}
