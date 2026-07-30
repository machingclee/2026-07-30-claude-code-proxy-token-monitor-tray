// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GMTray",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "GMTray", targets: ["GMTray"]),
    ],
    targets: [
        .executableTarget(
            name: "GMTray",
            path: "Sources/GMTray",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
