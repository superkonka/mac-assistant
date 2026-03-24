# 去 OpenClaw 原生化重构蓝图

## 目标

把 `OpenClaw` 从默认主链中移除，最终完全剔除相关 runtime、网关、Doctor、健康检查和协议依赖。

重构后的系统应满足：

- 主会话、Planner、Workflow、Task、Browser、Service、Skill 全部由 macOS App 原生控制。
- LLM、视觉、MCP、Browser、Service 都通过统一的原生执行层调度。
- `OpenClaw` 不再是主会话的默认入口，也不再是恢复链、记忆链、任务链的事实源。
- 删除 `OpenClawKit / OpenClawProtocol / OpenClawChatUI` 工程依赖。

## 现状判断

当前系统里真正应该保留的是：

- `Planner` 控制平面
- `WorkflowRun / Task` 执行态
- `BrowserSession / Browser executor`
- `ServiceManager / MCP services`
- `LocalKimiCLIService`
- Memory / Recovery / Trace 框架

当前系统里应该逐步移除的是：

- `OpenClawGatewayClient`
- `OpenClawGatewayRuntimeManager`
- `OpenClawDoctor`
- `OpenClawHealthChecker`
- `OpenClawBridge`
- `ClawRuntimeAdapter` 命名和其 OpenClaw 特化返回类型
- 所有 `OpenClaw*` 用户可见文案和 UI

## 核心设计原则

### 1. Planner First

主会话只负责承接用户输入和展示结果，不直接决定调用哪条技术链路。

统一变成：

`User Input -> Planner -> Workflow/Task/Direct Executor -> Result`

### 2. Runtime Neutral

运行时抽象不再携带 `OpenClaw` 品牌和协议语义。

当前：

- `ClawRuntimeAdapter`
- `OpenClawSkillsStatusReport`
- `OpenClawRecoveredOutput`

目标：

- `ConversationRuntimeAdapter`
- `RuntimeCapabilitySnapshot`
- `RecoveredRuntimeOutput`

### 3. Native Executors

把“调用大模型”“调用 MCP 服务”“操作浏览器”“操作本地服务”拆成并列执行器，而不是全都转述给某个 gateway。

## 目标架构

### 控制平面

- `RequestPlanner`
- `PlannerCommitteeService`
- `PlannerWakeService`
- `WorkflowRunCoordinator`

### 原生运行时

- `ConversationRuntimeAdapter`
- `NativeConversationRuntimeAdapter`
- `LocalTextRuntime`
- `VisionRuntime`

### 原生执行器

- `LLMExecutor`
- `MCPExecutor`
- `ServiceExecutor`
- `BrowserExecutor`
- `SkillExecutor`

### 事实源

- `TaskDefinition / TaskRun`
- `WorkflowSpec / WorkflowRunState`
- `ExecutionTrace`
- `MemoryCoordinator`

## 分阶段迁移

## Phase 0: 冻结 OpenClaw 扩散

目标：先止血，不再让新功能继续耦合 OpenClaw。

需要做的事：

- 禁止新增 `OpenClaw*` 直接引用。
- 所有新增调用一律走抽象层。
- 所有 Planner 新分支不得再新增 `routeMainConversation -> OpenClaw` 的兜底依赖。

涉及文件：

- [RequestPlanner.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/RequestPlanner.swift)
- [CommandRunner.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/CommandRunner.swift)

验收：

- 新能力接入时不再需要改 `OpenClawGatewayClient`。

## Phase 1: 运行时抽象去 OpenClaw 化

目标：把当前 `ClawRuntimeAdapter` 改成中性协议，并引入原生默认实现。

### 1.1 改协议

重命名：

- [ClawRuntimeAdapter.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/ClawRuntimeAdapter.swift)

建议改成：

