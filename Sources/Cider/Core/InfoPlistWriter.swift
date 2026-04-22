import Foundation

enum InfoPlistWriter {
    struct Options {
        let bundleName: String
        let bundleIdentifier: String
        let bundleVersion: String
        let iconFileName: String?
        let minimumSystemVersion: String
        let executableName: String
        let category: String
    }

    static func write(_ options: Options, to destination: URL) throws {
        var plist: [String: Any] = [
            "CFBundleExecutable": options.executableName,
            "CFBundleIdentifier": options.bundleIdentifier,
            "CFBundleName": options.bundleName,
            "CFBundleDisplayName": options.bundleName,
            "CFBundlePackageType": "APPL",
            "CFBundleSignature": "????",
            "CFBundleVersion": options.bundleVersion,
            "CFBundleShortVersionString": options.bundleVersion,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "en",
            "LSMinimumSystemVersion": options.minimumSystemVersion,
            "LSApplicationCategoryType": options.category,
            "NSHighResolutionCapable": true,
            "NSSupportsAutomaticGraphicsSwitching": true
        ]
        if let icon = options.iconFileName {
            plist["CFBundleIconFile"] = icon
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination)
    }

    static func writePkgInfo(to destination: URL) throws {
        try Data("APPL????".utf8).write(to: destination)
    }
}
