// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "axon",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "axon", targets: ["AxonCLI"]),
        .executable(name: "AxonEditorApp", targets: ["AxonEditorApp"]),
        .executable(name: "AxonMenuApp", targets: ["AxonMenuApp"]),
        .library(name: "AxonClient", targets: ["AxonClient"]),
        .library(name: "AxonCore", targets: ["AxonCore"]),
        .executable(name: "tool-surface-exporter", targets: ["ToolSurfaceExporter"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.1")
    ],
    targets: [
        // The unprivileged half of Axon: the socket client, health and contract models, bundle and
        // launchd plumbing, and the updater. Nothing here may call a privacy-gated API, because the
        // menu shell links only this; `PrivacyBoundaryTests` enforces it.
        .target(
            name: "AxonClient"
        ),
        .target(
            name: "AxonCore",
            dependencies: [
                "AxonClient",
                .product(name: "Yams", package: "Yams")
            ]
        ),
        .executableTarget(
            name: "ToolSurfaceExporter",
            dependencies: ["AxonClient", "AxonCore"]
        ),
        .executableTarget(
            name: "AxonCLI",
            dependencies: ["AxonClient", "AxonCore"]
        ),
        .executableTarget(
            name: "AxonEditorApp",
            dependencies: ["AxonClient", "AxonCore"]
        ),
        // The menu shell. It depends on AxonClient alone, so nothing that calls a privacy-gated API
        // is reachable from it; the daemon does that work under its own identity.
        .executableTarget(
            name: "AxonMenuApp",
            dependencies: ["AxonClient"]
        ),
        .executableTarget(
            name: "AxonReorderFixtureApp"
        ),
        .testTarget(
            name: "AxonCoreTests",
            dependencies: ["AxonClient", "AxonCore"]
        ),
        .testTarget(
            name: "AxonClientTests",
            dependencies: ["AxonClient"]
        ),
        .testTarget(
            name: "AxonMenuAppTests",
            dependencies: ["AxonClient", "AxonMenuApp"]
        )
    ]
)
