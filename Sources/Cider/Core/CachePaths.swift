import Foundation

enum CachePaths {
    static var root: URL {
        let fm = FileManager.default
        let library = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return library.appendingPathComponent("Cider", isDirectory: true)
    }

    static var engines: URL {
        root.appendingPathComponent("Engines", isDirectory: true)
    }

    static var graphicsDrivers: URL {
        root.appendingPathComponent("GraphicsDrivers", isDirectory: true)
    }

    static func ensureExists(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
