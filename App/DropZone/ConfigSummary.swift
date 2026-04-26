import Foundation
import CiderModels

// Pure projection of a CiderConfig into a short, structured summary
// the Drop Zone renders next to the bundle's icon once a config is
// loaded (either from a Save or from auto-detection). Shape:
//
//   - heading:  the App Name, always present
//   - lines:    zero or more single-line snippets, each describing one
//               aspect of the config that ISN'T a default
//
// Rules (kept here so the test suite has one place to pin them):
//   * No property keys, no spelled-out paths, no defaults.
//   * Exe is shown by basename only.
//   * Wine options collapse onto one " · "-joined row when any are
//     non-default; rows that aren't "different from default" are
//     omitted.
//   * Args / splash / icon / origin-URL each become their own row only
//     when set to a non-default value.
enum ConfigSummary {
    struct Snapshot: Equatable {
        let heading: String
        let lines: [String]
    }

    static func summary(for config: CiderConfig) -> Snapshot {
        var lines: [String] = []

        // Install mode + graphics share a row — both are ~6 chars and
        // the user will always glance at them together.
        let modeLabel = label(for: config)
        let graphicsLabel = label(for: config.graphics)
        lines.append("\(modeLabel) · \(graphicsLabel)")

        if !config.engine.name.isEmpty {
            lines.append(config.engine.name)
        }

        let exeBase = (config.exe as NSString).lastPathComponent
        if !exeBase.isEmpty {
            lines.append(exeBase)
        }

        if !config.args.isEmpty {
            lines.append("args: \(config.args.joined(separator: " "))")
        }

        if let wineLine = wineLine(config.wine) {
            lines.append(wineLine)
        }

        if config.splash != nil {
            lines.append("custom splash")
        }
        if let icon = config.icon, !icon.isEmpty {
            lines.append("custom icon")
        }
        if (config.originURL?.isEmpty == false)
            || (config.distributionURL?.isEmpty == false) {
            lines.append("from URL")
        }

        return Snapshot(heading: config.displayName, lines: lines)
    }

    // MARK: - Pieces

    private static func label(for config: CiderConfig) -> String {
        // Infer install mode from applicationPath the same way
        // MoreDialogViewModel does — keeps the summary consistent
        // with what the dialog displays.
        let p = config.applicationPath.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("/") || p.hasPrefix("~") { return "Link" }
        if p == "Application"
            || p.hasPrefix("Application/")
            || p.hasPrefix("System/") {
            return "Bundle"
        }
        return "Install"
    }

    private static func label(for kind: GraphicsDriverKind) -> String {
        switch kind {
        case .dxmt:     return "DXMT"
        case .d3dmetal: return "D3DMetal"
        case .dxvk:     return "DXVK"
        }
    }

    private static func wineLine(_ wine: CiderConfig.WineOptions) -> String? {
        var bits: [String] = []
        if wine.esync == false           { bits.append("esync off") }
        if wine.msync == false           { bits.append("msync off") }
        if wine.console == true          { bits.append("console") }
        if wine.inheritConsole == true   { bits.append("shared console") }
        if wine.useWinedbg == true       { bits.append("winedbg on") }
        if !wine.winetricks.isEmpty {
            bits.append("tricks: \(wine.winetricks.joined(separator: " "))")
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }
}
