# Mac Assistant 架构文档

## 系统架构

```
┌─────────────────────────────────────┐
│      Mac App (SwiftUI)              │
│  - 菜单栏状态图标                      │
│  - 悬浮聊天窗口                        │
│  - 全局快捷键                         │
│  - 系统通知                           │
└──────────┬──────────────────────────┘
           │ HTTP/WebSocket
           ▼
┌─────────────────────────────────────┐
│      Backend (Python/FastAPI)       │
│  - REST API                         │
│  - WebSocket 实时通信                │
│  - OpenClaw 集成                    │
│  - Kimi CLI 封装                     │
│  - 系统操作接口                      │
└──────────┬──────────────────────────┘
           │
    ┌──────┴──────┬──────────────┐
    ▼             ▼              ▼
┌─────────┐  ┌─────────┐  ┌──────────┐
│OpenClaw │  │Kimi CLI │  │macOS API │
│Gateway  │  │         │  │(AppleScript│
└─────────┘  └─────────┘  └──────────┘
```

## 核心功能

### 1. 聊天对话
- WebSocket 实时通信
- 历史记录持久化
- 支持 Markdown 渲染

### 2. 系统集成
- 截图 → AI 分析
- 剪贴板 → AI 处理
- 文件拖放 → AI 解读

### 3. 快捷指令
- 代码解释
- 文本润色
- 翻译
- 总结

## API 端点

### REST API
- `GET /health` - 健康检查
- `POST /chat` - 发送消息
- `POST /command` - 执行命令
- `POST /system` - 系统操作
- `GET /history` - 获取历史

### WebSocket
- `ws://localhost:8765/ws` - 实时通信

## 技术栈

### 后端
- Python 3.11+
- FastAPI
- WebSockets
- Pydantic

### 前端
- SwiftUI
- AppKit
- Combine

## 数据流

1. 用户输入 → Mac App
2. Mac App → HTTP POST /chat
3. Backend → OpenClaw/Kimi
4. AI 响应 → Backend
5. Backend → Mac App
6. Mac App 展示结果

## 安全考虑

- 本地服务只监听 127.0.0.1
- 无外部网络请求（除非调用 AI）
- 敏感操作需要用户确认
