// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Merly",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Merly",
            path: "Sources/Merly",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "MerlyTests",
            dependencies: ["Merly"],
            path: "Tests/MerlyTests"
        ),
    ]
)
