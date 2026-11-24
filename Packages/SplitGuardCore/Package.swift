// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "SplitGuardCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SplitGuardCore", targets: ["SplitGuardCore"])
    ],
    dependencies: [
        .package(path: "../WireGuardEngine")
    ],
    targets: [
        .target(
            name: "SplitGuardCore",
            dependencies: [
                .product(name: "WireGuardEngine", package: "WireGuardEngine")
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "SplitGuardCoreTests",
            dependencies: [
                "SplitGuardCore",
                .product(name: "WireGuardEngine", package: "WireGuardEngine")
            ],
            resources: [.process("Fixtures")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        )
    ]
)