```swift
protocol ConversationRuntimeAdapter: Actor {
    func sendMessage(
        agent: Agent,
        sessionKey: String,
        sessionLabel: String?,
        requestID: String,
        text: String,
        images: [String],
        systemPrompt: String?,
        onAssistantText: (@Sendable (String) async -> Void)?
    ) async throws -> String

    func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot

    func recoverInterruptedOutput(
        sessionKey: String,
        requestStartedAt: Date,
        latestAssistantText: String
    ) async -> RecoveredRuntimeOutput?

    func injectAssistantMessage(
        sessionKey: String,
        message: String,
        label: String?
    ) async throws
}
```

### 1.2 新增默认原生实现

新增文件：

- `Services/Runtime/NativeConversationRuntimeAdapter.swift`
- `Services/Runtime/LocalTextRuntime.swift`
- `Services/Runtime/VisionRuntime.swift`

职责：

- 文本默认走 `LocalKimiCLIService`
- 图片和视觉请求走支持视觉的原生 provider
- 中断恢复直接基于本地会话和任务缓存，不依赖 OpenClaw history

### 1.3 CommandRunner 默认切换

修改：

- [CommandRunner.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/CommandRunner.swift)

把：

- `init(runtimeAdapter: any ClawRuntimeAdapter = OpenClawRuntimeAdapter.shared)`

改成：

- `init(runtimeAdapter: any ConversationRuntimeAdapter = NativeConversationRuntimeAdapter.shared)`

验收：

- 主会话文本请求默认不再经过 `OpenClawGatewayClient`
- 构建仍然通过

## Phase 2: 直接执行链原生化

目标：Planner 能直接调度 MCP、service、browser，不再通过 gateway 转述。

### 2.1 MCP 执行器落地

当前问题：

