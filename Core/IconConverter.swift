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

    // Converts an input image into an .icns written to `destination`.
    // Accepts any format NSImage can read — PNG / JPEG / Windows .ico /
    // multi-image TIFF / etc. Non-PNG inputs are first flattened to a
    // single PNG (the largest sub-image, for multi-resolution containers
    // like .ico) so the sips + iconutil pipeline gets a clean source.
    public static func convert(image input: URL, destination: URL) throws {
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw Error.inputNotFound(input)
        }

        let pngSource: URL
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-iconset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        if input.pathExtension.lowercased() == "png" {
            pngSource = input
        } else {
            pngSource = workDir.appendingPathComponent("source.png")
            try renderToPNG(input, destination: pngSource)
        }

        let iconset = workDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        for size in sizes {
            let pixels = size.base * size.scale
            let suffix = size.scale == 1 ? "" : "@2x"
            let filename = "icon_\(size.base)x\(size.base)\(suffix).png"
            let output = iconset.appendingPathComponent(filename)
            try Shell.run("/usr/bin/sips", [
                "-z", String(pixels), String(pixels),
                pngSource.path,
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

    // Loads any NSImage-readable input and writes the largest available
    // bitmap representation as a PNG to `destination`. For Windows .ico
    // files this picks the highest-resolution sub-image embedded in the
    // file — usually 256×256 or 64×64 — which is what the icns pipeline
    // wants to scale down from. For single-bitmap formats this just
    // rewrites the bytes as PNG.
    private static func renderToPNG(_ source: URL, destination: URL) throws {
        guard let image = NSImage(contentsOf: source) else {
            throw Error.inputNotLoadable(source)
        }

        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let largestRep = bitmapReps.max {
            ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
        }

        let pngData: Data
        if let rep = largestRep, let data = rep.representation(using: .png, properties: [:]) {
            pngData = data
        } else {
            // Fallback: rasterise the NSImage at its natural size.
            let size = image.size
            guard size.width > 0, size.height > 0 else {
                throw Error.inputNotLoadable(source)
            }
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
            guard let bitmap = rep else { throw Error.inputNotLoadable(source) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw Error.inputNotLoadable(source)
            }
            pngData = data
        }

        try pngData.write(to: destination)
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
        case inputNotLoadable(URL)
        public var description: String {
            switch self {
            case .inputNotFound(let url):
                return "Icon image not found at \(url.path)"
            case .inputNotLoadable(let url):
                return "Could not read icon image at \(url.path) — unsupported format?"
            }
        }
    }
}
