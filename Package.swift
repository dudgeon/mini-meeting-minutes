// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mini-meeting-minutes",
    platforms: [
        // Parakeet Redux's 2-bit encoder needs macOS 15 Core ML ops.
        .macOS(.v15)
    ],
    products: [
        .executable(name: "mmm", targets: ["mmm"])
    ],
    dependencies: [
        // Pinned to a main-branch commit: LocalVQE echo cancellation landed after the v0.17.4 tag.
        // `traits: []` leaves out FluidAudio's text-normalization binary, which only its TTS and
        // inverse-text-normalization features use.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "20d4f0bd46d11d7f50a6eb4f7835cfdbd2b4ba14",
            traits: []
        ),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MinutesCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "mmm",
            dependencies: [
                "MinutesCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MinutesCoreTests",
            dependencies: ["MinutesCore"]
        ),
    ]
)
