// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StorageWatch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "StorageWatch",
            path: "Sources/StorageWatch"
        )
    ]
)
