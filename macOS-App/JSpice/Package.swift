// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JSpice",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "JSpice", targets: ["JSpice"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "JSpice",
            dependencies: [],
            path: "JSpice",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .define("TESTING", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "JSpiceTests",
            dependencies: ["JSpice"],
            path: "Tests"
        )
    ]
)
