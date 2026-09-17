// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MrRoboto",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "MusicTheory", targets: ["MusicTheory"]),
        .library(name: "SongGraph", targets: ["SongGraph"]),
        .library(name: "Analysis", targets: ["Analysis"]),
        .library(name: "AnalysisMLX", targets: ["AnalysisMLX"]),
        .library(name: "AnalysisONNX", targets: ["AnalysisONNX"]),
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .library(name: "Instrument", targets: ["Instrument"]),
        .library(name: "Performance", targets: ["Performance"]),
        .executable(name: "m0", targets: ["m0"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        // Demucs on MLX (MIT). Pinned to a commit, not a branch; bump deliberately.
        .package(url: "https://github.com/kylehowells/demucs-mlx-swift", revision: "c8482739c621b90a64bf1a9f013712f6fea44eda"),
        // ONNX Runtime (MIT), Objective-C bindings over the 1.24.2 pod archive. Exact tag; bump deliberately.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        .target(name: "MusicTheory"),
        .target(name: "SongGraph", dependencies: ["MusicTheory"]),
        // Signalsmith Stretch (MIT), vendored header-only C++ behind a C shim; see Sources/CSignalsmithStretch/vendor/VENDORED.txt.
        .target(name: "CSignalsmithStretch",
                cxxSettings: [.headerSearchPath("vendor"), .define("SIGNALSMITH_USE_ACCELERATE"), .define("ACCELERATE_NEW_LAPACK")],
                linkerSettings: [.linkedFramework("Accelerate")]),
        .target(name: "Analysis", dependencies: ["MusicTheory", "CSignalsmithStretch"],
                linkerSettings: [.linkedFramework("MusicUnderstanding"), .linkedFramework("AVFoundation")]),
        .target(name: "AnalysisMLX", dependencies: [
            "Analysis",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "DemucsMLX", package: "demucs-mlx-swift"),
        ], linkerSettings: [.linkedFramework("AVFoundation")]),
        .target(name: "AnalysisONNX", dependencies: [
            "Analysis",
            .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
        ], linkerSettings: [.linkedFramework("AVFoundation")]),
        .target(name: "AudioEngine", dependencies: ["MusicTheory", "SongGraph"],
                linkerSettings: [.linkedFramework("AVFoundation")]),
        // The realtime render core. macOS 27 marks the realtime-safe AVAudioSourceNode render
        // block unavailable to Swift, so voice rendering lives in C and Swift owns lifetime.
        .target(name: "CVoiceRender"),
        // The degradation chain: bit/rate reduction, saturation, wow and flutter, vinyl noise.
        // In C for the same reason as the render core, and reachable both as a post-mix stage
        // inside a voice render and as an offline buffer processor.
        .target(name: "CDegrade"),
        .target(name: "Instrument", dependencies: ["MusicTheory", "SongGraph", "CVoiceRender", "CDegrade", "AudioEngine"],
                linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("Accelerate")]),
        // Turning parts into scheduled events: grooves, feels, and chopping a sample onto a feel.
        .target(name: "Performance", dependencies: ["MusicTheory", "SongGraph", "Analysis",
                                                    "Instrument", "AudioEngine"]),
        .executableTarget(name: "m0", dependencies: [
            "MusicTheory", "SongGraph", "Analysis", "AnalysisMLX", "AnalysisONNX", "AudioEngine",
            "Instrument", "Performance",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "MusicTheoryTests", dependencies: ["MusicTheory"]),
        .testTarget(name: "SongGraphTests", dependencies: ["SongGraph"]),
        .testTarget(name: "AnalysisTests", dependencies: ["Analysis"]),
        .testTarget(name: "AnalysisMLXTests", dependencies: ["AnalysisMLX"]),
        .testTarget(name: "AnalysisONNXTests", dependencies: ["AnalysisONNX"]),
        .testTarget(name: "AudioEngineTests", dependencies: ["AudioEngine"]),
        .testTarget(name: "InstrumentTests", dependencies: ["Instrument", "AudioEngine"]),
        .testTarget(name: "PerformanceTests", dependencies: ["Performance"]),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
