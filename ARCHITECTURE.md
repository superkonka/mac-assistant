# MacAssistant 架构设计 v2.0

## 核心原则

> **应用层轻量化，核心能力下沉到 OpenClaw Core**

```
┌─────────────────────────────────────────────────────────────────┐
│                      MacAssistant (应用层)                       │
│                      轻量级 UI + 调度编排                         │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │   UI Layer  │  │  Scheduler  │  │   Gateway   │             │
│  │   (SwiftUI) │  │  (编排调度)  │  │   Client    │             │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘             │
│         │                │                │                      │
│         └────────────────┴────────────────┘                      │
│                          │                                       │
│                          ▼                                       │
│              ┌─────────────────────┐                             │
│              │   Unified Events    │                             │
│              │   (事件总线)         │                             │
│              └─────────────────────┘                             │
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    │ WebSocket / Local IPC
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                    OpenClaw Core (运行时层)                      │
│                     核心能力 + 执行引擎                          │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────┐ │
│  │Agent Runtime│  │Skill Engine │  │ Tool Runner │  │ Memory │ │
│  │  (Agent执行) │  │ (技能执行)  │  │  (工具执行)  │  │(上下文) │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └────────┘ │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │   Planner   │  │  Dispatcher │  │   Sandbox   │             │
│  │  (意图规划)  │  │  (任务分发)  │  │  (沙箱隔离)  │             │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
└─────────────────────────────────────────────────────────────────┘
```

## 分层职责

### 1. 应用层 (MacAssistant)

**不做的：**
- ❌ 不直接调用 LLM API
- ❌ 不直接执行 Tools
- ❌ 不维护 Agent 执行状态机
- ❌ 不做复杂的意图解析

**做的：**
- ✅ 用户界面展示 (消息、状态、配置)
- ✅ 会话组织和管理 (UI 层面的会话)
- ✅ 请求编排和结果聚合
- ✅ 与 OpenClaw Gateway 的通信
- ✅ 本地数据持久化 (消息历史、配置)

### 2. OpenClaw Core 层

**核心职责：**
- Agent 生命周期管理
- Skill 发现、加载、执行
- Tool 调用和权限控制
- 上下文/记忆管理
- 多 Agent 编排 (Planner/Dispatcher)

## 新模块设计

### AgentSystem (应用层)

```swift
// 轻量级 Agent 配置模型
struct AgentDescriptor: Codable {
    let id: String
    let name: String
    let providerRef: ProviderReference  // 引用，不存储密钥
    let capabilities: [CapabilityTag]   // 能力标签，用于路由
    let preferences: AgentPreferences   // 用户偏好
}

// Agent 注册表 - 只做配置管理
class AgentRegistry {
    func register(_ descriptor: AgentDescriptor)
    func resolve(for capability: CapabilityTag) -> AgentDescriptor?
    func syncToOpenClaw()  // 同步到 OpenClaw Core
}
```

### SkillSystem (应用层)

```swift
// Skill 声明式注册
struct SkillManifest: Codable {
    let id: String
    let name: String
    let description: String
    let parameters: [ParameterSchema]
    let requiredCapabilities: [CapabilityTag]
}

// Skill 浏览器 - 只展示，不执行
class SkillBrowser {
    func listAvailable() -> [SkillManifest]
    func install(from url: URL)
    func uninstall(_ skillId: String)
}
```

### GatewayClient (统一接口)

```swift
// 与 OpenClaw Core 的唯一通信接口
class GatewayClient {
    // 发送消息，所有复杂逻辑在 Core 层处理
    func sendMessage(
        content: String,
        context: ConversationContext,
        onEvent: (GatewayEvent) -> Void
    ) async throws
    
    // 控制命令
    func pauseSession(_ sessionId: String)
    func resumeSession(_ sessionId: String)
    func cancelTask(_ taskId: String)
}

enum GatewayEvent {
    case text(String)
    case toolStart(ToolCall)
    case toolEnd(ToolResult)
    case skillStart(SkillInvocation)
    case skillEnd(SkillResult)
    case error(Error)
    case done
}
```

