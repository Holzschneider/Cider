import Foundation
import CiderModels

// Counts lines streamed out of wine's stdout/stderr, normalises them
// against the rolling-average baseline from RuntimeStats, and exposes a
// 0…1 progress + a "settled" signal once line rate has dropped.
//
// Pure logic — no I/O. Caller drives it by calling `record(lines:)` for
// every batch of lines pulled from the wine pipe and `tick()` periodically
// so settle detection works even when no lines are arriving.
public final class ConsoleLineCounter {
    public struct Snapshot: Equatable {
        public let lineCount: Int
        public let progress: Double?    // nil before any baseline exists
        public let settled: Bool        // line rate has fallen below threshold
    }

    public let baseline: CiderRuntimeStats.LoadLineCount
    // Optional explicit target — when set (cider.json's
    // loading.expectedLineCount), it wins over the rolling baseline
    // and lets the bar be determinate from the very first launch
    // without waiting for a sample. nil falls back to baseline.
    public let explicitTarget: Int?
    public let settleQuietSeconds: TimeInterval
    public let settleMinLines: Int      // don't settle before at least N lines

    private var count: Int = 0
    private var lastLineAt: Date?
    private var settledFlag: Bool = false
    private var clock: () -> Date

    public init(
        baseline: CiderRuntimeStats.LoadLineCount,
        explicitTarget: Int? = nil,
        settleQuietSeconds: TimeInterval = 3.0,
        settleMinLines: Int = 5,
        clock: @escaping () -> Date = Date.init
    ) {
        self.baseline = baseline
        self.explicitTarget = explicitTarget
        self.settleQuietSeconds = settleQuietSeconds
        self.settleMinLines = settleMinLines
        self.clock = clock
    }

    @discardableResult
    public func record<S: Sequence>(lines: S) -> Snapshot where S.Element == String {
        var added = 0
        for _ in lines { added += 1 }
        if added > 0 {
            count += added
            lastLineAt = clock()
        }
        return snapshot()
    }

    public func tick() -> Snapshot {
        // Only check settling; no count change.
        if !settledFlag,
           count >= settleMinLines,
           let last = lastLineAt,
           clock().timeIntervalSince(last) >= settleQuietSeconds {
            settledFlag = true
        }
        return snapshot()
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            lineCount: count,
            progress: progressForCurrent(),
            settled: settledFlag
        )
    }

    private func progressForCurrent() -> Double? {
        if let explicitTarget, explicitTarget > 0 {
            return min(1.0, Double(count) / Double(explicitTarget))
        }
        return baseline.progress(forCurrent: count)
    }
}
