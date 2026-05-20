// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Pelu",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PeluCore",
            targets: ["PeluCore"]
        ),
        .library(
            name: "PeluUI",
            targets: ["PeluUI"]
        ),
        .executable(
            name: "PeluMacPrototype",
            targets: ["PeluMacPrototype"]
        ),
    ],
    targets: [
        .target(
            name: "PeluCore"
        ),
        .target(
            name: "PeluUI",
            dependencies: ["PeluCore"]
        ),
        .executableTarget(
            name: "PeluMacPrototype",
            dependencies: ["PeluCore", "PeluUI"]
        ),
        .testTarget(
            name: "PeluCoreTests",
            dependencies: ["PeluCore", "PeluUI"]
        ),
    ]
)
