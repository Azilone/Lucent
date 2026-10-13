// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vivid",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Vivid", path: "Sources/Vivid")
    ]
)
