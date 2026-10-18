// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HidhoggCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "HidhoggCore", targets: ["HidhoggCore"]),
        .executable(name: "hidhoggctl", targets: ["hidhoggctl"]),
    ],
    targets: [
        .target(name: "HidhoggCore", resources: [.process("Resources")], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "hidhoggctl", dependencies: ["HidhoggCore"]),
        .testTarget(name: "HidhoggCoreTests", dependencies: ["HidhoggCore"], resources: [.process("Resources")]),
    ]
)
