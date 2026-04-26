import Foundation
import CiderModels

// Per-launch ephemeral .app bundle around the engine's wine binary.
// Lets us control what macOS shows in the menu bar's app slot while
// wine is the foreground process — without modifying the shared
// wswine.bundle (which is engine-wide and would race across multiple
// configured bundles).
//
// Layout written to TMPDIR:
//
//   /tmp/cider-wrapper-<sanitised>-<uuid>.app/
//     Contents/
//       Info.plist           ← CFBundleName / CFBundleDisplayName = displayName
//       MacOS/
//         wine               ← symlink to the engine's wine binary
//
// macOS resolves the running binary's containing bundle via the
// Contents/MacOS/ ancestor and reads Info.plist from there. The
// symlink target's @loader_path-relative dylibs (libinotify, libgnutls,
// renderer DLLs) still resolve through the engine's actual on-disk
// location, so wine boots normally.
public enum WineWrapperBundle {
    public struct Built {
        public let bundleURL: URL    // Wrapper.app
        public let wineURL: URL      // Wrapper.app/Contents/MacOS/wine (the symlink)
    }

    public static func make(
        displayName: String,
        engineWineBinary: URL
    ) throws -> Built {
        let safeName = sanitiseForFilename(displayName)
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-wrapper-\(safeName)-\(UUID().uuidString)",
                                    isDirectory: true)
        let bundle = parent.appendingPathComponent("\(safeName).app",
                                                   isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        // Symlink the wine binary so wine's own @loader_path-relative
        // dylib lookups still resolve in the engine cache.
        let wineLink = macOS.appendingPathComponent("wine")
        try FileManager.default.createSymbolicLink(
            at: wineLink, withDestinationURL: engineWineBinary)

        // Write Info.plist with the user-facing name.
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        let plist = makePlist(displayName: displayName, identifier: "app.cider.\(safeName).wrapper")
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)

        return Built(bundleURL: bundle, wineURL: wineLink)
    }

    // Best-effort cleanup. Caller invokes after the wine process exits.
    // Failures (file already gone, permissions, …) are swallowed.
    public static func cleanup(_ built: Built) {
        let parent = built.bundleURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parent)
    }

    // MARK: - Plist generation

    private static func makePlist(displayName: String, identifier: String) -> String {
        // Plain-text plist with the minimum keys macOS needs to treat
        // the directory as a real .app bundle and pull CFBundleName
        // for the menu bar app slot.
        let escaped = xmlEscape(displayName)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key>
            <string>\(escaped)</string>
            <key>CFBundleDisplayName</key>
            <string>\(escaped)</string>
            <key>CFBundleIdentifier</key>
            <string>\(identifier)</string>
            <key>CFBundleExecutable</key>
            <string>wine</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    // Filesystem-safe variant of the displayName for the wrapper's
    // own folder + .app filename. Strips path / shell metacharacters,
    // collapses whitespace to a dash, falls back to "App" if the user
    // somehow typed a name that strips down to nothing.
    private static func sanitiseForFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\"?*<>|\t\n\r ")
        let mapped = raw.unicodeScalars
            .map { invalid.contains($0) ? "-" : String($0) }.joined()
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let collapsed = trimmed.split(whereSeparator: { $0 == "-" }).joined(separator: "-")
        let bounded = String(collapsed.prefix(80))
        return bounded.isEmpty ? "App" : bounded
    }
}