- [SkillCatalogAdapters.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/Skills/SkillCatalogAdapters.swift#L145) 的 `MCPServiceAdapter` 返回空列表。

需要做的事：

- 新增 `Services/Executors/MCPExecutor.swift`
- 给每个 MCP 服务暴露结构化 manifest
- 让 Planner 可直接选择 `xiaohongshu-mcp` / `github-mcp-http` 这类服务

修改：

- [SkillCatalogAdapters.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/Skills/SkillCatalogAdapters.swift)
- [ServiceManager.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/ServiceManager.swift)
- [RequestPlanner.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/RequestPlanner.swift)

### 2.2 Browser / Service / Skill 执行统一

保留并继续强化：

- `BrowserStepExecutor`
- `ServiceStepExecutor`
- `SkillStepExecutor`

原则：

- Browser 不走 OpenClaw
- Service 不走 OpenClaw
- MCP 不走 OpenClaw

验收：

- “通过小红书 MCP 做每天 5 点热搜整理”会进入 workflow/service 链，而不是主会话直连 runtime

## Phase 3: 记忆与恢复链去 OpenClaw 化

目标：让 memory、recovery、trace 不再依赖 OpenClaw 类型。

### 3.1 Memory 类型解绑

当前依赖点：

- [MemoryModels.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/MemorySystem/MemoryModels.swift#L9)
- [ClawRuntimeMemoryHook.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/MemorySystem/Integration/ClawRuntimeMemoryHook.swift#L11)

需要做的事：

- 去掉 `import OpenClawKit`
- 把 `ClawRuntimeMemoryHook` 改名为 `RuntimeMemoryHook`
- 用 `ConversationRuntimeAdapter` 代替 `ClawRuntimeAdapter`

### 3.2 恢复策略本地化

当前问题：

- 中断恢复依赖 gateway history / buffer 语义。

需要做的事：

- 基于 `TaskRun`、本地会话 transcript、执行器缓存做恢复
- stream interrupted 不再等同于“OpenClaw 历史补偿”

修改：

- [CommandRunner.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/CommandRunner.swift)
- `Services/Recovery/*`

验收：

- runtime 中断时，系统仍可基于本地任务与 partial output 恢复

## Phase 4: UI 与诊断去 OpenClaw 化

目标：用户界面不再暴露 OpenClaw 概念。

### 要移除的 UI

- [OpenClawDoctorView.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Views/Chat/OpenClawDoctorView.swift)
- [OpenClawHealthChecker.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Analytics/OpenClawHealthChecker.swift)
- [OpenClawDoctor.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/OpenClawDoctor.swift)

### 要修改的 UI

- [ChatView.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Views/Chat/ChatView.swift)
- [ContentView.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/ContentView.swift)

替换成：

- `RuntimeStatusView`
- `NativeDiagnosticsView`

用户文案统一改成：

- 运行时
- 本地推理
- 原生执行器
- 服务执行状态

不再出现：

- OpenClaw
- gateway
- doctor

验收：

- 用户完全感知不到 OpenClaw 这个历史实现

## Phase 5: 删除 OpenClaw 实现与工程依赖

目标：真正完成剔除。

### 删除代码

- [OpenClawGatewayClient.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/OpenClawGatewayClient.swift)
- `OpenClawGatewayRuntimeManager.swift`
- `OpenClawBridge.swift`
- `OpenClawDoctor.swift`
- `OpenClawHealthChecker.swift`

### 删除工程依赖

修改：

- [Package.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/Package.swift)
- [project.pbxproj](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant.xcodeproj/project.pbxproj)

删除：

- `OpenClawKit`
- `OpenClawProtocol`
- `OpenClawChatUI`

验收：

- 工程不再链接任何 OpenClaw package
- `rg -n "OpenClaw|openclaw|ClawRuntimeAdapter"` 只剩迁移文档和历史注释

## 文件级改造清单

### 优先改

- [ClawRuntimeAdapter.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/ClawRuntimeAdapter.swift)
- [CommandRunner.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/CommandRunner.swift)
- [LocalKimiCLIService.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/LocalKimiCLIService.swift)
- [RequestPlanner.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/RequestPlanner.swift)
- [SkillCatalogAdapters.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/Skills/SkillCatalogAdapters.swift)
- [ServiceManager.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/ServiceManager.swift)

### 第二批改

- [MemoryModels.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/MemorySystem/MemoryModels.swift)
- [ClawRuntimeMemoryHook.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/MemorySystem/Integration/ClawRuntimeMemoryHook.swift)
- [MemoryCoordinator.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/MemorySystem/Integration/MemoryCoordinator.swift)
- [MemoryAwareAgent.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/MemorySystem/Integration/MemoryAwareAgent.swift)

### 最后删

- [OpenClawGatewayClient.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/OpenClawGatewayClient.swift)
- [ChatView.swift](/Volumes/ExpansionDock/Code/mac-assistant/mac-app/MacAssistant/MacAssistant/Views/Chat/ChatView.swift) 中的 OpenClaw UI 入口

## 风险与规避

### 风险 1

本地文本 runtime 替代后，视觉能力缺口会暴露。

规避：

- 文本和视觉分 runtime
- 不要把所有请求都压到 `LocalKimiCLIService`

### 风险 2

MCP 服务虽然运行中，但还没有统一执行协议。

规避：

- 先完成 `MCPExecutor + manifest`
- 再切主路径

### 风险 3

记忆系统会被 OpenClaw 类型拖住。

规避：

- 先改抽象层和 memory hook
- 最后再删 package 依赖

## 建议执行顺序

1. `Phase 1`
2. `Phase 2`
3. `Phase 3`
4. `Phase 4`
5. `Phase 5`

不要先删 package，再补原生 runtime。

## 第一阶段的最小落地目标

第一阶段只要达到下面 4 条，就算切换成功：

- 主会话默认不再经过 OpenClaw
- Planner 可直接把 MCP/service/browser/workflow 分发到原生执行器
- stream interrupted 不再依赖 OpenClaw 特有恢复逻辑
- UI 顶层不再暴露 OpenClaw 状态

## 一句话定案

`OpenClaw` 应从主链降为历史实现，随后完全删除。  
新的主系统应该是：

`Planner + Native Runtime + Native Executors + Workflow/Task + Memory/Recovery`
