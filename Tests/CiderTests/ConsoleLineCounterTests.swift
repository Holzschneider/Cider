import XCTest
@testable import CiderModels
@testable import CiderCore

final class ConsoleLineCounterTests: XCTestCase {
    func testProgressIsNilBeforeBaseline() {
        let counter = ConsoleLineCounter(baseline: .init())
        let snap = counter.record(lines: ["a", "b", "c"])
        XCTAssertEqual(snap.lineCount, 3)
        XCTAssertNil(snap.progress)
        XCTAssertFalse(snap.settled)
    }

    func testProgressNormalisesAgainstRolling() {
        var baseline = CiderRuntimeStats.LoadLineCount()
        baseline.record(100)
        let counter = ConsoleLineCounter(baseline: baseline)
        let snap = counter.record(lines: Array(repeating: "x", count: 50))
        XCTAssertEqual(snap.lineCount, 50)
        XCTAssertEqual(snap.progress!, 0.5, accuracy: 0.001)
    }

    func testProgressCapsAtOne() {
        var baseline = CiderRuntimeStats.LoadLineCount()
        baseline.record(10)
        let counter = ConsoleLineCounter(baseline: baseline)
        let snap = counter.record(lines: Array(repeating: "x", count: 1000))
        XCTAssertEqual(snap.progress!, 1.0, accuracy: 0.001)
    }

    func testSettleNeedsMinLinesAndQuietPeriod() {
        var t = Date(timeIntervalSince1970: 0)
        let counter = ConsoleLineCounter(
            baseline: .init(),
            settleQuietSeconds: 2.0,
            settleMinLines: 5,
            clock: { t }
        )
        // Record 3 lines (below settle min)
        _ = counter.record(lines: ["a", "b", "c"])
        t = t.addingTimeInterval(10)
        XCTAssertFalse(counter.tick().settled, "shouldn't settle below min lines")

        // Record 3 more (over min) at t=10
        _ = counter.record(lines: ["d", "e", "f"])
        t = t.addingTimeInterval(1)
        XCTAssertFalse(counter.tick().settled, "shouldn't settle within quiet period")

        // Advance past the quiet threshold
        t = t.addingTimeInterval(2.0)
        XCTAssertTrue(counter.tick().settled, "should settle after quiet period")
    }

    func testSettleResetsOnNewLines() {
        var t = Date(timeIntervalSince1970: 0)
        let counter = ConsoleLineCounter(
            baseline: .init(),
            settleQuietSeconds: 2.0,
            settleMinLines: 1,
            clock: { t }
        )
        _ = counter.record(lines: ["a"])
        t = t.addingTimeInterval(5)
        // New line resets lastLineAt — should NOT immediately settle on next tick
        _ = counter.record(lines: ["b"])
        t = t.addingTimeInterval(1)
        XCTAssertFalse(counter.tick().settled)
        t = t.addingTimeInterval(2.0)
        XCTAssertTrue(counter.tick().settled)
    }
}
