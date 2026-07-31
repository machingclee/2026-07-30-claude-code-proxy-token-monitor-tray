// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenMonitorTray",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "TokenMonitorTray", targets: ["TokenMonitorTray"]),
    ],
    targets: [
        .executableTarget(
            name: "TokenMonitorTray",
            path: "Sources/TokenMonitorTray",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
