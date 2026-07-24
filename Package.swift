// swift-tools-version: 5.9
import PackageDescription

// Frameworks del sistema que necesita el motor JUCE (libStrudelJuce.a).
let juceLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("c++"),
    .linkedFramework("CoreAudio"),
    .linkedFramework("CoreMIDI"),
    .linkedFramework("AudioToolbox"),
    .linkedFramework("Accelerate"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("IOKit"),
    .linkedFramework("Security"),
    .linkedFramework("Cocoa"),
]

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
        .executable(
            name: "VolumeCalibrate",
            targets: ["VolumeCalibrate"]
        ),
        .executable(
            name: "JuceProbe",
            targets: ["JuceProbe"]
        ),
    ],
    dependencies: [
        .package(path: "MiniEngine"),
    ],
    targets: [
        // Motor JUCE (C++) precompilado como xcframework binario.
        .binaryTarget(
            name: "StrudelJuce",
            path: "StrudelJuce/StrudelJuce.xcframework"
        ),
        // SwiftUI executable app — depends on MiniEngine + StrudelJuce
        .executableTarget(
            name: "DemoStrudelApp",
            dependencies: [
                .product(name: "MiniEngine", package: "MiniEngine"),
                "StrudelJuce",
            ],
            path: "Sources/DemoStrudelApp",
            resources: [
                .copy("Samples"),
                .copy("StrudelWeb"),
                .copy("Soundfonts")
            ],
            linkerSettings: juceLinkerSettings
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
        // Headless smoke test del motor JUCE (C API + CoreAudio).
        .executableTarget(
            name: "JuceProbe",
            dependencies: ["StrudelJuce"],
            path: "Sources/JuceProbe",
            linkerSettings: juceLinkerSettings
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
        // Live RMS calibration harness: taps mainMixer in real-time to measure
        // RMS of synth vs sample patterns and calibrate synthHeadroom.
        .executableTarget(
            name: "VolumeCalibrate",
            dependencies: [
                .product(name: "MiniEngine", package: "MiniEngine"),
            ],
            path: "Sources/VolumeCalibrate"
        ),
    ]
)
