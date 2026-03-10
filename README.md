# Mac Assistant

基于 SwiftUI、OpenClaw Gateway wrapper 和可配置 Agent 运行时的 macOS 原生助手。

当前仓库已经不再是最早期的“菜单栏壳 + Python 后端”原型，而是一套以本地 Mac App 为主、可动态接入 Kimi CLI / 远端 LLM / 内置原生 Skill 的多 Agent 框架。README 以当前实现为准。

## 当前能力

- 原生 macOS 聊天窗口和菜单栏入口，支持截图询问、剪贴板询问、日志查看。
- 多 Agent 管理和能力路由，支持按能力选择文本、代码、视觉、长文档等模型。
- 运行时同步可用 Agent 到本地 OpenClaw Gateway wrapper，统一走会话、流式事件和历史恢复。
- `Kimi CLI`、`OpenAI`、`Anthropic`、`Google`、`Moonshot` 等 provider 接入。
- 自愈链路：鉴权失败检测、坏 Agent 临时下线、降级到其他可用 Agent、无 Agent 时自动拉起配置向导。
- `Kimi CLI` 登录失效检测，可引导执行 `kimi login` 恢复认证。
- 内置 `Mac 操作 Agent`，用 macOS 原生接口直接处理应用枚举、启动、退出、状态检查，避免 LLM 幻觉式“成功回执”。
- 内置 Skill 系统、Agent 创建流和 `Skill 迭代顾问`，能基于使用情况提出优化提案并等待用户确认。
- 富文本聊天渲染，支持标题、列表、引用、代码块和 Markdown 表格的结构化显示。

## 架构概览

主链路现在是：

```text
SwiftUI Mac App
  ├─ ChatView / MessageBubble / RichTextView
  ├─ CommandRunner
  ├─ AgentStore / AgentOrchestrator
  ├─ MacSystemAgent
  └─ OpenClawGatewayClient
          │
          ▼
OpenClawGatewayRuntimeManager
  ├─ 根据当前可用 Agent 生成 wrapper 配置
  ├─ 启动本地 gateway（默认 ws://127.0.0.1:18889）
  └─ 将 CLI / 远端 provider 统一成可路由模型
          │
          ▼
Kimi CLI / OpenAI / Anthropic / Google / Moonshot
```

辅助链路仍然保留：

- `backend/`：FastAPI 本地服务，端口默认 `8765`，适合独立调试、打包或保留旧接口兼容。
- `daemon/`：`launchd` 管理脚本，用来安装/管理 Python backend。
- `openclaw-core/`：本地 OpenClaw 源码与 `OpenClawKit` package，Xcode 工程直接引用其本地 package。

## 核心模块

- `mac-app/MacAssistant/MacAssistant/MacAssistantApp.swift`：应用入口、菜单栏、主窗口、日志窗口。
- `mac-app/MacAssistant/MacAssistant/Services/CommandRunner.swift`：主对话编排器，负责输入解析、Skill/Agent 路由、自愈和会话状态。
- `mac-app/MacAssistant/MacAssistant/Services/AgentStore.swift`：Agent 持久化、可用性检测、认证验证、OpenClaw 配置同步。
- `mac-app/MacAssistant/MacAssistant/Services/AgentOrchestrator.swift`：意图分析和能力路由。
- `mac-app/MacAssistant/MacAssistant/Services/OpenClawGatewayRuntimeManager.swift`：本地 gateway wrapper 生命周期和运行时配置生成。
- `mac-app/MacAssistant/MacAssistant/Services/OpenClawGatewayClient.swift`：发送消息、消费流式事件、history 恢复和异常收敛。
- `mac-app/MacAssistant/MacAssistant/Services/MacSystemAgent.swift`：原生 macOS 应用操作代理。
- `mac-app/MacAssistant/MacAssistant/Services/SkillEvolutionAdvisor.swift`：根据 Skill 使用数据提出演进建议。

## 仓库结构

```text
mac-assistant/
├── mac-app/
│   ├── MacAssistant/
│   │   ├── MacAssistant.xcodeproj
│   │   ├── Package.swift
│   │   └── MacAssistant/
│   │       ├── AutoAgent/
│   │       ├── Distillation/
│   │       ├── Models/
│   │       ├── Services/
│   │       ├── Skills/
│   │       ├── Storage/
│   │       ├── Utils/
│   │       └── Views/
│   ├── restart.sh
│   └── test_logs.sh
├── backend/
│   ├── main.py
│   ├── kimi_provider.py
│   ├── requirements.txt
│   └── start.sh
├── daemon/
│   ├── com.mac-assistant.backend.plist
│   └── service-manager.sh
├── scripts/
│   ├── setup.sh
│   ├── restart.sh
│   └── diagnose.sh
├── docs/
├── build/
└── openclaw-core/
```

