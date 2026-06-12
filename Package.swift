// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lens",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Lens",
            path: "Sources/Lens",
            resources: [.copy("Resources")]
        )
    ]
)
