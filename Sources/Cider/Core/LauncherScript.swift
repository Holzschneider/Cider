import Foundation

enum LauncherScript {
    struct Substitutions {
        let bundleId: String
        let wineBinaryRelativePath: String  // path under Resources/engine/, e.g. "wswine.bundle/bin/wine"
        let winExePath: String              // e.g. "C:\\Program Files\\My Game\\Game.exe"
        let exeArgs: [String]
        let dllOverrides: String
        let extraEnv: [String: String]
    }

    // Renders the launcher shell script using the bundled template and writes
    // it to `destination` with executable permissions.
    static func render(_ subs: Substitutions, to destination: URL) throws {
        let templateURL = Bundle.module.url(
            forResource: "launcher.sh.template",
            withExtension: nil
        )
        guard let templateURL else { throw Error.templateMissing }
        var template = try String(contentsOf: templateURL, encoding: .utf8)

        template = template.replacingOccurrences(of: "@@BUNDLE_ID@@", with: subs.bundleId)
        template = template.replacingOccurrences(
            of: "@@WINE_BIN_REL@@",
            with: escape(subs.wineBinaryRelativePath)
        )
        template = template.replacingOccurrences(
            of: "@@WIN_EXE_PATH@@",
            with: escape(subs.winExePath)
        )
        template = template.replacingOccurrences(
            of: "@@EXE_ARGS@@",
            with: subs.exeArgs.map { "\"\(escape($0))\"" }.joined(separator: " ")
        )
        template = template.replacingOccurrences(
            of: "@@WINEDLLOVERRIDES@@",
            with: "export WINEDLLOVERRIDES=\"\(subs.dllOverrides)\""
        )
        // dlopen on macOS does NOT use the wine binary's LC_RPATH; it consults
        // DYLD_*_LIBRARY_PATH. Wine's font driver, vulkan loader, etc. all
        // dlopen support dylibs by leaf name, so we must point those env vars
        // at the directory where Cider deposits the wrapper-template Frameworks
        // (sibling of wswine.bundle), as well as wine's own lib dir.
        template = template.replacingOccurrences(
            of: "@@DYLD_FALLBACK_LIBRARY_PATH@@",
            with: """
            export DYLD_FALLBACK_LIBRARY_PATH="$DIR/engine:$DIR/engine/moltenvkcx:$(dirname "$(dirname "$WINE_BIN")")/lib:${DYLD_FALLBACK_LIBRARY_PATH:-/usr/local/lib:/usr/lib}"
            """
        )

        let extra = subs.extraEnv
            .sorted(by: { $0.key < $1.key })
            .map { "export \($0.key)=\"\(escape($0.value))\"" }
            .joined(separator: "\n")
        template = template.replacingOccurrences(of: "@@EXTRA_ENV@@", with: extra)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try template.write(to: destination, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: destination.path
        )
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case templateMissing
        var description: String {
            "launcher.sh.template missing from the Cider bundle resources."
        }
    }
}
