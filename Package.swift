// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LxPilot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LxPilot",
            path: "Sources/LxPilot"
        )
    ]
)
