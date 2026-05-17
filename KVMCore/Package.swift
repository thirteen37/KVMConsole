// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KVMCore",
    platforms: [
        .macOS("15.0"),
        .iOS("26.0")
    ],
    products: [
        .library(name: "KVMCore", targets: ["KVMCore"])
    ],
    targets: [
        .target(
            name: "KVMCore",
            resources: [.process("Resources.xcassets")]
        ),
        .testTarget(
            name: "KVMCoreTests",
            dependencies: ["KVMCore"]
        )
    ]
)
