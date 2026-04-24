import Foundation

// Schema v2 (clean break from v1).
//
// cider.json describes how to LAUNCH a configured Windows app. It does NOT
// remember how the app's files were originally provided (folder / zip /
// URL) — that's a configuration-time concern handled by the Installer.
//
// `applicationPath` is resolved relative to the directory the cider.json
// itself lives in:
//   - Bundle install: cider.json at <bundle>/cider.json,
//                     applicationPath like "Application/MyGame".
//   - Install (AppSupport): cider.json at AppSupport/Configs/<name>.json,
//                           applicationPath like "MyGame" (resolved against
//                           AppSupport/Program Files/<name>/).
//   - Link: applicationPath is an absolute path to an external folder; the
//           cider.json sits in AppSupport/Configs/<name>.json.
//
// `originURL` is the optional URL the cider.json itself was originally
// fetched from (set when the user drops a remote cider.json URL — used
// for a future "check for updates" affordance).
//
// `distributionURL` is the optional URL of the data zip. Set when a
// cider.json-at-URL referenced a zip elsewhere (drop-URL indirection,
// Phase 5), and preserved so the bundle knows where its data came from
// (future patcher / re-install mechanism).
public struct CiderConfig: Codable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var displayName: String
    public var applicationPath: String
    public var exe: String
    public var args: [String]
    public var engine: EngineRef
    public var wrapperTemplate: TemplateRef
    public var graphics: GraphicsDriverKind
    public var wine: WineOptions
    public var splash: Splash?
    public var icon: String?
    public var originURL: String?
    public var distributionURL: String?

    public init(
        schemaVersion: Int = CiderConfig.currentSchemaVersion,
        displayName: String,
        applicationPath: String,
        exe: String,
        args: [String] = [],
        engine: EngineRef,
        wrapperTemplate: TemplateRef = .default,
        graphics: GraphicsDriverKind,
        wine: WineOptions = .default,
        splash: Splash? = nil,
        icon: String? = nil,
        originURL: String? = nil,
        distributionURL: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.displayName = displayName
        self.applicationPath = applicationPath
        self.exe = exe
        self.args = args
        self.engine = engine
        self.wrapperTemplate = wrapperTemplate
        self.graphics = graphics
        self.wine = wine
        self.splash = splash
        self.icon = icon
        self.originURL = originURL
        self.distributionURL = distributionURL
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

// MARK: - Resolution

public extension CiderConfig {
    // Resolves `applicationPath` against the cider.json's own location.
    // Absolute paths (Link mode) are returned as-is.
    func resolvedApplicationDirectory(configFile: URL) -> URL {
        if applicationPath.hasPrefix("/") {
            return URL(fileURLWithPath: applicationPath)
        }
        let configDir = configFile.deletingLastPathComponent()
        return configDir.appendingPathComponent(applicationPath, isDirectory: true)
    }

    // Resolves `exe` (relative path inside the application directory) to
    // an absolute on-disk URL.
    func resolvedExecutable(configFile: URL) -> URL {
        resolvedApplicationDirectory(configFile: configFile)
            .appendingPathComponent(exe)
    }
}

// MARK: - JSON I/O

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
