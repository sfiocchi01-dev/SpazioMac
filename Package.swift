// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpazioMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SpazioMac", targets: ["SpazioMac"])],
    targets: [
        .target(name: "SpazioCore"),
        .executableTarget(name: "SpazioMac", dependencies: ["SpazioCore"]),
        .executableTarget(name: "SpazioCoreCheck", dependencies: ["SpazioCore"], path: "Tests/SpazioCoreTests")
    ]
)
