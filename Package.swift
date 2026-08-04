// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeTrayMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeTrayMonitor",
            path: "Sources/ClaudeTrayMonitor"
        )
    ]
)