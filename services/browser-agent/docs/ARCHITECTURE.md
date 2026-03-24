# BrowserAgent 服务架构

## 设计理念

BrowserAgent 是一个独立的浏览器自动化服务，通过标准协议与 MacAssistant 主应用通信。

## 架构层次

```
┌─────────────────────────────────────────────────────────┐
│  协议层 (Protocol Layer)                                 │
│  - 定义标准通信接口                                       │
│  - 支持 XPC / HTTP / WebSocket                           │
├─────────────────────────────────────────────────────────┤
│  核心层 (Core Layer)                                     │
│  - BrowserController: 浏览器控制                         │
│  - PageAnalyzer: 页面分析                                │
│  - ActionExecutor: 动作执行                              │
├─────────────────────────────────────────────────────────┤
│  运行时层 (Runtime Layer)                                │
│  - AppleScriptRuntime: Safari/Chrome 控制               │
│  - JavaScriptRuntime: 页面脚本执行                      │
│  - ScreenshotCapture: 截图捕获                          │
└─────────────────────────────────────────────────────────┘
```

## 通信协议

### 命令类型

```swift
enum BrowserCommand {
    case navigate(url: String)
    case executeJavaScript(script: String)
    case captureSnapshot
    case captureScreenshot
    case getPageInfo
    case click(x: Int, y: Int)
    case fill(selector: String, value: String)
    case pressKey(key: String)
    case startSession
    case endSession
}
```

### 响应格式

```swift
struct BrowserResponse {
    let success: Bool
    let data: BrowserData?
    let error: BrowserError?
}

enum BrowserData {
    case pageSnapshot(PageSnapshot)
    case screenshot(path: String)
    pageInfo(PageInfo)
    case jsResult(value: String)
    case void
}
```

## 权限管理

服务独立管理权限：
- 启动时检查 Safari 权限
- 提供权限引导 UI
- 权限不足时返回特定错误码

## 部署方式

1. **嵌入式**: 作为 XPC Service 随主应用启动
2. **独立进程**: 单独打包为 App/CLI 工具
3. **后台守护**: 作为 LaunchAgent 常驻后台
