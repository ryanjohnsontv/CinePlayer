// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CinePlayerCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CinePlayerCore", targets: ["CinePlayerCore"]),
        .executable(name: "cine-diagnostic", targets: ["cine-diagnostic"]),
        .executable(name: "cine-scrub-bench", targets: ["cine-scrub-bench"]),
        .executable(name: "cine-lut-verify", targets: ["cine-lut-verify"]),
        .executable(name: "cine-batch-convert", targets: ["cine-batch-convert"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ryanjohnsontv/CineKit.git", from: "0.1.0"),
    ],
    targets: [
        .plugin(
            name: "MetalShaderPlugin",
            capability: .buildTool()
        ),
        .target(
            name: "CinePlayerCore",
            dependencies: [
                .product(name: "CineKit", package: "CineKit"),
            ],
            plugins: [
                "MetalShaderPlugin",
            ]
        ),
        .executableTarget(
            name: "cine-diagnostic",
            dependencies: [
                "CinePlayerCore",
            ]
        ),
        .executableTarget(
            name: "cine-scrub-bench",
            dependencies: [
                "CinePlayerCore",
            ]
        ),
        .executableTarget(
            name: "cine-lut-verify",
            dependencies: [
                "CinePlayerCore",
            ]
        ),
        .executableTarget(
            name: "wb-verify",
            dependencies: [
                "CinePlayerCore",
            ]
        ),
        .executableTarget(
            name: "cine-batch-convert",
            dependencies: [
                "CinePlayerCore",
            ]
        ),
        .testTarget(
            name: "CinePlayerCoreTests",
            dependencies: [
                "CinePlayerCore",
            ]
        ),
    ]
)
