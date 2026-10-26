// swift-tools-version: 6.2
import PackageDescription

// Supported toolchain: Xcode on macOS 26+ / Apple Silicon.
// Build and test with --triple arm64-apple-macosx26.0 (see CI and Makefile).

let package = Package(
    name: "Kumone",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Kumone", targets: ["KumoneLauncher"]),
        .library(name: "KumoneCore", targets: ["KumoneCore"]),
        // Offline vocal/accompaniment separation for AutoMix stem transitions; macOS only.
        .library(name: "StemKit", targets: ["StemKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
        // MLX Swift (MIT, Apple) — Metal inference runtime for StemKit.
        //
        // Pinned exactly, not ranged, for two reasons found by testing on this
        // Command Line Tools-only machine:
        //   - 0.31.1+ vendors an fmt that our clang rejects (consteval in
        //     format-inl.h), and 0.31.6+ additionally ships a CudaBuild build-tool
        //     plugin that fails to compile against our SwiftPM plugin API.
        //   - The prebuilt mlx.metallib that CLT-only builds need must match the
        //     vendored MLX version exactly; 0.30.6 vendors MLX 0.30.6, which is
        //     published on PyPI. See Scripts/fetch-mlx-metallib.sh.
        // Revisit the pin only alongside a fresh metallib fetch (and its pinned
        // sha256) and a stem separation run in a release build of the app.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.6"),
    ],
    targets: [
        .target(
            name: "KumoneCore",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .target(name: "KumoneObjC"),
            ],
            path: "Sources/Kumone",
            exclude: ["Resources"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Objective-C exception catching for the playback engine (macOS only):
        // AVFAudio reports some failures as NSExceptions Swift cannot catch.
        .target(
            name: "KumoneObjC",
            path: "Sources/KumoneObjC",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "KumoneLauncher",
            dependencies: [
                "KumoneCore",
                .product(name: "Sparkle", package: "Sparkle"),
                // AutoMix stem hand-overs: KumoneCore stays MLX-free and takes
                // a separator as a closure, which `StemSetup` installs here.
                // The built app therefore needs mlx.metallib beside its binary
                // — see Scripts/fetch-mlx-metallib.sh — and degrades to the
                // whole-mix transition path without it.
                .target(name: "StemKit"),
            ],
            path: "Sources/KumoneLauncher",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                // Sparkle.framework is embedded in Contents/Frameworks by Scripts/build-app.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // Mel-Band RoFormer vocal separation on Apple Silicon MLX/Metal.
        // Model code adapted from xocialize/mel-roformer-mlx-swift (MIT) — see the
        // per-file headers in Sources/StemKit.
        .target(
            name: "StemKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(
                    name: "MLXNN", package: "mlx-swift"),
                .product(
                    name: "MLXFFT", package: "mlx-swift"),
                .product(
                    name: "MLXFast", package: "mlx-swift"),
            ],
            path: "Sources/StemKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Checkpoint metadata plus a small GPU runtime smoke test (no model
        // weights/network). CI installs the verified kernels before testing.
        .testTarget(
            name: "StemKitTests",
            dependencies: [
                "StemKit",
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Tests/StemKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "KumoneCoreTests",
            dependencies: [
                "KumoneCore",
                .target(name: "KumoneObjC"),
            ],
            path: "Tests/KumoneCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