## 环境要求

- macOS 15+
- Xcode 16+（建议 16.4 或更高）
- Python 3.11+（仅在使用 `backend/` 时必需）
- 可选：`kimi` CLI
- 可选：OpenAI / Anthropic / Google / Moonshot 等 provider API Key

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/superkonka/mac-assistant.git
cd mac-assistant
```

### 2. 构建并启动 Mac App

最直接的方式是用 Xcode 打开：

```bash
open mac-app/MacAssistant/MacAssistant.xcodeproj
```

也可以直接命令行构建：

```bash
xcodebuild \
  -project mac-app/MacAssistant/MacAssistant.xcodeproj \
  -scheme MacAssistant \
  -configuration Debug \
  build
```

### 3. 首次运行配置 Agent

首次启动如果没有任何可用 Agent，应用会自动进入配置向导。

- 使用 `Kimi CLI`：
  1. 确保本机有 `kimi` 命令
  2. 执行 `kimi login`
  3. 回到应用里测试连接
- 使用远端 provider：
  1. 在向导中选择 provider
  2. 输入 API Key
  3. 通过连接测试后创建 Agent

### 4. 可选：启动 Python backend

如果你需要保留本地 FastAPI 服务：

```bash
./scripts/setup.sh
cd daemon
./service-manager.sh install
```

单独调试时也可以：

```bash
cd backend
./start.sh
```

健康检查：

```bash
curl http://127.0.0.1:8765/health
```

## 自愈与恢复机制

当前已经实现的自愈能力：

- 鉴权失败会被识别为 `401/403`，而不是当成普通文本错误继续传播。
- 失效的远端 Agent 会被临时移出可用列表，避免反复命中同一条坏配置。
- 如果还有其他可用 Agent，会自动改用其他 Agent 继续完成请求。
- 如果一个可用 Agent 都没有，会直接引导进入 Agent 配置向导。
- `Kimi CLI` 登录失效时，会提示并可引导执行 `kimi login`。
- 对应用启动类操作，系统会验证进程和端口状态，不会在实际失败时谎报成功。

当前还没有做的事：

- 无法自动修复第三方 API Key 本身。
- 某些依赖系统权限或第三方 App 内部状态的动作，仍然需要用户手动授权或确认。

## 常用开发命令

### 构建 Mac App

```bash
xcodebuild \
  -project mac-app/MacAssistant/MacAssistant.xcodeproj \
  -scheme MacAssistant \
  -configuration Debug \
  -quiet build
```

### 重启应用

```bash
pkill -f "/MacAssistant.app/Contents/MacOS/MacAssistant"
open ~/Library/Developer/Xcode/DerivedData/MacAssistant-*/Build/Products/Debug/MacAssistant.app
```

### 管理 backend 守护进程

```bash
cd daemon
./service-manager.sh status
./service-manager.sh logs
./service-manager.sh restart
```

## 日志与排障

- App 运行日志：`~/Documents/MacAssistant/Logs/mac-assistant-current.log`
- 对话事件日志：`~/Documents/MacAssistant/ConversationLogs`
- Backend 日志：`~/code/mac-assistant/daemon/backend.log`

应用内也提供：

- 菜单栏 `查看日志`
- 菜单栏 `打开日志目录`

## 当前内置 Skill / Agent 方向

- `/system`：系统信息
- `/file`：文件与目录
- `/app`：macOS 应用操作
- `/web`：网页搜索与打开
- `/git`：Git 状态和日志
- `/futu`：FutuOpenD 启停和状态检查
- `Mac 操作 Agent`：在高置信度场景下优先于 LLM 执行
- `Skill 迭代顾问`：对运行时 Skill 提出改进建议并等待确认

## 注意事项

- Xcode 工程依赖仓库内的本地 `openclaw-core/apps/shared/OpenClawKit` package，不要随意改动目录结构。
- `Kimi CLI` 不是永久登录态，过期后需要重新执行 `kimi login`。
- 当前 README 已同步到最新实现，但 `docs/` 里仍有部分历史设计文档，阅读时请以代码和本 README 为准。

## License

MIT
