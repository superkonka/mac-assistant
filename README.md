# Mac Assistant

基于 SwiftUI 和可配置 Agent 运行时的 macOS 原生助手。

当前仓库已经不再是最早期的"菜单栏壳 + Python 后端"原型，而是一套以本地 Mac App 为主、可动态接入 `Kimi CLI` / 远端 LLM / 内置原生 Skill 的多 Agent 框架。README 以当前实现为准。

## 当前能力

- 原生 macOS 聊天窗口和菜单栏入口，支持截图询问、剪贴板询问、日志查看。
- 多 Agent 管理和能力路由，支持按能力选择文本、代码、视觉、长文档等模型。
- Agent 角色分工：支持 `主会话`、`Planner`、`子任务 Worker`、`回退池`、`仅手动`。
- 统一 `Planner / Dispatcher / Result Collector / Self-heal` 链路，支持主会话、独立 side task 和部分并行子任务。
- Provider 接入：`Kimi CLI`、`DeepSeek`、`Doubao`、`Zhipu`、`OpenAI`、`Anthropic`、`Google`、`Moonshot`、`MiniMax`。
- `Planner Console`：支持规则优先、Planner Agent 接管、影子对比、最近 diff 观察。
- 自愈链路：鉴权失败检测、坏 Agent 临时下线、降级到其他可用 Agent、无 Agent 时自动拉起配置向导。
- `Kimi CLI` 登录失效检测，可引导执行 `kimi login` 恢复认证。
- 内置 `Mac 操作 Agent`，用 macOS 原生接口直接处理应用枚举、启动、退出、状态检查，避免 LLM 幻觉式"成功回执"。
- 内置 Skill 系统、Agent 创建流和 `Skill 迭代顾问`，能基于使用情况提出优化提案并等待用户确认。
- 富文本聊天渲染，支持标题、列表、引用、代码块和 Markdown 表格的结构化显示。

## 架构概览

主链路：

```text
SwiftUI Mac App
  ├─ ChatView / MessageBubble / RichTextView
  ├─ ConversationController
  ├─ ContextAssembler
  ├─ RequestPlanner
  ├─ TaskSupervisor
  ├─ ResultReducer / ConversationStores
  ├─ AgentStore / AgentOrchestrator / MacSystemAgent
  └─ ConversationRuntimeAdapter (UnifiedLLMClient)
          │
          ▼
Kimi CLI / DeepSeek / Doubao / Zhipu / OpenAI / Anthropic / Google / Moonshot / MiniMax
```

调度逻辑是固定阶段的模块链：

```text
UI
  -> ConversationController
  -> ContextAssembler
  -> Planner
  -> TaskSupervisor
  -> ConversationRuntimeAdapter
  -> ResultReducer
  -> Stores
```

其中：

- `ConversationController` 负责给 UI 提供统一会话入口和观察态，避免 `ChatView` 直接绑定底层运行时。
- `ContextAssembler` 负责把截图、最近消息、当前 Agent、可恢复 task context 组装成 `RequestEnvelope`。
- `Planner` 负责判定这次请求是主对话、配置向导、系统操作、URL 研究、Skill 建议还是 side task。
- `TaskSupervisor` 负责承接规划结果，并驱动主会话、独立子任务和恢复链路。
- `ConversationRuntimeAdapter` 负责把运行时调用收口到单一适配层。
- `ResultReducer` 负责把运行态压成 UI 可消费的 `ConversationStores`。
- `Self-heal` 负责 Agent 回退、Kimi 登录恢复。

辅助链路：

- `backend/`：FastAPI 本地服务，端口默认 `8765`，适合独立调试、打包或保留旧接口兼容。
- `daemon/`：`launchd` 管理脚本，用来安装/管理 Python backend。

## 核心模块

