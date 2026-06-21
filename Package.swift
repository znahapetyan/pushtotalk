// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Talk",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Talk",
            path: "Sources/Talk"
        )
    ]
)
