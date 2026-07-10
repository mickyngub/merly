// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Merlyn",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Merlyn",
            path: "Sources/Merlyn",
            resources: [.copy("Resources")]
        )
    ]
)
