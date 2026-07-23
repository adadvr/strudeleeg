// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DemoStrudel",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "DemoStrudelApp",
            targets: ["DemoStrudelApp"]
        ),
        .executable(
            name: "ValidateEvents",
            targets: ["ValidateEvents"]
        ),
        .executable(
            name: "AudioValidate",
            targets: ["AudioValidate"]
        ),
    ],
    dependencies: [
        .package(path: "MiniEngine"),
    ],
    targets: [
        // SwiftUI executable app — depends on MiniEngine
        .executableTarget(
            name: "DemoStrudelApp",
            dependencies: [
                .product(name: "MiniEngine", package: "MiniEngine"),
            ],
            path: "Sources/DemoStrudelApp",
            resources: [
                .copy("Samples"),
                .copy("StrudelWeb")
            ]
        ),
        // CLI tool — validates event timing using the new MiniEngine core
        .executableTarget(
            name: "ValidateEvents",
            dependencies: [
                .product(name: "MiniEngine", package: "MiniEngine"),
            ],
            path: "Sources/ValidateEvents"
        ),
        // Headless probe to diagnose the Strudel WebView engine
        .executableTarget(
            name: "WebProbe",
            dependencies: [],
            path: "Sources/WebProbe"
        ),
        // Offline audio validation harness: renders MiniEngine synths offline
        // and verifies spectral peaks with Accelerate/vDSP FFT.
        .executableTarget(
            name: "AudioValidate",
            dependencies: [
                .product(name: "MiniEngine", package: "MiniEngine"),
            ],
            path: "Sources/AudioValidate"
        ),
    ]
)
