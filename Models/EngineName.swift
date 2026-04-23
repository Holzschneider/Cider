import Foundation

public struct EngineName: Hashable, Codable, CustomStringConvertible {
    public enum Variant: String, Codable {
        case wine = "Wine"
        case wineCX = "WineCX"
    }

    public let raw: String
    public let wrapperVersion: String      // e.g. "WS12"
    public let variant: Variant
    public let version: String             // e.g. "24.0.7_7"

    public var description: String { raw }

    // Accepts forms like "WS12WineCX24.0.7_7", "WS11Wine10.0_1".
    public init(_ raw: String) throws {
        let pattern = #"^(WS\d+)(Wine(?:CX)?)([\d._]+(?:Bit)?)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(raw.startIndex..., in: raw)
        guard
            let match = regex.firstMatch(in: raw, range: range),
            match.numberOfRanges == 4,
            let wrap = Range(match.range(at: 1), in: raw),
            let kind = Range(match.range(at: 2), in: raw),
            let ver = Range(match.range(at: 3), in: raw)
        else {
            throw Error.unrecognised(raw)
        }

        self.raw = raw
        self.wrapperVersion = String(raw[wrap])
        self.version = String(raw[ver])
        guard let parsed = Variant(rawValue: String(raw[kind])) else {
            throw Error.unrecognised(raw)
        }
        self.variant = parsed
    }

    public var archiveFilename: String { "\(raw).tar.xz" }

    // Sikarugir publishes all engines as assets under a single release tag.
    // Override with CIDER_ENGINES_TAG env var if a future release uses a
    // different tag name.
    public static var releaseTag: String {
        ProcessInfo.processInfo.environment["CIDER_ENGINES_TAG"] ?? "v1.0"
    }

    public var releaseDownloadURL: URL {
        URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/\(Self.releaseTag)/\(archiveFilename)")!
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case unrecognised(String)
        public var description: String {
            switch self {
            case .unrecognised(let s):
                return "Unrecognised engine name '\(s)'. Expected form: WS1xWine[CX]<version> (e.g. WS12WineCX24.0.7_7)."
            }
        }
    }
}
