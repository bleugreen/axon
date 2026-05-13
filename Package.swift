// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "axon",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "axon", targets: ["AxonCLI"]),
        .executable(name: "AxonApp", targets: ["AxonApp"]),
        .library(name: "AxonCore", targets: ["AxonCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.1")
    ],
    targets: [
        .target(
            name: "AxonCore",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ]
        ),
        .executableTarget(
            name: "AxonCLI",
            dependencies: ["AxonCore"]
        ),
        .executableTarget(
            name: "AxonApp",
            dependencies: ["AxonCore"]
        ),
        .testTarget(
            name: "AxonCoreTests",
            dependencies: ["AxonCore"]
        )
    ]
)
