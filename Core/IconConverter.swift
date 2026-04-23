import Foundation
import AppKit

public enum IconConverter {
    public static let sizes: [(base: Int, scale: Int)] = [
        (16, 1), (16, 2),
        (32, 1), (32, 2),
        (128, 1), (128, 2),
        (256, 1), (256, 2),
        (512, 1), (512, 2)
    ]

    // Converts `png` into an .icns written to `destination` using macOS's
    // built-in `sips` and `iconutil`.
    public static func convert(png: URL, destination: URL) throws {
        guard FileManager.default.fileExists(atPath: png.path) else {
            throw Error.inputNotFound(png)
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-iconset-\(UUID().uuidString)", isDirectory: true)
        let iconset = workDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        for size in sizes {
            let pixels = size.base * size.scale
            let suffix = size.scale == 1 ? "" : "@2x"
            let filename = "icon_\(size.base)x\(size.base)\(suffix).png"
            let output = iconset.appendingPathComponent(filename)
            try Shell.run("/usr/bin/sips", [
                "-z", String(pixels), String(pixels),
                png.path,
                "--out", output.path
            ], captureOutput: true)
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Shell.run("/usr/bin/iconutil", [
            "-c", "icns",
            iconset.path,
            "-o", destination.path
        ], captureOutput: true)
    }

    // Apply an .icns as the Finder custom icon on a target file/folder
    // (typically a `.app` bundle). This writes the `Icon\r` file + sets the
    // `com.apple.FinderInfo` `kHasCustomIcon` flag — both **outside** any
    // signed `Contents/`, so it does NOT invalidate codesign / notarization.
    @discardableResult
    public static func applyAsCustomIcon(at icnsURL: URL, to target: URL) -> Bool {
        guard let image = NSImage(contentsOf: icnsURL) else {
            Log.warn("could not load icon image \(icnsURL.path)")
            return false
        }
        return NSWorkspace.shared.setIcon(image, forFile: target.path, options: [])
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case inputNotFound(URL)
        public var description: String {
            switch self {
            case .inputNotFound(let url):
                return "Icon PNG not found at \(url.path)"
            }
        }
    }
}
