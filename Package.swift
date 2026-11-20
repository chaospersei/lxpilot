// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LxPilot",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "LxPilot",
            path: "Sources/LxPilot",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
