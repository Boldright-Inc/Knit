// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Knit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "KnitCore", targets: ["KnitCore"]),
        .executable(name: "knit", targets: ["KnitCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CDeflate",
            path: "Sources/CDeflate",
            exclude: [
                "src/x86/cpu_features.c",
                "src/riscv",
            ],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .unsafeFlags(["-O3"], .when(configuration: .release)),
            ]
        ),
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            exclude: [
                "src/decompress/huf_decompress_amd64.S",
            ],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("src/common"),
                .define("ZSTD_MULTITHREAD", to: "1"),
                .define("ZSTD_DISABLE_ASM", to: "1"),
                .unsafeFlags(["-O3"], .when(configuration: .release)),
            ]
        ),
        .target(
            name: "CZlibBridge",
            path: "Sources/CZlibBridge",
            sources: ["bridge.c"],
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-O3"], .when(configuration: .release)),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
        .target(
            name: "KnitCore",
            dependencies: ["CDeflate", "CZstd", "CZlibBridge"],
            path: "Sources/KnitCore",
            resources: [
                .process("Engine/MetalKernels"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "KnitCLI",
            dependencies: [
                "KnitCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/KnitCLI"
        ),
        // Note: tests are intentionally not declared as a SwiftPM target.
        // The Tests/ directory may or may not be present in distribution
        // clones, and SwiftPM caches package evaluation in a way that makes
        // dynamic test-target inclusion unreliable. To run tests during
        // development, see Package.dev.swift (loaded via the helper script
        // Scripts/run-tests.sh).
    ]
)
