// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HidhoggCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "HidhoggCore", targets: ["HidhoggCore"])],
    targets: [
        .target(name: "HidhoggCore"),
        .testTarget(name: "HidhoggCoreTests", dependencies: ["HidhoggCore"]),
    ]
)
