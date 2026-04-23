import XCTest
@testable import CiderModels

final class CiderRuntimeStatsTests: XCTestCase {
    func testFreshStatsHaveNoBaseline() {
        let s = CiderRuntimeStats()
        XCTAssertFalse(s.prefixInitialised)
        XCTAssertEqual(s.loadLineCount.samples, 0)
        XCTAssertNil(s.loadLineCount.progress(forCurrent: 100))
    }

    func testFirstSampleSetsBaseline() {
        var s = CiderRuntimeStats()
        s.loadLineCount.record(1000)
        XCTAssertEqual(s.loadLineCount.samples, 1)
        XCTAssertEqual(s.loadLineCount.rolling, 1000, accuracy: 0.001)
    }

    func testRollingAverageConverges() {
        var lc = CiderRuntimeStats.LoadLineCount()
        for _ in 0..<10 { lc.record(2000) }
        XCTAssertEqual(lc.rolling, 2000, accuracy: 0.001)
        XCTAssertEqual(lc.samples, CiderRuntimeStats.rollingWindow)
    }

    func testRollingAverageTracksRecentDrift() {
        var lc = CiderRuntimeStats.LoadLineCount()
        // Fill with 1000s
        for _ in 0..<CiderRuntimeStats.rollingWindow { lc.record(1000) }
        XCTAssertEqual(lc.rolling, 1000, accuracy: 0.001)
        // New sample at 5000 — should pull average up but not all the way
        lc.record(5000)
        XCTAssertGreaterThan(lc.rolling, 1000)
        XCTAssertLessThan(lc.rolling, 5000)
    }

    func testProgressCapsAtOne() throws {
        var lc = CiderRuntimeStats.LoadLineCount()
        lc.record(100)
        XCTAssertEqual(try XCTUnwrap(lc.progress(forCurrent: 50)), 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(lc.progress(forCurrent: 100)), 1.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(lc.progress(forCurrent: 1000)), 1.0, accuracy: 0.001)
    }

    func testWriteAndRead() throws {
        var s = CiderRuntimeStats(prefixInitialised: true)
        s.loadLineCount.record(4321)
        s.lastVerifiedEngineSha = "deadbeef"

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try s.write(to: url)
        let loaded = CiderRuntimeStats.loadOrDefault(from: url)
        XCTAssertEqual(loaded, s)
    }

    func testLoadOrDefaultReturnsFreshOnMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).json")
        let s = CiderRuntimeStats.loadOrDefault(from: url)
        XCTAssertFalse(s.prefixInitialised)
        XCTAssertEqual(s.loadLineCount.samples, 0)
    }
}
