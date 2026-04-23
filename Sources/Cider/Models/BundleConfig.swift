import Foundation

struct BundleConfig: Codable {
    var input: URL
    var exe: String
    var args: [String]
    var engine: EngineName
    var graphics: GraphicsDriverKind
    var icon: URL?
    var name: String
    var bundleId: String
    var output: URL
    var preInitPrefix: Bool
    var console: Bool
    var inheritConsole: Bool
    var signIdentity: SignIdentity

    enum SignIdentity: Codable, Equatable {
        case adHoc
        case developerID(String)

        var codesignArgument: String {
            switch self {
            case .adHoc: return "-"
            case .developerID(let id): return id
            }
        }
    }

    // Metadata we write into the produced bundle as cider.json
    struct BundleMetadata: Codable {
        let engine: String
        let graphics: GraphicsDriverKind
        let winExePath: String
        let exeArgs: [String]
        let createdAt: Date
        let ciderVersion: String
    }
}

extension BundleConfig {
    // TOML-decodable representation used by --with-config.
    struct File: Decodable {
        struct Bundle: Decodable {
            var input: String
            var exe: String
            var name: String?
            var bundle_id: String?
            var output: String?
        }
        struct Engine: Decodable {
            var name: String
            var graphics: String?
        }
        struct Launch: Decodable {
            var args: String?
        }
        struct Icon: Decodable {
            var path: String?
        }

        var bundle: Bundle
        var engine: Engine
        var launch: Launch?
        var icon: Icon?
    }
}
