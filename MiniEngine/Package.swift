// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MiniEngine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MiniEngine",
            targets: ["MiniEngine"]
        ),
    ],
    targets: [
        .target(
            name: "MiniEngine",
            dependencies: [],
            path: "Sources/MiniEngine"
        ),
        .testTarget(
            name: "MiniEngineTests",
            dependencies: ["MiniEngine"],
            path: "Tests/MiniEngineTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
