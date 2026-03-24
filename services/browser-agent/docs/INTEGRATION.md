# 与 MacAssistant 集成指南

## 架构关系

```
MacAssistant.app
├── MacAssistant (主应用)
│   └── BrowserAgentClient (客户端库)
│       └── 通过 XPC 连接服务
└── BrowserAgent.xpc (XPC 服务)
    └── BrowserAgentService (独立进程)
```

## 集成步骤

### 1. 添加 XPC 服务

将 `BrowserAgent.xpc` 复制到主应用的 `Contents/XPCServices/` 目录。

### 2. 修改主应用代码

替换原有的浏览器实现：

**原代码:**
```swift
// 直接使用 SimpleBrowserAgent
let agent = SimpleBrowserAgent.shared
agent.navigate(to: url)
```

**新代码:**
```swift
// 通过客户端连接到服务
let client = BrowserAgentClient()
client.connect()

let sessionId = try await client.startSession(config: SessionConfig())
try await client.navigate(sessionId: sessionId, url: url)
```

### 3. 修改 SwiftUI 视图

**原代码:**
```swift
SimpleBrowserAgentView()
```

**新代码:**
```swift
BrowserAgentView()
```

## 优势

1. **独立进程**: 浏览器服务崩溃不影响主应用
2. **权限隔离**: 服务独立管理权限，UI 更清晰
3. **可测试**: 可以单独测试浏览器服务
4. **可替换**: 未来可以替换为 Playwright 等其他实现

## 迁移计划

1. **Phase 1**: 完成 BrowserAgent 服务开发
2. **Phase 2**: 主应用集成客户端
3. **Phase 3**: 移除旧的浏览器代码
4. **Phase 4**: 独立优化浏览器服务
