// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "WireGuardEngine",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [.library(name: "WireGuardEngine", targets: ["WireGuardEngine"])],
    targets: [
        .target(name: "WireGuardEngine"),
        .testTarget(name: "WireGuardEngineTests", dependencies: ["WireGuardEngine"])
    ]
)
