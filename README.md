# 🤖 Mac Assistant

基于 OpenClaw + Kimi CLI 的 Mac 智能助手，原生菜单栏应用，让 AI 触手可及。

![Architecture](docs/architecture.png)

## ✨ 特性

- 🎯 **菜单栏悬浮窗** - 随时唤出，不打断工作流
- 🎙️ **语音输入** - 点击麦克风直接说话（使用 macOS SFSpeechRecognizer）
- 💬 **AI 对话** - 集成 OpenClaw 和 Kimi CLI
- 📸 **截图询问** - 截图后直接问 AI
- 📋 **剪贴板处理** - 复制内容一键处理
- ⌨️ **全局快捷键** - `⌘⇧Space` 快速唤起
- 🔧 **快捷指令** - 代码解释、润色、翻译、总结
- 🔔 **系统通知** - macOS 原生通知集成
- 🔄 **自动重连** - 后台服务断线自动恢复

## 🏗️ 架构

```
Mac App (SwiftUI)  ←→  Backend (Python)  ←→  OpenClaw/Kimi
     ↓                       ↓
  菜单栏图标            系统操作接口
  悬浮聊天窗            (截图/剪贴板/通知)
  全局快捷键
```

## 🚀 快速开始

### 1. 克隆项目

```bash
cd ~/code
git clone https://github.com/superkonka/mac-assistant.git
cd mac-assistant
```

### 2. 安装依赖

```bash
./scripts/setup.sh
```

### 3. 启动后端

```bash
cd backend
./start.sh
```

### 4. 构建 Mac 应用

打开 `mac-app/MacAssistant/MacAssistant.xcodeproj` 用 Xcode 构建运行。

## 📝 使用指南

### 快捷键

| 快捷键 | 功能 |
|--------|------|
| `⌘⇧Space` | 打开/关闭面板 |
| `⌘⇧1` | 截图并询问 |
| `⌘⇧V` | 询问剪贴板内容 |

### API 端点

后端服务运行在 `http://127.0.0.1:8765`

- `POST /chat` - 发送消息
- `POST /system` - 系统操作（截图/剪贴板/通知）
- `WS /ws` - WebSocket 实时通信

## 📁 项目结构

```
mac-assistant/
├── backend/               # Python 后端
│   ├── main.py           # FastAPI 服务
│   ├── requirements.txt  # 依赖
│   └── start.sh          # 启动脚本
├── mac-app/              # SwiftUI Mac 应用
│   └── MacAssistant/     # Xcode 项目
│       ├── MacAssistantApp.swift
│       ├── ContentView.swift
│       └── Services/     # 后端通信
├── scripts/              # 工具脚本
│   └── setup.sh          # 一键安装
└── docs/                 # 文档
```

## 🔧 开发

### 后端开发

```bash
cd backend
source .venv/bin/activate
python3 main.py
```

### 前端开发

用 Xcode 打开 `mac-app/MacAssistant/MacAssistant.xcodeproj`

## 🛣️ 路线图

- [ ] 文件拖放支持
- [ ] 语音输入
- [ ] 自定义提示词
- [ ] 多模型支持 (GPT-4, Claude, etc.)
- [ ] 插件系统
- [ ] 云端同步

## 📄 许可证

MIT License

## 🙏 致谢

- [OpenClaw](https://github.com/openclaw/openclaw) - AI 辅助开发框架
- [Kimi CLI](https://github.com/moonshot-ai/kimi-cli) - Moonshot AI 命令行工具
