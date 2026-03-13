# Mac Assistant

基于 SwiftUI、OpenClaw Gateway wrapper 和可配置 Agent 运行时的 macOS 原生助手。

当前仓库已经不再是最早期的“菜单栏壳 + Python 后端”原型，而是一套以本地 Mac App 为主、可动态接入 `Kimi CLI` / 远端 LLM / 内置原生 Skill / OpenClaw Skills 的多 Agent 框架。README 以当前实现为准。

## 当前能力

- 原生 macOS 聊天窗口和菜单栏入口，支持截图询问、剪贴板询问、日志查看。
- 多 Agent 管理和能力路由，支持按能力选择文本、代码、视觉、长文档等模型。
- Agent 角色分工：支持 `主会话`、`Planner`、`子任务 Worker`、`回退池`、`仅手动`。
- 统一 `Planner / Dispatcher / Result Collector / Self-heal` 链路，支持主会话、独立 side task 和部分并行子任务。
- 运行时同步可用 Agent 到本地 OpenClaw Gateway wrapper，统一走会话、流式事件和历史恢复。
- provider 接入：`Kimi CLI`、`DeepSeek`、`Doubao`、`Zhipu`、`OpenAI`、`Anthropic`、`Google`、`Moonshot`。
- `Planner Console`：支持规则优先、Planner Agent 接管、影子对比、最近 diff 观察。
- 自愈链路：鉴权失败检测、坏 Agent 临时下线、降级到其他可用 Agent、无 Agent 时自动拉起配置向导。
- `Kimi CLI` 登录失效检测，可引导执行 `kimi login` 恢复认证。
- `OpenClaw Doctor`：在主界面展示 Claw 运行状态，支持诊断、自动修复、重装和打开运行目录/日志。
- 内置 `Mac 操作 Agent`，用 macOS 原生接口直接处理应用枚举、启动、退出、状态检查，避免 LLM 幻觉式“成功回执”。
- 内置 Skill 系统、Agent 创建流和 `Skill 迭代顾问`，能基于使用情况提出优化提案并等待用户确认。
- `ClawHub Marketplace`：支持登录、搜索、安装、卸载、更新外部 OpenClaw Skills。
- 富文本聊天渲染，支持标题、列表、引用、代码块和 Markdown 表格的结构化显示。

## 架构概览

主链路现在是：

```text
SwiftUI Mac App
  ├─ ChatView / MessageBubble / RichTextView
  ├─ ConversationController
  ├─ ContextAssembler
  ├─ RequestPlanner
  ├─ TaskSupervisor
  ├─ ResultReducer / ConversationStores
  ├─ AgentStore / AgentOrchestrator / MacSystemAgent
  └─ ClawRuntimeAdapter (OpenClawGatewayClient)
          │
          ▼
OpenClawGatewayRuntimeManager
  ├─ 根据当前可用 Agent 生成 wrapper 配置
  ├─ 启动本地 gateway（默认 ws://127.0.0.1:18889）
  ├─ 管理本地 OpenClaw runtime / skills / logs
  └─ 将 CLI / 远端 provider 统一成可路由模型
          │
          ▼
Kimi CLI / DeepSeek / Doubao / Zhipu / OpenAI / Anthropic / Google / Moonshot
```

当前调度逻辑不是“所有请求都直接进一个 LLM”，而是固定阶段的模块链：

```text
UI
  -> ConversationController
  -> ContextAssembler
  -> Planner
  -> TaskSupervisor
  -> ClawRuntimeAdapter(OpenClaw)
  -> ResultReducer
  -> Stores
```

其中：

- `ConversationController` 负责给 UI 提供统一会话入口和观察态，避免 `ChatView` 直接绑定底层运行时。
- `ContextAssembler` 负责把截图、最近消息、当前 Agent、可恢复 task context 组装成 `RequestEnvelope`。
- `Planner` 负责判定这次请求是主对话、配置向导、系统操作、URL 研究、Skill 建议还是 side task。
- `TaskSupervisor` 负责承接规划结果，并驱动主会话、独立子任务和恢复链路。
- `ClawRuntimeAdapter` 负责把 OpenClaw runtime 调用收口到单一适配层。
- `ResultReducer` 负责把运行态压成 UI 可消费的 `ConversationStores`。
- `Self-heal` 负责 Agent 回退、Kimi 登录恢复、OpenClaw 诊断与重装。

辅助链路仍然保留：

- `backend/`：FastAPI 本地服务，端口默认 `8765`，适合独立调试、打包或保留旧接口兼容。
- `daemon/`：`launchd` 管理脚本，用来安装/管理 Python backend。
- `openclaw-core/`：本地 OpenClaw 源码与 `OpenClawKit` package，Xcode 工程直接引用其本地 package。

## 核心模块

