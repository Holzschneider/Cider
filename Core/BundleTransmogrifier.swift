import Foundation
import CiderModels

// Turns a vanilla `Cider.app` into a configured `<DisplayName>.app` by:
//   1. Renaming (Apply) or copying (Clone & Apply) the bundle.
//   2. Removing any stale CiderConfig/ override so the new config wins.
//   3. Persisting cider.json to the chosen storage:
//        - .appSupport         → ~/Library/Application Support/Cider/Configs/<bundle-name>.json
//        - .inBundleOverride   → <bundle>/CiderConfig/cider.json
//        - .sourceFolder(URL)  → <sourceDir>/cider.json (lives next to the user's game files)
//   4. Applying a Finder custom icon (NSWorkspace.setIcon, outside Contents/).
//
// Touches **only** sibling-of-Contents files (CiderConfig folder + Finder
// icon metadata + Apple-Double resource fork) and the bundle name itself.
// Contents/ stays byte-identical, so the codesign seal and notarization
// ticket on the original Cider.app survive intact.
public struct BundleTransmogrifier {
    public enum Mode {
        case applyInPlace
        case cloneTo(URL)
    }

    public enum ConfigStorage: Equatable {
        case appSupport
        case inBundleOverride
        case sourceFolder(URL)
    }

    public struct Result {
        public let finalBundleURL: URL
        public let configWrittenTo: URL
        public let iconApplied: Bool
    }

    public let currentBundle: URL
    public let config: CiderConfig
    public let icnsURL: URL?            // pre-converted .icns, applied via NSWorkspace.setIcon
    public let storage: ConfigStorage
    public let allowOverwrite: Bool

    public init(
        currentBundle: URL,
        config: CiderConfig,
        icnsURL: URL? = nil,
        storage: ConfigStorage = .appSupport,
        allowOverwrite: Bool = false
    ) {
        self.currentBundle = currentBundle
        self.config = config
        self.icnsURL = icnsURL
        self.storage = storage
        self.allowOverwrite = allowOverwrite
    }

    @discardableResult
    public func transmogrify(mode: Mode) throws -> Result {
        let targetName = Self.sanitiseBundleName(config.displayName)
        guard !targetName.isEmpty else {
            throw Error.emptyDisplayName
        }
        let resultBundle: URL

        switch mode {
        case .applyInPlace:
            let parent = currentBundle.deletingLastPathComponent()
            let destination = parent.appendingPathComponent("\(targetName).app", isDirectory: true)
            if destination != currentBundle {
                try ensureClearPath(destination)
                try FileManager.default.moveItem(at: currentBundle, to: destination)
            }
            resultBundle = destination

        case .cloneTo(let dest):
            try ensureClearPath(dest)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // cp -a preserves symlinks + extended attributes (the codesign
            // seal lives in xattrs on macOS).
            try Shell.run("/bin/cp", ["-a", currentBundle.path, dest.path], captureOutput: true)
            resultBundle = dest
        }

        // Wipe any stale in-bundle override that came along on a clone, so
        // we don't accidentally keep loading the source bundle's config.
        let staleOverride = resultBundle.appendingPathComponent("CiderConfig", isDirectory: true)
        if storage != .inBundleOverride,
           FileManager.default.fileExists(atPath: staleOverride.path) {
            try FileManager.default.removeItem(at: staleOverride)
        }

        // Persist config.
        let configURL = try writeConfig(near: resultBundle, named: targetName)

        // Apply Finder custom icon (outside Contents/, signature-safe).
        var iconApplied = false
        if let icnsURL {
            iconApplied = IconConverter.applyAsCustomIcon(at: icnsURL, to: resultBundle)
            if !iconApplied {
                Log.warn("custom-icon application failed for \(resultBundle.path)")
            }
        }

        Log.info("transmogrified \(currentBundle.lastPathComponent) → \(resultBundle.lastPathComponent)")
        return Result(finalBundleURL: resultBundle, configWrittenTo: configURL, iconApplied: iconApplied)
    }

    // MARK: - Helpers

    private func ensureClearPath(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            if allowOverwrite {
                try FileManager.default.removeItem(at: url)
            } else {
                throw Error.targetExists(url)
            }
        }
    }

    private func writeConfig(near bundle: URL, named bundleName: String) throws -> URL {
        let url: URL
        switch storage {
        case .appSupport:
            url = AppSupport.config(forBundleNamed: bundleName)
        case .inBundleOverride:
            url = bundle
                .appendingPathComponent("CiderConfig", isDirectory: true)
                .appendingPathComponent("cider.json")
        case .sourceFolder(let dir):
            url = dir.appendingPathComponent("cider.json")
        }
        try config.write(to: url)
        return url
    }

    // Display name → filesystem-safe bundle name. Strips characters that
    // confuse Finder / shell / codesign, collapses internal whitespace,
    // and clamps length.
    public static func sanitiseBundleName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\"?*<>|")
        var s = raw.unicodeScalars
            .map { invalid.contains($0) ? Character(" ") : Character($0) }
            .reduce(into: "") { $0.append($1) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(120))
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case emptyDisplayName
        case targetExists(URL)
        public var description: String {
            switch self {
            case .emptyDisplayName:
                return "Cannot transmogrify: cider.json's displayName is empty."
            case .targetExists(let url):
                return "Target bundle already exists at \(url.path). Pass --force / allowOverwrite to replace."
            }
        }
    }
}
