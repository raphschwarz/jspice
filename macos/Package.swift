// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JSpiceMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JSpice", targets: ["JSpice"]),
        .executable(name: "jspice-mcp", targets: ["jspice-mcp"]),
        .library(name: "CircuitKit", targets: ["CircuitKit"]),
        .library(name: "JSpiceAutomation", targets: ["JSpiceAutomation"]),
    ],
    targets: [
        // The simulation engine and circuit model. No UI code, so it can be unit tested on its own.
        .target(name: "CircuitKit"),
        // Tools for driving circuits from outside: netlists, simulation runs, measurements, and an MCP server for AI agents.
        .target(name: "JSpiceAutomation", dependencies: ["CircuitKit"]),
        // The MCP server on standard input and output.
        .executableTarget(name: "jspice-mcp", dependencies: ["JSpiceAutomation"]),
        // The macOS app.
        .executableTarget(name: "JSpice", dependencies: ["CircuitKit", "JSpiceAutomation"]),
        .testTarget(name: "CircuitKitTests", dependencies: ["CircuitKit"]),
        .testTarget(name: "JSpiceAutomationTests", dependencies: ["JSpiceAutomation", "CircuitKit"]),
    ]
)
