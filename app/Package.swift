// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hidhogg",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Hidhogg", targets: ["HidhoggApp"])
    ],
    targets: [
        .executableTarget(name: "HidhoggApp")
    ]
)
