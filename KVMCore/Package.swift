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
    dependencies: [
        .package(url: "https://github.com/webrtc-sdk/Specs.git", exact: "125.6422.02")
    ],
    targets: [
        .target(
            name: "KVMCore",
            dependencies: [
                .product(name: "WebRTC", package: "Specs")
            ]
        ),
        .testTarget(
            name: "KVMCoreTests",
            dependencies: ["KVMCore"]
        )
    ]
)
