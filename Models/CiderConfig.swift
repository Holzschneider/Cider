import Foundation

// Schema for cider.json — the per-bundle configuration. Located via
// ConfigStore (in-bundle override → AppSupport-by-name).
public struct CiderConfig: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var displayName: String
    public var exe: String
    public var args: [String]
    public var source: Source
    public var engine: EngineRef
    public var wrapperTemplate: TemplateRef
    public var graphics: GraphicsDriverKind
    public var wine: WineOptions
    public var splash: Splash?
    public var icon: String?

    public init(
        schemaVersion: Int = CiderConfig.currentSchemaVersion,
        displayName: String,
        exe: String,
        args: [String] = [],
        source: Source,
        engine: EngineRef,
        wrapperTemplate: TemplateRef = .default,
        graphics: GraphicsDriverKind,
        wine: WineOptions = .default,
        splash: Splash? = nil,
        icon: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.displayName = displayName
        self.exe = exe
        self.args = args
        self.source = source
        self.engine = engine
        self.wrapperTemplate = wrapperTemplate
        self.graphics = graphics
        self.wine = wine
        self.splash = splash
        self.icon = icon
    }

    public struct Source: Codable, Equatable {
        public enum Mode: String, Codable {
            case path
            case inBundle
            case url
        }
        public var mode: Mode
        public var path: String?
        public var inBundleFolder: String?
        public var url: String?
        public var sha256: String?

        public init(
            mode: Mode,
            path: String? = nil,
            inBundleFolder: String? = nil,
            url: String? = nil,
            sha256: String? = nil
        ) {
            self.mode = mode
            self.path = path
            self.inBundleFolder = inBundleFolder
            self.url = url
            self.sha256 = sha256
        }
    }

    public struct EngineRef: Codable, Equatable {
        public var name: String
        public var url: String
        public var sha256: String?

        public init(name: String, url: String, sha256: String? = nil) {
            self.name = name
            self.url = url
            self.sha256 = sha256
        }
    }

    public struct TemplateRef: Codable, Equatable {
        public var version: String
        public var url: String
        public var sha256: String?

        public init(version: String, url: String, sha256: String? = nil) {
            self.version = version
            self.url = url
            self.sha256 = sha256
        }

        // Default tracks the version Cider has been validated against;
        // Cider will follow this unless a per-bundle config overrides it.
        public static let `default` = TemplateRef(
            version: "1.0.11",
            url: "https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.11.tar.xz"
        )
    }

    public struct WineOptions: Codable, Equatable {
        public var esync: Bool
        public var msync: Bool
        public var useWinedbg: Bool
        public var winetricks: [String]
        public var console: Bool
        public var inheritConsole: Bool

        public init(
            esync: Bool = true,
            msync: Bool = true,
            useWinedbg: Bool = false,
            winetricks: [String] = [],
            console: Bool = false,
            inheritConsole: Bool = false
        ) {
            self.esync = esync
            self.msync = msync
            self.useWinedbg = useWinedbg
            self.winetricks = winetricks
            self.console = console
            self.inheritConsole = inheritConsole
        }

        public static let `default` = WineOptions()
    }

    public struct Splash: Codable, Equatable {
        public var file: String
        public var transparent: Bool

        public init(file: String, transparent: Bool = true) {
            self.file = file
            self.transparent = transparent
        }
    }
}

// Pretty-print + parse helpers. JSON is stored sorted, indented for
// human-editable cider.json files.
public extension CiderConfig {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder = JSONDecoder()

    func encoded() throws -> Data { try Self.encoder.encode(self) }

    static func decode(_ data: Data) throws -> CiderConfig {
        try decoder.decode(CiderConfig.self, from: data)
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoded().write(to: url)
    }

    static func read(from url: URL) throws -> CiderConfig {
        try decode(Data(contentsOf: url))
    }
}
