// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hidhogg",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Hidhogg", targets: ["HidhoggApp"]),
        .executable(name: "hidhoggctl", targets: ["HidhoggCLI"]),
        .executable(name: "flowlite84-status", targets: ["FlowLite84StatusProbe"])
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", exact: "2.0.0")
    ],
    targets: [
        .target(name: "HidhoggDomain"),
        .target(name: "GenericBluetooth", dependencies: ["HidhoggDomain"]),
        .target(name: "HidhoggConfiguration", dependencies: ["HidhoggDomain", .product(name: "TOML", package: "swift-toml")]),
        .target(name: "LogitechBolt", dependencies: ["HidhoggDomain"]),
        .target(name: "UlanziD200X"),
        .target(name: "LofreeFlowLite84"),
        .executableTarget(name: "FlowLite84StatusProbe", dependencies: ["LofreeFlowLite84"]),
        .target(name: "HidhoggAutomation", dependencies: ["HidhoggDomain"]),
        .executableTarget(name: "HidhoggCLI", dependencies: ["HidhoggAutomation"]),
        .target(name: "MacOSActions", dependencies: ["HidhoggDomain"]),
        .executableTarget(name: "HidhoggApp", dependencies: ["HidhoggDomain", "HidhoggConfiguration", "LogitechBolt", "MacOSActions", "UlanziD200X", "HidhoggAutomation", "LofreeFlowLite84", "GenericBluetooth"]),
        .testTarget(name: "GenericBluetoothTests", dependencies: ["GenericBluetooth", "HidhoggDomain"]),
        .testTarget(name: "LofreeFlowLite84Tests", dependencies: ["LofreeFlowLite84"]),
        .testTarget(name: "HidhoggAutomationTests", dependencies: ["HidhoggAutomation", "HidhoggDomain"]),
        .testTarget(name: "UlanziD200XTests", dependencies: ["UlanziD200X"]),
        .testTarget(name: "HidhoggConfigurationTests", dependencies: ["HidhoggConfiguration", "HidhoggDomain"]),
        .testTarget(name: "LogitechBoltTests", dependencies: ["LogitechBolt", "HidhoggDomain"]),
        .testTarget(name: "MacOSActionsTests", dependencies: ["MacOSActions", "HidhoggDomain"]),
        .testTarget(name: "HidhoggAppTests", dependencies: ["HidhoggApp", "HidhoggDomain", "HidhoggConfiguration", "LogitechBolt", "MacOSActions", "UlanziD200X", "LofreeFlowLite84", "GenericBluetooth"])
    ]
)
