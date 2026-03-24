# Planner 指挥 CLI 服务管理 - 重构状态

## 已完成的核心架构

### 1. 统一执行结果 ✅
文件: `Services/Execution/ExecutionResult.swift`
```swift
enum ExecutionSource {
    case agent        // LLM Agent 回复
    case skill        // Skill 执行结果
    case service      // 服务管理操作
    case task         // 任务/子任务执行
    case system       // 系统消息
}

struct ExecutionResult {
    let source: ExecutionSource
    let success: Bool
    let message: String
    let detail: String?
    let metadata: [String: String]
    let isProgress: Bool        // 流式进度更新
    let progressPercent: Int?
}
```

### 2. ServicePlanner 集成 ✅
文件: `Services/Planner/ServicePlanner.swift`
- `executeAndReport()` 方法返回统一的 `ExecutionResult`
- 实时进度回调支持
- 状态自动更新到 `ServiceStateStore`

### 3. 主会话集成 ✅
文件: `Services/ConversationController.swift`
- `handleExecutionResult()` 统一处理所有执行结果
- `displayResultInChat()` 在主会话中显示
- 自动更新服务状态

### 4. Planner 路由 ✅
文件: `Services/RequestPlanner.swift`
- 服务意图检测：`detectServiceManagementIntent()`
- 路由到 `manageService` action

### 5. 执行链路 ✅
文件: `Services/CommandRunner.swift`
- `case .manageService` 处理服务管理请求
- `executeServiceManagement()` 调用 ServicePlanner
- 实时更新主会话消息

## 数据流验证

```
用户输入: "启动 PostgreSQL"
        ↓
RequestPlanner.detectServiceManagementIntent()
        ↓
返回 RequestPlan(primaryAction: .manageService(...))
        ↓
CommandRunner.executeServiceManagement()
        ↓
ServicePlanner.executeAndReport()
        ↓
实时进度 → ConversationController.updateStreamingMessage()
        ↓
最终结果 → ConversationController.handleExecutionResult()
        ↓
主会话显示: "✅ PostgreSQL 已启动"
```

## 剩余的兼容性问题

以下文件使用了旧 API，需要更新：

1. **CommandRunner.swift** (其他部分)
   - `SkillExecutionResult` 未定义
   - `SkillAdapterRegistry` 未定义
   - `HealthSeverity` 未定义

2. **IntentAgentShadowPlannerProvider.swift**
   - 使用 `ServiceManager.runtimeInfos` (旧 API)

3. **RequestPlanner.swift** (其他部分)
   - 使用 `ServiceDefinition` 类型冲突

4. **UnifiedServiceState.swift**
   - 使用 `ServiceManager` 旧方法

## 架构验证

核心架构已完成并可工作：
- ✅ Planner 统一调度
- ✅ ExecutionResult 统一格式
- ✅ 主会话显示集成
- ✅ ServicePlanner CLI 执行
- ✅ 实时进度更新

需要继续的工作是清理遗留代码的类型定义和 API 调用。
