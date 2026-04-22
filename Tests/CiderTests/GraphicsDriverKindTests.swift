import XCTest
@testable import Cider

final class GraphicsDriverKindTests: XCTestCase {
    func testAllCasesHaveOverrides() {
        for kind in GraphicsDriverKind.allCases {
            XCTAssertFalse(kind.dllOverrides.isEmpty, "\(kind) missing DLL overrides")
        }
    }

    func testDefaultMatchesArchitecture() {
        let expected: GraphicsDriverKind
        #if arch(arm64)
        expected = .d3dmetal
        #else
        expected = .dxvk
        #endif
        XCTAssertEqual(GraphicsDriverKind.defaultForThisMachine, expected)
    }
}
