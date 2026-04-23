import XCTest
@testable import CiderModels
@testable import CiderCore

final class IntegrityCheckerTests: XCTestCase {
    private func tmpFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-ic-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let unreachable = URL(string: "https://0.0.0.0/never")!

    func testRedownloadWhenLocalMissing() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let decision = await IntegrityChecker.decide(
            localFile: url,
            expectedSha256: nil,
            priorCache: nil,
            remoteURL: unreachable
        )
        XCTAssertEqual(decision, .redownload(reason: "no local copy"))
    }

    func testUseExistingOnExpectedShaMatch() async throws {
        let file = try tmpFile("hello cider")
        defer { try? FileManager.default.removeItem(at: file) }
        let sha = try SHA256Hasher.hash(file: file)
        let decision = await IntegrityChecker.decide(
            localFile: file,
            expectedSha256: sha,
            priorCache: nil,
            remoteURL: unreachable
        )
        XCTAssertEqual(decision, .useExisting)
    }

    func testRedownloadOnExpectedShaMismatch() async throws {
        let file = try tmpFile("hello cider")
        defer { try? FileManager.default.removeItem(at: file) }
        let decision = await IntegrityChecker.decide(
            localFile: file,
            expectedSha256: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
            priorCache: nil,
            remoteURL: unreachable
        )
        if case .redownload(let reason) = decision {
            XCTAssertTrue(reason.contains("sha256 mismatch"))
        } else {
            XCTFail("expected sha mismatch decision, got \(decision)")
        }
    }

    func testUseExistingOnNetworkErrorWithPriorCache() async throws {
        let file = try tmpFile("anything")
        defer { try? FileManager.default.removeItem(at: file) }
        let sha = try SHA256Hasher.hash(file: file)
        let prior = CiderRuntimeStats.CachedArtifact(
            sha256: sha,
            etag: "abc",
            lastModified: "Mon, 01 Jan 2024 00:00:00 GMT",
            bytes: 8
        )
        // No expected sha; HEAD request will fail (unreachable). Expect
        // fail-open: trust local copy.
        let decision = await IntegrityChecker.decide(
            localFile: file,
            expectedSha256: nil,
            priorCache: prior,
            remoteURL: unreachable
        )
        XCTAssertEqual(decision, .useExisting)
    }

    func testCachedArtifactRoundTripsThroughRuntimeStats() throws {
        var s = CiderRuntimeStats(prefixInitialised: true)
        s.engineCache = .init(
            sha256: "abc123",
            etag: "W/\"etag\"",
            lastModified: "Tue, 02 Feb 2024",
            bytes: 12345
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try s.write(to: url)
        let loaded = CiderRuntimeStats.loadOrDefault(from: url)
        XCTAssertEqual(loaded.engineCache?.sha256, "abc123")
        XCTAssertEqual(loaded.engineCache?.etag, "W/\"etag\"")
        XCTAssertEqual(loaded.engineCache?.bytes, 12345)
    }
}
