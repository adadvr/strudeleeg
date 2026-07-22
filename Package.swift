// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DemoStrudel",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "NativeEngine",
            targets: ["NativeEngine"]
        ),
        .executable(
            name: "DemoStrudelApp",
            targets: ["DemoStrudelApp"]
        ),
        .executable(
            name: "ValidateEvents",
            targets: ["ValidateEvents"]
        ),
    ],
    targets: [
        // Isolated native audio engine — no dependency on app code or WebView
        .target(
            name: "NativeEngine",
            dependencies: [],
            path: "Sources/NativeEngine"
        ),
        // SwiftUI executable app
        .executableTarget(
            name: "DemoStrudelApp",
            dependencies: ["NativeEngine"],
            path: "Sources/DemoStrudelApp",
            resources: [
                .copy("Samples")
            ]
        ),
        // CLI tool to validate event timing (F1 verification)
        .executableTarget(
            name: "ValidateEvents",
            dependencies: ["NativeEngine"],
            path: "Sources/ValidateEvents"
        ),
    ]
)
