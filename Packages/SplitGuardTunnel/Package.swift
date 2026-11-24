// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "SplitGuardTunnel",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SplitGuardTunnel", targets: ["SplitGuardTunnel"])
    ],
    dependencies: [
        .package(path: "../WireGuardEngine"),
        .package(path: "../SplitGuardCore")
    ],
    targets: [
        .target(
            name: "SplitGuardTunnel",
            dependencies: [
                .product(name: "WireGuardEngine", package: "WireGuardEngine"),
                .product(name: "SplitGuardCore", package: "SplitGuardCore")
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        )
    ]
)