- `mac-app/MacAssistant/MacAssistant/MacAssistantApp.swift`：应用入口、菜单栏、主窗口、日志窗口。
- `mac-app/MacAssistant/MacAssistant/Services/ConversationController.swift`：UI 会话控制器，统一收口发送入口和观察态。
- `mac-app/MacAssistant/MacAssistant/Services/ContextAssembler.swift`：会话上下文组装器，负责形成 `RequestEnvelope`。
- `mac-app/MacAssistant/MacAssistant/Services/CommandRunner.swift`：主对话编排器，负责 planner 决策执行、主会话、side task、自愈和 trace。
- `mac-app/MacAssistant/MacAssistant/Services/RequestPlanner.swift`：统一请求规划器，负责判定请求类型和执行模式。
- `mac-app/MacAssistant/MacAssistant/Services/TaskSupervisor.swift`：任务承接和 task session 监督层。
- `mac-app/MacAssistant/MacAssistant/Services/IntentAgentShadowPlannerProvider.swift`：独立 Planner Agent 的影子判定接口。
- `mac-app/MacAssistant/MacAssistant/Services/AgentStore.swift`：Agent 持久化、可用性检测、认证验证、角色分配。
- `mac-app/MacAssistant/MacAssistant/Services/AgentOrchestrator.swift`：能力路由和当前 Agent 协同。
- `mac-app/MacAssistant/MacAssistant/Services/ConversationRuntimeAdapter.swift`：运行时适配层。
- `mac-app/MacAssistant/MacAssistant/Services/ResultReducer.swift`：把运行态收敛成 UI Stores。
- `mac-app/MacAssistant/MacAssistant/Services/MacSystemAgent.swift`：原生 macOS 应用操作代理。
- `mac-app/MacAssistant/MacAssistant/Services/SkillEvolutionAdvisor.swift`：根据 Skill 使用数据提出演进建议。
- `mac-app/MacAssistant/MacAssistant/Services/LLM/`：统一 LLM Provider 实现（OpenAICompatible、Anthropic、Google）。

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
│   │       │   └── LLM/          # 统一 LLM Provider 实现
│   │       ├── Skills/
│   │       ├── Storage/
│   │       ├── Utils/
│   │       └── Views/
│   ├── restart.sh
│   └── test_logs.sh
├── backend/                      # FastAPI 本地服务（可选）
│   ├── main.py
│   ├── kimi_provider.py
│   ├── requirements.txt
│   └── start.sh
├── daemon/                       # launchd 管理脚本
│   ├── com.mac-assistant.backend.plist
│   └── service-manager.sh
├── scripts/                      # 辅助脚本
│   ├── setup.sh
│   ├── restart.sh
│   └── diagnose.sh
├── docs/                         # 文档
└── build/                        # 构建产物
```

## 环境要求

- macOS 15+
- Xcode 16+（建议 16.4 或更高）
- Python 3.11+（仅在使用 `backend/` 时必需）
- 可选：`kimi` CLI
- 可选：DeepSeek / Doubao / Zhipu / OpenAI / Anthropic / Google / Moonshot / MiniMax 等 provider API Key

> 当前最低版本是 `macOS 15+`。

## 快速开始

### 1. 克隆仓库

```bash
git clone <repository-url>
cd mac-assistant
```

### 2. 构建并安装

```bash
./build-and-install.sh
```

脚本会自动：
- 构建 Release 版本
- 安装到 `/Applications/MacAssistant.app`

### 3. 启动应用

```bash
open /Applications/MacAssistant.app
```

或使用快捷键 `⌘ ⇧ Space` 打开面板。

## 快捷键

- `⌘ ⇧ Space` - 打开/关闭面板
- `⌘ ⇧ 1` - 截图并询问 AI
- `⌘ ⇧ V` - 询问剪贴板内容

## 开发

### 构建

```bash
cd mac-app/MacAssistant
xcodebuild -project MacAssistant.xcodeproj -scheme MacAssistant \
  -configuration Release -destination "platform=macOS" build
```

### 项目结构

- 纯原生 Swift 实现，无外部 runtime 依赖
- 统一 LLM Client 架构支持多 Provider
- 模块化的 Skill 系统

## License

MIT License