- `mac-app/MacAssistant/MacAssistant/MacAssistantApp.swift`：应用入口、菜单栏、主窗口、日志窗口。
- `mac-app/MacAssistant/MacAssistant/Services/ConversationController.swift`：UI 会话控制器，统一收口发送入口和观察态。
- `mac-app/MacAssistant/MacAssistant/Services/ContextAssembler.swift`：会话上下文组装器，负责形成 `RequestEnvelope`。
- `mac-app/MacAssistant/MacAssistant/Services/CommandRunner.swift`：主对话编排器，负责 planner 决策执行、主会话、side task、自愈和 trace。
- `mac-app/MacAssistant/MacAssistant/Services/RequestPlanner.swift`：统一请求规划器，负责判定请求类型和执行模式。
- `mac-app/MacAssistant/MacAssistant/Services/TaskSupervisor.swift`：任务承接和 task session 监督层。
- `mac-app/MacAssistant/MacAssistant/Services/IntentAgentShadowPlannerProvider.swift`：独立 Planner Agent 的影子判定接口。
- `mac-app/MacAssistant/MacAssistant/Services/AgentStore.swift`：Agent 持久化、可用性检测、认证验证、角色分配、OpenClaw 配置同步。
- `mac-app/MacAssistant/MacAssistant/Services/AgentOrchestrator.swift`：能力路由和当前 Agent 协同。
- `mac-app/MacAssistant/MacAssistant/Services/ClawRuntimeAdapter.swift`：OpenClaw runtime 适配层。
- `mac-app/MacAssistant/MacAssistant/Services/ResultReducer.swift`：把运行态收敛成 UI Stores。
- `mac-app/MacAssistant/MacAssistant/Services/OpenClawGatewayRuntimeManager.swift`：本地 gateway wrapper 生命周期和运行时配置生成。
- `mac-app/MacAssistant/MacAssistant/Services/OpenClawGatewayClient.swift`：发送消息、消费流式事件、history 恢复和异常收敛。
- `mac-app/MacAssistant/MacAssistant/Services/MacSystemAgent.swift`：原生 macOS 应用操作代理。
- `mac-app/MacAssistant/MacAssistant/Models/ConversationPipelineModels.swift`：Conversation Stores 和组装后的请求模型。
- `mac-app/MacAssistant/MacAssistant/Services/DependencyManager.swift` + `OpenClawDoctor.swift`：OpenClaw runtime 检测、安装、修复、重装。
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
- 可选：DeepSeek / Doubao / Zhipu / OpenAI / Anthropic / Google / Moonshot 等 provider API Key

> 当前最低版本仍然是 `macOS 15+`。  
> 输入组件已经做了兼容双路径准备，但整个工程仍受 `OpenClawKit / OpenClawChatUI / ElevenLabsKit / Textual` 这条依赖链限制，暂时不能真正下探到更低系统版本。

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
  3. 选择角色：主会话 / Planner / 子任务 / 回退 / 仅手动
  4. 通过连接测试后创建 Agent

### 4. 配置 Agent 角色

当前推荐的角色分工：

- `主会话 Agent`：负责与你直接对话，例如 `Kimi CLI` 或稳定文本模型。
- `Planner Agent`：负责意图分析和链路规划，适合便宜、快、结构化输出稳定的模型。
- `子任务 Worker`：负责 URL 研究、视觉、文档抓取、side task。
- `回退 Agent`：负责主 Agent 失败后的兜底。
- `仅手动`：不参与自动路由，只在你显式选中或显式调用时使用。

### 5. 可选：启动 Python backend

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
- OpenClaw runtime 会优先使用应用自管版本，并支持诊断、自动修复、重装和日志查看。
- 对应用启动类操作，系统会验证进程和端口状态，不会在实际失败时谎报成功。
- 中断任务支持本地 journal + history 回捞，部分链路支持“继续处理”。

当前还没有做的事：

- 无法自动修复第三方 API Key 本身。
- 某些依赖系统权限或第三方 App 内部状态的动作，仍然需要用户手动授权或确认。
- Planner Agent 目前仍建议先在 shadow mode 下观察 diff，再决定是否正式接管主意图分析。

## Planner Console

在 `Skills > 设置` 里可以看到当前链路模块：

- `Planner`
- `Dispatcher`
- `Link Research`
- `Result Collector`
- `Local System Guard`
- `Fallback / Self-heal`

当前支持的 Planner 方式：

- `规则优先`
- `Planner Agent 接管`
- `影子对比`

影子模式下，系统会额外跑一条 Planner Agent 判定，但不接管主流程，只记录 `MATCH / DIFF` 供后续调整。

## Skills 与市场

- 内置 Skills：系统、文件、网页、Futu、Git 等。
- `ClawHub Marketplace`：可登录、搜索、安装、卸载、更新外部 OpenClaw Skills。
- 安装目标默认是 OpenClaw wrapper 的 `workspace/skills`，安装后会自动刷新 runtime。

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
- `Planner Console`：查看意图分析、调度和影子判定状态
- `Claw Doctor`：查看和修复 OpenClaw 运行时状态

## 注意事项

- Xcode 工程依赖仓库内的本地 `openclaw-core/apps/shared/OpenClawKit` package，不要随意改动目录结构。
- `Kimi CLI` 不是永久登录态，过期后需要重新执行 `kimi login`。
- 当前主链路已经开始使用统一 `Planner -> Dispatcher -> Collector` 骨架，但仍在持续收敛，部分历史分支逻辑尚未完全移除。
- 当前 README 已同步到最新实现，但 `docs/` 里仍有部分历史设计文档，阅读时请以代码和本 README 为准。

## License

MIT
