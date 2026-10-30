// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReactCheckCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReactCheckCore", targets: ["ReactCheckCore"]),
    ],
    targets: [
        .target(
            name: "ReactCheckCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ReactCheckCoreTests",
            dependencies: ["ReactCheckCore"],
            resources: [.copy("Golden")]
        ),
    ]
)
