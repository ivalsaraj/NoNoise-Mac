// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NoNoiseMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NoNoiseMac", targets: ["NoNoiseMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // Lock-free C11-atomics SPSC float ring for the tap-based Clean Incoming path (bridges the
        // process-tap IOProc → AVAudioSourceNode, two realtime threads). C target because acquire/
        // release atomics aren't available pure-Swift on the macOS 14.4 floor; mirrors the driver's
        // tested nn_ring discipline with zero external dependencies.
        .target(
            name: "CTapRing",
            path: "Sources/CTapRing"
        ),
        .target(
            name: "Core",
            dependencies: ["CTapRing"],
            path: "Sources/Core",
            resources: [
                .copy("../../Resources")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate")
            ]
        ),
        .executableTarget(
            name: "NoNoiseMac",
            dependencies: [
                "Core",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/App",
            resources: [
                .process("../../Resources")
            ]
        ),
        .executableTarget(
            name: "NoNoiseMacCLI",
            dependencies: ["Core"],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "NoNoiseMacTests",
            dependencies: ["Core", "CTapRing"],
            path: "Tests/NoNoiseMacTests"
        )
    ]
)
