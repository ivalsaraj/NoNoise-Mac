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
        .target(
            name: "Core",
            dependencies: [],
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
            dependencies: ["Core"],
            path: "Tests/NoNoiseMacTests"
        )
    ]
)
