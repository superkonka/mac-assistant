// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacAssistant",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MacAssistant",
            targets: ["MacAssistant"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MacAssistant",
            path: "MacAssistant",
            exclude: ["Info.plist"]
        )
    ]
)
