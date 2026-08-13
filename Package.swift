// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "axon",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "axon", targets: ["AxonCLI"]),
        .executable(name: "AxonDaemonApp", targets: ["AxonDaemonApp"]),
        .executable(name: "AxonEditorApp", targets: ["AxonEditorApp"]),
        .library(name: "AxonCore", targets: ["AxonCore"]),
        .executable(name: "tool-surface-exporter", targets: ["ToolSurfaceExporter"])
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
            name: "ToolSurfaceExporter",
            dependencies: ["AxonCore"]
        ),
        .executableTarget(
            name: "AxonCLI",
            dependencies: ["AxonCore"]
        ),
        .executableTarget(
            name: "AxonDaemonApp",
            dependencies: ["AxonCore"]
        ),
        .executableTarget(
            name: "AxonEditorApp",
            dependencies: ["AxonCore"]
        ),
        .executableTarget(
            name: "AxonReorderFixtureApp"
        ),
        .executableTarget(
            name: "SemanticNameStudy",
            dependencies: ["AxonCore"]
        ),
        .testTarget(
            name: "AxonCoreTests",
            dependencies: ["AxonCore"]
        )
    ]
)
