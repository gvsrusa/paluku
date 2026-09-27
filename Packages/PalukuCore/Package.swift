// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PalukuCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "PalukuCore", targets: ["PalukuCore"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1"),
    ],
    targets: [
        .target(name: "PalukuCore", dependencies: [
            .product(name: "WhisperKit", package: "WhisperKit"),
            .product(name: "MCP", package: "swift-sdk"),
        ], swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]),
        .testTarget(name: "PalukuCoreTests", dependencies: ["PalukuCore"]),
    ],
    swiftLanguageModes: [.v5]
)
