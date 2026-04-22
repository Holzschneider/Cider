// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Cider",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "cider", targets: ["Cider"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Cider",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "TOMLKit", package: "TOMLKit")
            ],
            resources: [
                .copy("Resources/launcher.sh.template")
            ]
        ),
        .testTarget(
            name: "CiderTests",
            dependencies: ["Cider"]
        )
    ]
)
