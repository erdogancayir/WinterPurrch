// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WinterPurrch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WinterPurrch",
            path: "Sources/WinterPurrch",
            swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))]
        ),
    ]
)
