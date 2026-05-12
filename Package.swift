// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "axon",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "axon", targets: ["AxonCLI"]),
        .library(name: "AxonCore", targets: ["AxonCore"])
    ],
    targets: [
        .target(name: "AxonCore"),
        .executableTarget(
            name: "AxonCLI",
            dependencies: ["AxonCore"]
        ),
        .testTarget(
            name: "AxonCoreTests",
            dependencies: ["AxonCore"]
        )
    ]
)
