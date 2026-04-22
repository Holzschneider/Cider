import XCTest
@testable import Cider

final class InfoPlistWriterTests: XCTestCase {
    func testWritesRequiredKeys() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-plist-test-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try InfoPlistWriter.write(
            .init(
                bundleName: "My Game",
                bundleIdentifier: "com.example.mygame",
                bundleVersion: "1.2.3",
                iconFileName: "AppIcon",
                minimumSystemVersion: "11.0",
                executableName: "Launcher",
                category: "public.app-category.games"
            ),
            to: tmp
        )

        let data = try Data(contentsOf: tmp)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(plist?["CFBundleName"] as? String, "My Game")
        XCTAssertEqual(plist?["CFBundleIdentifier"] as? String, "com.example.mygame")
        XCTAssertEqual(plist?["CFBundleExecutable"] as? String, "Launcher")
        XCTAssertEqual(plist?["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(plist?["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist?["NSHighResolutionCapable"] as? Bool, true)
    }

    func testOmitsIconWhenNil() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cider-plist-test-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try InfoPlistWriter.write(
            .init(
                bundleName: "No Icon App",
                bundleIdentifier: "com.example.noicon",
                bundleVersion: "1.0",
                iconFileName: nil,
                minimumSystemVersion: "11.0",
                executableName: "Launcher",
                category: "public.app-category.utilities"
            ),
            to: tmp
        )

        let data = try Data(contentsOf: tmp)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertNil(plist?["CFBundleIconFile"])
    }
}
