// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NanoKVMCore",
    platforms: [
        .macOS("15.0"),
        .iOS("26.0")
    ],
    products: [
        .library(name: "NanoKVMCore", targets: ["NanoKVMCore"])
    ],
    targets: [
        .target(name: "NanoKVMCore"),
        .testTarget(
            name: "NanoKVMCoreTests",
            dependencies: ["NanoKVMCore"]
        )
    ]
)
