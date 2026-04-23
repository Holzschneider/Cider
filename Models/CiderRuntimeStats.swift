import Foundation

// Per-bundle ephemeral state, stored at
// ~/Library/Application Support/Cider/RuntimeStats/<bundle-name>.json.
//
// Holds:
//  - Whether the wine prefix has been initialised (so we don't redo wineboot)
//  - A rolling-average count of stdout lines from the last few wine launches,
//    used to normalise the load-progress bar to 0..100% in the splash window
//  - The last verified hashes for slim-mode (engine + source) so the patcher
//    can detect upstream changes without re-downloading every launch
public struct CiderRuntimeStats: Codable, Equatable {
    public static let currentSchemaVersion = 1
    public static let rollingWindow = 5

    public var schemaVersion: Int
    public var prefixInitialised: Bool
    public var loadLineCount: LoadLineCount
    public var lastVerifiedEngineSha: String?
    public var lastVerifiedSourceSha: String?

    public init(
        schemaVersion: Int = CiderRuntimeStats.currentSchemaVersion,
        prefixInitialised: Bool = false,
        loadLineCount: LoadLineCount = LoadLineCount(),
        lastVerifiedEngineSha: String? = nil,
        lastVerifiedSourceSha: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.prefixInitialised = prefixInitialised
        self.loadLineCount = loadLineCount
        self.lastVerifiedEngineSha = lastVerifiedEngineSha
        self.lastVerifiedSourceSha = lastVerifiedSourceSha
    }

    public struct LoadLineCount: Codable, Equatable {
        public var rolling: Double
        public var samples: Int

        public init(rolling: Double = 0, samples: Int = 0) {
            self.rolling = rolling
            self.samples = samples
        }

        // Folds a new wine-launch line count into the rolling average.
        // Caps the sample count at rollingWindow so old launches eventually
        // drop out and the average tracks recent reality (e.g. game updates
        // changing startup behaviour).
        public mutating func record(_ count: Int) {
            let countD = Double(count)
            if samples == 0 {
                rolling = countD
                samples = 1
                return
            }
            let effective = min(samples, CiderRuntimeStats.rollingWindow)
            rolling = (rolling * Double(effective) + countD) / Double(effective + 1)
            samples = min(samples + 1, CiderRuntimeStats.rollingWindow)
        }

        // 0..1 progress for `currentLineCount` against the rolling average.
        // Returns nil before any baseline is recorded — the splash should
        // show an indeterminate spinner in that case.
        public func progress(forCurrent currentLineCount: Int) -> Double? {
            guard samples > 0, rolling > 0 else { return nil }
            return min(1.0, Double(currentLineCount) / rolling)
        }
    }
}

public extension CiderRuntimeStats {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder = JSONDecoder()

    func encoded() throws -> Data { try Self.encoder.encode(self) }

    static func decode(_ data: Data) throws -> CiderRuntimeStats {
        try decoder.decode(CiderRuntimeStats.self, from: data)
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoded().write(to: url)
    }

    // Loads stats from disk, or returns a fresh default if the file is
    // absent or unreadable. Stats are non-load-bearing — losing them only
    // resets the rolling average — so we don't fail loud here.
    static func loadOrDefault(from url: URL) -> CiderRuntimeStats {
        guard let data = try? Data(contentsOf: url),
              let stats = try? decode(data) else {
            return CiderRuntimeStats()
        }
        return stats
    }
}
