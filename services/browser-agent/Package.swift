// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BrowserAgent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BrowserAgentService", targets: ["BrowserAgentService"]),
        .library(name: "BrowserAgentProtocol", targets: ["BrowserAgentProtocol"]),
        .library(name: "BrowserAgentClient", targets: ["BrowserAgentClient"]),
    ],
    targets: [
        // 协议定义
        .target(
            name: "BrowserAgentProtocol",
            path: "Sources"
        ),
        
        // 服务端
        .executableTarget(
            name: "BrowserAgentService",
            dependencies: ["BrowserAgentProtocol"],
            path: "Sources",
            sources: [
                "Core",
                "Runtime",
                "Server",
                "main.swift"
            ]
        ),
        
        // 客户端
        .target(
            name: "BrowserAgentClient",
            dependencies: ["BrowserAgentProtocol"],
            path: "Sources",
            sources: [
                "Client"
            ]
        ),
    ]
)
