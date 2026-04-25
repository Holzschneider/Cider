import Foundation
import CryptoKit
import CiderModels

// Stable identity for a Wine prefix, derived from the subset of
// CiderConfig fields that actually affect the prefix's on-disk state:
// engine binary + URL (different versions = different wine = different
// prefix bottles), graphics driver (controls which DLLs land in
// system32/syswow64), and the wine knobs that wineboot/wineprefix care
// about (esync, msync, winetricks).
//
// Two configs that hash to the same key can safely share a prefix —
// re-running wineboot would produce the same drive_c structure. Two
// configs that differ in any of these fields get distinct prefixes,
// so a Bundle that needs CrossOver-CX24 doesn't sit on top of a
// prefix bootstrapped with WS12.
//
// Things deliberately excluded from the hash: displayName, exe, args,
// applicationPath, splash, icon, originURL, distributionURL, source.
// Those are bundle-presentation / launch-time concerns; they have no
// effect on the prefix's contents.
public enum PrefixIdentity {
    public struct Identity: Equatable {
        // Filesystem-safe slot name, suitable for AppSupport/Prefixes/.
        // Format: "<engine>-<graphics>-<short-hash>".
        public let key: String
        // Human-readable label for log lines / UI.
        public let displayName: String
    }

    public static func compute(for config: CiderConfig) -> Identity {
        let normalised = NormalisedInputs(
            engineName: config.engine.name.trimmingCharacters(in: .whitespaces),
            engineURL:  config.engine.url.trimmingCharacters(in: .whitespaces),
            graphics:   config.graphics.rawValue,
            esync:      config.wine.esync,
            msync:      config.wine.msync,
            // Sort winetricks so verb order doesn't change the prefix's
            // identity — installing corefonts then vcrun2019 is the
            // same prefix as installing them in reverse.
            winetricks: config.wine.winetricks
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
                .sorted()
        )

        // Stable serialisation: tab-delimited, no JSON ordering games.
        let payload = [
            "engineName=\(normalised.engineName)",
            "engineURL=\(normalised.engineURL)",
            "graphics=\(normalised.graphics)",
            "esync=\(normalised.esync ? "1" : "0")",
            "msync=\(normalised.msync ? "1" : "0")",
            "winetricks=[\(normalised.winetricks.joined(separator: ","))]"
        ].joined(separator: "\t")

        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let shortHash = String(hex.prefix(8))

        let engineSlug = sanitise(normalised.engineName)
        let graphicsSlug = sanitise(normalised.graphics)
        let key = "\(engineSlug)-\(graphicsSlug)-\(shortHash)"

        let displayName: String = {
            var parts = ["Wine prefix \(shortHash)"]
            if !normalised.engineName.isEmpty { parts.append("engine=\(normalised.engineName)") }
            if !normalised.graphics.isEmpty   { parts.append("graphics=\(normalised.graphics)") }
            return parts.joined(separator: ", ")
        }()

        return Identity(key: key, displayName: displayName)
    }

    // MARK: - Internal

    private struct NormalisedInputs {
        let engineName: String
        let engineURL: String
        let graphics: String
        let esync: Bool
        let msync: Bool
        let winetricks: [String]
    }

    // Filesystem-safe slug. Strips path / shell metacharacters, collapses
    // whitespace to a single dash, falls back to "unknown" if everything
    // gets stripped (engineName empty, etc.).
    private static func sanitise(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\"?*<>|\t\n\r ")
        let mapped = raw.unicodeScalars.map { invalid.contains($0) ? "-" : String($0) }.joined()
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let collapsed = trimmed.split(whereSeparator: { $0 == "-" }).joined(separator: "-")
        let bounded = String(collapsed.prefix(64))
        return bounded.isEmpty ? "unknown" : bounded
    }
}
