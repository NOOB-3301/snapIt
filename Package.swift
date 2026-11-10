// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SnapIt",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "SnapItCore"),
        .executableTarget(name: "SnapIt", dependencies: ["SnapItCore"]),
        .testTarget(name: "SnapItCoreTests", dependencies: ["SnapItCore"]),
    ]
)
