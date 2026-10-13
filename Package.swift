// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lucent",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Lucent", path: "Sources/Lucent")
    ]
)
