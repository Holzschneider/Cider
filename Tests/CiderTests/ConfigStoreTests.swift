import XCTest
@testable import CiderModels
@testable import CiderCore

final class ConfigStoreTests: XCTestCase {
    private func sample(_ name: String) -> CiderConfig {
        CiderConfig(
            displayName: name,
            exe: "Game.exe",
            source: .init(mode: .path, path: "/tmp/x"),
            engine: .init(name: "WS12WineCX24.0.7_7", url: "https://example.com/x.tar.xz"),
            graphics: .dxmt
        )
    }

    private func tmp() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-cs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testReturnsNilWhenNothingPresent() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(
            inBundleConfigFile: dir.appendingPathComponent("inBundle.json"),
            appSupportConfigFile: dir.appendingPathComponent("appSupport.json")
        )
        XCTAssertNil(try store.locate())
    }

    func testAppSupportFallback() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let inBundle = dir.appendingPathComponent("inBundle.json")
        let appSupport = dir.appendingPathComponent("appSupport.json")
        try sample("FromAppSupport").write(to: appSupport)

        let store = ConfigStore(inBundleConfigFile: inBundle, appSupportConfigFile: appSupport)
        let resolved = try XCTUnwrap(try store.locate())
        XCTAssertEqual(resolved.config.displayName, "FromAppSupport")
        if case .appSupport(let url) = resolved.source {
            XCTAssertEqual(url, appSupport)
        } else {
            XCTFail("expected .appSupport")
        }
    }

    func testInBundleOverrideWinsOverAppSupport() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let inBundle = dir.appendingPathComponent("CiderConfig").appendingPathComponent("cider.json")
        let appSupport = dir.appendingPathComponent("appSupport.json")
        try sample("FromInBundle").write(to: inBundle)
        try sample("FromAppSupport").write(to: appSupport)

        let store = ConfigStore(inBundleConfigFile: inBundle, appSupportConfigFile: appSupport)
        let resolved = try XCTUnwrap(try store.locate())
        XCTAssertEqual(resolved.config.displayName, "FromInBundle")
        if case .inBundleOverride(let url) = resolved.source {
            XCTAssertEqual(url, inBundle)
        } else {
            XCTFail("expected .inBundleOverride")
        }
    }

    func testWriteRoundTripsThroughInBundleTarget() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let inBundle = dir.appendingPathComponent("CiderConfig").appendingPathComponent("cider.json")
        let appSupport = dir.appendingPathComponent("appSupport.json")
        let store = ConfigStore(inBundleConfigFile: inBundle, appSupportConfigFile: appSupport)
        let written = try store.write(sample("Test"), to: .inBundleOverride)
        XCTAssertEqual(written, inBundle)
        let resolved = try XCTUnwrap(try store.locate())
        XCTAssertEqual(resolved.config.displayName, "Test")
    }
}
