// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacAssistant",
    platforms: [
        .macOS("15.0")
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MacAssistant",
            dependencies: [],
            path: "MacAssistant",
            exclude: [
                "Info.plist",
            ],
            swiftSettings: [
                .unsafeFlags(["-suppress-warnings"]),
                .define("SWIFT_DISABLE_SIL_COMBINE")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-no_warn_duplicate_libraries"])
            ]
        )
    ]
)
