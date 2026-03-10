// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacAssistant",
    platforms: [
        .macOS("15.0")
    ],
    dependencies: [
        .package(path: "../../openclaw-core/apps/shared/OpenClawKit"),
    ],
    targets: [
        .executableTarget(
            name: "MacAssistant",
            dependencies: [
                .product(name: "OpenClawKit", package: "OpenClawKit"),
                .product(name: "OpenClawProtocol", package: "OpenClawKit"),
                .product(name: "OpenClawChatUI", package: "OpenClawKit"),
            ],
            path: "MacAssistant",
            exclude: [
                "Info.plist",
                "ContentView.swift",
                "AgentSystem",
                "Analytics/ConversationAnalyzer.swift",
                "Analytics/ConversationAnalyzerView.swift",
            ],
            sources: [
                "MacAssistantApp.swift",
                "Models",
                "Services",
                "Views",
                "Storage",
                "Utils",
                "Analytics",
                "AutoAgent",
                "Distillation",
                "Skills",
            ],
            swiftSettings: [
                .unsafeFlags(["-suppress-warnings"])
            ]
        )
    ]
)
