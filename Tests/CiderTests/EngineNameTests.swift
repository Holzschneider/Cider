import XCTest
@testable import Cider

final class EngineNameTests: XCTestCase {
    func testParsesCrossOverEngine() throws {
        let e = try EngineName("WS12WineCX24.0.7_7")
        XCTAssertEqual(e.wrapperVersion, "WS12")
        XCTAssertEqual(e.variant, .wineCX)
        XCTAssertEqual(e.version, "24.0.7_7")
        XCTAssertEqual(e.archiveFilename, "WS12WineCX24.0.7_7.tar.xz")
        XCTAssertEqual(
            e.releaseDownloadURL.absoluteString,
            "https://github.com/Sikarugir-App/Engines/releases/download/WS12WineCX24.0.7_7/WS12WineCX24.0.7_7.tar.xz"
        )
    }

    func testParsesVanillaWineEngine() throws {
        let e = try EngineName("WS11Wine10.0_1")
        XCTAssertEqual(e.wrapperVersion, "WS11")
        XCTAssertEqual(e.variant, .wine)
        XCTAssertEqual(e.version, "10.0_1")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try EngineName("not-an-engine"))
        XCTAssertThrowsError(try EngineName("WineCX24.0"))
        XCTAssertThrowsError(try EngineName(""))
    }
}
