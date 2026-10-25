// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "lgmon",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "lgmon",
            path: "Sources/lgmon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
