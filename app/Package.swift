// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hidhogg",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Hidhogg", targets: ["HidhoggApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", exact: "2.0.0")
    ],
    targets: [
        .target(name: "HidhoggDomain"),
        .target(name: "HidhoggConfiguration", dependencies: ["HidhoggDomain", .product(name: "TOML", package: "swift-toml")]),
        .target(name: "LogitechBolt", dependencies: ["HidhoggDomain"]),
        .target(name: "MacOSActions", dependencies: ["HidhoggDomain"]),
        .executableTarget(name: "HidhoggApp", dependencies: ["HidhoggDomain", "HidhoggConfiguration", "LogitechBolt", "MacOSActions"]),
        .testTarget(name: "HidhoggConfigurationTests", dependencies: ["HidhoggConfiguration", "HidhoggDomain"]),
        .testTarget(name: "LogitechBoltTests", dependencies: ["LogitechBolt", "HidhoggDomain"]),
        .testTarget(name: "MacOSActionsTests", dependencies: ["MacOSActions", "HidhoggDomain"]),
        .testTarget(name: "HidhoggAppTests", dependencies: ["HidhoggApp", "HidhoggDomain", "HidhoggConfiguration", "LogitechBolt", "MacOSActions"])
    ]
)
