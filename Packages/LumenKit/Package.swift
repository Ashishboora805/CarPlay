// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LumenKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LumenKit", targets: ["LumenKit"])
    ],
    targets: [
        .target(
            name: "LumenKit",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "LumenKitTests",
            dependencies: ["LumenKit"]
        )
    ]
)
