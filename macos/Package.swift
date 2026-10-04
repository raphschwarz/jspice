// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JSpiceMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JSpice", targets: ["JSpice"]),
        .library(name: "CircuitKit", targets: ["CircuitKit"]),
    ],
    targets: [
        // The simulation engine and circuit model. No UI code, so it can be unit tested on its own.
        .target(name: "CircuitKit"),
        // The macOS app.
        .executableTarget(name: "JSpice", dependencies: ["CircuitKit"]),
        .testTarget(name: "CircuitKitTests", dependencies: ["CircuitKit"]),
    ]
)
