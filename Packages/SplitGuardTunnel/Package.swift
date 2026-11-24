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
        .package(path: "../../Vendor/wireguard-apple")
    ],
    targets: [
        .target(
            name: "SplitGuardTunnel",
            dependencies: [
                .product(name: "WireGuardEngine", package: "WireGuardEngine"),
                .product(name: "WireGuardKit", package: "wireguard-apple")
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "SplitGuardTunnelTests",
            dependencies: [
                "SplitGuardTunnel",
                .product(name: "WireGuardEngine", package: "WireGuardEngine"),
                .product(name: "WireGuardKit", package: "wireguard-apple")
            ]
        )
    ]
)
