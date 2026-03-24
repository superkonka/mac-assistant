# BrowserAgent 浏览器自动化服务

独立的浏览器自动化服务，通过 XPC 协议与 MacAssistant 主应用通信。

## 架构

```
BrowserAgent (XPC Service)
├── Core/               # 核心逻辑
│   ├── BrowserController.swift    # 浏览器控制器
│   └── ...
├── Runtime/            # 运行时
│   ├── AppleScriptRunner.swift    # AppleScript 执行
│   └── PermissionManager.swift    # 权限管理
├── Server/             # 服务端
│   └── XPCServer.swift            # XPC 服务器
└── Client/             # 客户端 (供主应用使用)
    ├── BrowserAgentClient.swift   # 服务客户端
    └── BrowserAgentView.swift     # SwiftUI 视图
```

## 协议

基于 `BrowserAgentProtocol.swift` 定义的标准协议：

- **Command**: 导航、执行 JS、截图等
- **Response**: 统一响应格式
- **Event**: 页面加载、操作完成等事件

## 使用方式

### 1. 嵌入式 (XPC Service)

将服务打包为 XPC Service，随主应用一起启动。

### 2. 独立进程

单独运行服务进程：

```bash
swift run BrowserAgent
```

### 3. 主应用集成

```swift
import BrowserAgentClient

let client = BrowserAgentClient()
client.connect()

// 检查权限
let status = try await client.checkPermission()

// 启动会话
let sessionId = try await client.startSession(config: SessionConfig())

// 导航
try await client.navigate(sessionId: sessionId, url: "https://example.com")
```

## 开发计划

- [x] 协议定义
- [x] 核心控制器
- [x] XPC 通信
- [x] SwiftUI 客户端
- [ ] 截图功能
- [ ] 元素定位
- [ ] 自动化操作
- [ ] 测试覆盖
