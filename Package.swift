// swift-tools-version: 5.9
import PackageDescription

// SPM is intentional during the GUI rewrite. Phase 11 migrates this to a
// real Cider.xcodeproj for hardened-runtime + notarization integration; the
// directory layout already matches that target Xcode structure so the move
// is mostly mechanical.
let package = Package(
    name: "Cider",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "cider", targets: ["CiderApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "CiderApp",
            dependencies: [
                "CiderCore",
                "CiderModels",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "App"
        ),
        .target(
            name: "CiderCore",
            dependencies: ["CiderModels"],
            path: "Core"
        ),
        .target(
            name: "CiderModels",
            path: "Models"
        ),
        .testTarget(
            name: "CiderTests",
            dependencies: ["CiderApp", "CiderCore", "CiderModels"],
            path: "Tests/CiderTests"
        )
    ]
)