## 数据流

```
用户输入
    ↓
[应用层] ChatView 接收输入
    ↓
[应用层] Scheduler 构建 RequestContext
    ↓
[应用层] GatewayClient.sendMessage()
    ↓ ─────────────────────────────────────── WebSocket
[Core 层] Gateway 接收请求
    ↓
[Core 层] Planner 分析意图
    ↓
[Core 层] Dispatcher 选择 Agent
    ↓
[Core 层] Agent Runtime 执行
    ↓ (可能需要 Skills/Tools)
[Core 层] Skill Engine / Tool Runner
    ↓
[Core 层] 流式返回结果
    ↑ ─────────────────────────────────────── WebSocket
[应用层] GatewayClient 接收 Events
    ↓
[应用层] UI 更新展示
```

## 迁移计划

### Phase 1: 基础设施
1. 创建新的 GatewayClient 统一接口
2. 移除应用层直接调用 LLM 的代码
3. 所有请求都通过 OpenClaw Gateway

### Phase 2: Agent 模块重构
1. AgentStore 改为 AgentRegistry（只管理配置）
2. AgentOrchestrator 改为轻量级调度器
3. Agent 执行完全委托给 OpenClaw Core

### Phase 3: Skill 模块重构
1. 移除应用层的 Skill 执行逻辑
2. Skill 只保留声明式注册和 UI 展示
3. 技能执行完全下沉到 OpenClaw Core

### Phase 4: 清理和优化
1. 删除重复代码
2. 统一事件模型
3. 优化性能和内存占用

## 代码目录结构

```
mac-app/MacAssistant/MacAssistant/
├── App/
│   ├── MacAssistantApp.swift
│   └── AppState.swift
│
├── UI/                          # 纯展示层
│   ├── Chat/
│   │   ├── ChatView.swift
│   │   ├── MessageList.swift
│   │   ├── InputBar.swift
│   │   └── StatusBar.swift
│   ├── Agents/
│   │   ├── AgentListView.swift
│   │   └── AgentConfigView.swift
│   ├── Skills/
│   │   ├── SkillBrowserView.swift
│   │   └── SkillDetailView.swift
│   └── Common/
│
├── Scheduler/                   # 轻量级调度
│   ├── RequestScheduler.swift
│   ├── SessionManager.swift
│   └── EventAggregator.swift
│
├── Gateway/                     # OpenClaw 通信
│   ├── GatewayClient.swift
│   ├── GatewayModels.swift
│   └── GatewayEvents.swift
│
├── Registry/                    # 配置注册表
│   ├── AgentRegistry.swift
│   ├── SkillRegistry.swift
│   └── ProviderRegistry.swift
│
├── Storage/                     # 本地持久化
│   ├── MessageStore.swift
│   ├── ConversationStore.swift
│   └── SettingsStore.swift
│
└── Models/                      # 数据模型
    ├── Conversation.swift
    ├── Message.swift
    └── Configuration.swift
```

## 关键变化

| 旧架构 | 新架构 |
|--------|--------|
| CommandRunner 包含复杂执行逻辑 | RequestScheduler 只做编排调度 |
| AgentOrchestrator 管理 Agent 状态 | AgentRegistry 只做配置管理 |
| 应用层直接执行 Skills | Skill 只在 Core 层执行 |
| 多处重复代码 | 统一通过 GatewayClient 通信 |
| 应用层维护上下文 | Core 层统一维护上下文 |

## 好处

1. **更清晰的边界** - 应用层和核心层职责明确
2. **更好的复用** - OpenClaw Core 可以被其他客户端复用
3. **更易维护** - 逻辑集中在 Core 层，应用层只做 UI
4. **更好的扩展** - 新增 Agent/Skill 不需要修改应用层代码
5. **更好的测试** - 可以独立测试 Core 层能力
