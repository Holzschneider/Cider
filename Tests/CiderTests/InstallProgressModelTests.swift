import XCTest
@testable import CiderModels
@testable import CiderCore
@testable import CiderApp

@MainActor
final class InstallProgressModelTests: XCTestCase {

    func testPhasesDeclaredSeedsList() {
        let m = InstallProgressModel()
        m.apply(.phasesDeclared([
            PhaseDescriptor(id: "a", label: "Step A", kind: .indeterminate),
            PhaseDescriptor(id: "b", label: "Step B", kind: .determinate, alreadyDone: true),
        ]))
        XCTAssertEqual(m.phases.count, 2)
        XCTAssertEqual(m.phases[0].id, "a")
        XCTAssertEqual(m.phases[0].label, "Step A")
        XCTAssertEqual(m.phases[0].state, .pending)
        XCTAssertEqual(m.phases[1].state, .skipped,
                       "alreadyDone descriptors render as skipped (text-only, dim)")
    }

    func testPhaseStartProgressDoneTransitions() {
        let m = InstallProgressModel()
        m.apply(.phasesDeclared([
            PhaseDescriptor(id: "dl", label: "Downloading", kind: .determinate),
        ]))
        m.apply(.phaseStarted(id: "dl"))
        if case .running(let f, let d) = m.phases[0].state {
            XCTAssertNil(f); XCTAssertEqual(d, "")
        } else { XCTFail("expected .running") }

        m.apply(.phaseProgress(id: "dl", fraction: 0.42, detail: "1.0 MB"))
        if case .running(let f, let d) = m.phases[0].state {
            XCTAssertEqual(f, 0.42)
            XCTAssertEqual(d, "1.0 MB")
        } else { XCTFail("expected .running") }

        m.apply(.phaseDone(id: "dl"))
        XCTAssertEqual(m.phases[0].state, .done)
    }

    func testPhaseFailedCarriesMessage() {
        let m = InstallProgressModel()
        m.apply(.phasesDeclared([
            PhaseDescriptor(id: "x", label: "Risky", kind: .indeterminate),
        ]))
        m.apply(.phaseFailed(id: "x", message: "boom"))
        if case .failed(let msg) = m.phases[0].state {
            XCTAssertEqual(msg, "boom")
        } else { XCTFail("expected .failed") }
    }

    func testEventForUnknownPhaseIsIgnored() {
        let m = InstallProgressModel()
        m.apply(.phasesDeclared([
            PhaseDescriptor(id: "a", label: "A", kind: .indeterminate),
        ]))
        m.apply(.phaseStarted(id: "does-not-exist"))
        // No crash, no spurious phase added.
        XCTAssertEqual(m.phases.count, 1)
        XCTAssertEqual(m.phases[0].state, .pending)
    }

    func testLegacyStageAndFractionUpdateHeader() {
        let m = InstallProgressModel()
        m.apply(.stage("Working", detail: "deets"))
        XCTAssertEqual(m.stage, "Working")
        XCTAssertEqual(m.detail, "deets")
        XCTAssertNil(m.fraction)

        m.apply(.fraction(0.3))
        XCTAssertEqual(m.fraction, 0.3)
    }
}
