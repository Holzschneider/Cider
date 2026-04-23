import ArgumentParser
import Foundation
import TOMLKit

struct BundleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle",
        abstract: "Create a .app bundle from a Windows app."
    )

    @Option(name: .long, help: "Path to a .zip or a directory containing the Windows app.")
    var input: String?

    @Option(name: .long, help: "Path of the .exe relative to the input root.")
    var exe: String?

    @Option(name: .long, help: "Arguments forwarded to the .exe at launch.")
    var args: String?

    @Option(name: .long, help: "Wine engine to use, e.g. WS12WineCX24.0.7_7.")
    var engine: String?

    @Option(name: .long, help: "Graphics driver: dxmt, d3dmetal, dxvk.")
    var graphics: GraphicsDriverKind?

    @Option(name: .long, help: "PNG icon to convert and embed.")
    var icon: String?

    @Option(name: .long, help: "Display name; defaults to the exe stem.")
    var name: String?

    @Option(name: .customLong("bundle-id"), help: "Bundle identifier (reverse-DNS).")
    var bundleId: String?

    @Option(name: .long, help: "Output path for the produced .app.")
    var output: String?

    @Option(name: .customLong("with-config"), help: "Read defaults from a TOML config file.")
    var withConfig: String?

    @Option(name: .customLong("sign-identity"),
            help: "Codesign identity (e.g. \"Developer ID Application: Name\"). Defaults to ad-hoc.")
    var signIdentity: String?

    @Flag(name: .customLong("no-prefix-init"), help: "Skip wineboot prefix initialisation.")
    var noPrefixInit: Bool = false

    @Flag(name: .long, help: "Wrap the exe in cmd.exe /c run.bat with stdout redirected to all.txt. Use for console / TUI apps that crash without a real Windows console.")
    var console: Bool = false

    @Flag(name: .long, help: "With --console: prefix the exe with `start \"\" /B /WAIT` so it inherits cmd's text-mode console instead of allocating its own graphical conhost window. Suppresses the patcher's pop-up Windows terminal but may break apps whose child processes need their own window (wine propagates /B's CREATE_NO_WINDOW).")
    var inheritConsole: Bool = false

    @OptionGroup var verbosity: VerbosityOptions

    func run() async throws {
        verbosity.apply()
        let cfg = try resolveConfig()
        let builder = BundleBuilder(config: cfg)
        let bundleURL = try await builder.build()
        print(bundleURL.path)
    }

    private func resolveConfig() throws -> BundleConfig {
        var fileCfg: BundleConfig.File?
        if let withConfig {
            let url = URL(fileURLWithPath: withConfig)
            let contents = try String(contentsOf: url, encoding: .utf8)
            fileCfg = try TOMLDecoder().decode(BundleConfig.File.self, from: contents)
        }

        guard let inputRaw = input ?? fileCfg?.bundle.input else {
            throw ValidationError("Missing --input.")
        }
        guard let exeRaw = exe ?? fileCfg?.bundle.exe else {
            throw ValidationError("Missing --exe.")
        }
        guard let engineRaw = engine ?? fileCfg?.engine.name else {
            throw ValidationError("Missing --engine.")
        }

        let engineName = try EngineName(engineRaw)

        let graphicsKind: GraphicsDriverKind
        if let g = graphics {
            graphicsKind = g
        } else if let s = fileCfg?.engine.graphics, let g = GraphicsDriverKind(rawValue: s) {
            graphicsKind = g
        } else {
            graphicsKind = GraphicsDriverKind.defaultForThisMachine
        }

        let inputURL = URL(fileURLWithPath: inputRaw).absoluteURL
        let displayName = name ?? fileCfg?.bundle.name ?? (exeRaw as NSString).lastPathComponent
            .replacingOccurrences(of: ".exe", with: "")
        let resolvedBundleId = bundleId ?? fileCfg?.bundle.bundle_id ?? "com.cider.\(slug(displayName))"
        let outputPath = output ?? fileCfg?.bundle.output ?? "./\(displayName).app"
        let outputURL = URL(fileURLWithPath: outputPath).absoluteURL

        let iconRaw = icon ?? fileCfg?.icon?.path
        let iconURL = iconRaw.map { URL(fileURLWithPath: $0).absoluteURL }

        let argString = args ?? fileCfg?.launch?.args ?? ""
        let argList = argString.isEmpty ? [] : try tokenise(argString)

        let sign: BundleConfig.SignIdentity = signIdentity.map { .developerID($0) } ?? .adHoc

        return BundleConfig(
            input: inputURL,
            exe: exeRaw,
            args: argList,
            engine: engineName,
            graphics: graphicsKind,
            icon: iconURL,
            name: displayName,
            bundleId: resolvedBundleId,
            output: outputURL,
            preInitPrefix: !noPrefixInit,
            console: console,
            inheritConsole: inheritConsole,
            signIdentity: sign
        )
    }
}

private func slug(_ s: String) -> String {
    let lowered = s.lowercased()
    let filtered = lowered.unicodeScalars.map { scalar -> Character in
        if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
        return "-"
    }
    return String(filtered)
        .split(separator: "-", omittingEmptySubsequences: true)
        .joined(separator: "-")
}

// Minimal POSIX-ish tokenisation supporting single- and double-quoted segments.
private func tokenise(_ input: String) throws -> [String] {
    var tokens: [String] = []
    var current = ""
    var quote: Character? = nil
    var escape = false

    for ch in input {
        if escape {
            current.append(ch); escape = false; continue
        }
        if ch == "\\" { escape = true; continue }
        if let q = quote {
            if ch == q { quote = nil } else { current.append(ch) }
            continue
        }
        if ch == "\"" || ch == "'" { quote = ch; continue }
        if ch.isWhitespace {
            if !current.isEmpty { tokens.append(current); current = "" }
            continue
        }
        current.append(ch)
    }
    if quote != nil {
        throw ValidationError("Unterminated quote in --args: \(input)")
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
}
