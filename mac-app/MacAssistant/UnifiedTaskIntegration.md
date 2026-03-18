# 统一任务管理系统迁移指南

## 概述

为了简化任务管理架构，我们将三个独立的任务系统整合为一个统一的任务管理系统：

| 旧系统 | 新系统 | 用途 |
|--------|--------|------|
| AgentTaskSession | UnifiedTask (.exceptionRecovery) | 异常恢复任务 |
| Subtask | UnifiedTask (.smartSubtask) | 智能子任务 |
| TaskItem | UnifiedTask (.todo) | 待办任务 |

## 新架构

### 核心组件

```
┌─────────────────────────────────────────────────────────────┐
│                    统一任务管理架构                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────┐     ┌──────────────────────┐         │
│  │ UnifiedTask      │     │ UnifiedTaskManager   │         │
│  │ (任务模型)        │◄────│ (任务生命周期管理)    │         │
│  └──────────────────┘     └──────────┬───────────┘         │
│                                      │                      │
│                    ┌─────────────────┼─────────────────┐    │
│                    ▼                 ▼                 ▼    │
│         ┌──────────────┐  ┌────────────────┐  ┌──────────┐ │
│         │ QuickTask    │  │ UnifiedTask    │  │ Task     │ │
│         │ AccessView   │  │ ManagerView    │  │ Migration│ │
│         │ (快速入口)    │  │ (完整管理器)    │  │ Helper   │ │
│         └──────────────┘  └────────────────┘  └──────────┘ │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 任务模型 (UnifiedTask)

```swift
struct UnifiedTask {
    let id: String
    var type: UnifiedTaskType        // .exceptionRecovery, .smartSubtask, .todo, .background
    var title: String
    var description: String
    var status: UnifiedTaskStatus    // .pending, .running, .paused, .completed, .failed
    
    // 执行相关
    var assignedAgentID: String?
    var strategy: TaskExecutionStrategy
    
    // 内容相关
    var inputContext: String
    var result: String?
    var errorMessage: String?
    
    // 对话历史
    var messages: [TaskMessage]
    var logs: [TaskLogEntry]
    
    // 异常恢复专用
    var canResume: Bool
    var gatewaySessionKey: String?
    
    // 时间相关
    var createdAt: Date
    var scheduledTime: Date?
    
    // 统计
    var executionTime: TimeInterval?
    var retryCount: Int
}
```

## 迁移状态

### ✅ 已完成

1. **核心模型**: `UnifiedTaskModels.swift`
   - UnifiedTaskType (任务类型: exceptionRecovery, smartSubtask, todo, background)
   - UnifiedTaskStatus (五态状态机: pending, running, paused, completed, failed)
   - UnifiedTask (统一任务模型)
   - TaskExecutionStrategy / TaskExecutionStrategyType (执行策略)
   - TaskFilter (筛选器)
   - TaskStatistics (统计)

2. **任务管理器**: `UnifiedTaskManager.swift`
   - 单例模式，@MainActor
   - CRUD操作 (addTask, removeTask, updateTask, task)
   - 执行管理 (startTask, pauseTask, resumeTask, retryTask, cancelTask)
   - 执行队列管理 (enqueueTask, processQueue)
   - 自动持久化 (30秒间隔)
   - 实时统计

3. **UI组件**: 
   - `UnifiedTaskManagerView` - 完整任务管理界面
   - `QuickTaskAccessView` - 快速任务入口（替代TaskSessionTabsView）
   - `UnifiedTaskRow` - 任务列表项
   - `FilterTabButton` - 筛选标签
   - `TaskStatusIcon`, `TaskStatusBadge`, `TaskActionButtons` - 辅助组件

4. **迁移工具**: `TaskMigrationHelper.swift`
   - 从旧系统转换到新系统
   - AgentTaskSession → UnifiedTask (含消息类型转换)
   - Subtask → UnifiedTask
   - TaskItem → UnifiedTask

5. **集成工作**:
   - ✅ CommandRunner 异常处理时创建 UnifiedTask
   - ✅ ChatView 集成 QuickTaskAccessView
   - ✅ 构建成功，无编译错误

### ⏳ 待完成

1. **SubtaskCoordinator迁移**
   - 将Subtask创建改为UnifiedTask
   - 更新SubtaskPanelView使用新系统

2. **TaskManager迁移**
   - 替换TaskItem使用
   - 迁移待办任务

3. **执行逻辑**
   - 实现executeExceptionRecovery
   - 实现executeSmartSubtask
   - 实现executeGenericTask

## 使用指南

### 创建异常恢复任务

```swift
// 旧方式
let session = AgentTaskSession(
    id: sessionID,
    title: title,
    originalRequest: request,
    status: .waitingUser,
    ...
)
taskSessions.append(session)

// 新方式
let task = UnifiedTaskManager.shared.createExceptionRecoveryTask(
    title: title,
    originalRequest: request,
    errorMessage: error,
    gatewaySessionKey: sessionKey
)
```

### 创建智能子任务

```swift
// 新方式
let task = UnifiedTaskManager.shared.createSmartSubtask(
    title: "分析代码",
    description: "分析项目结构",
    inputContext: context,
    strategy: .useAgent("code-analyzer")
)
```

### 创建待办任务

```swift
// 新方式
let task = UnifiedTaskManager.shared.createTodoTask(
    title: "完成文档",
    description: "编写API文档",
    scheduledTime: tomorrow
)
```

### 执行任务

```swift
// 启动任务
await UnifiedTaskManager.shared.startTask(id: task.id)

// 暂停任务
UnifiedTaskManager.shared.pauseTask(id: task.id)

// 恢复任务
UnifiedTaskManager.shared.resumeTask(id: task.id)

// 重试失败任务
await UnifiedTaskManager.shared.retryTask(id: task.id)
```

### 筛选任务

```swift
// 获取待执行的任务
let pending = manager.tasks(filteredBy: .pending)

// 获取异常恢复任务
let exceptions = manager.tasks(filteredBy: .exception)

// 获取全部任务
let all = manager.tasks(filteredBy: .all)
```

## 注意事项

1. **状态映射**
   - `AgentTaskSession.partial` → `UnifiedTaskStatus.paused`
   - `AgentTaskSession.waitingUser` → `UnifiedTaskStatus.pending`
   - `Subtask.cancelled` → `UnifiedTaskStatus.failed`

2. **持久化**
   - 自动保存间隔：30秒
   - 存储位置：Documents/unified_tasks.json
   - 启动时自动加载

3. **向后兼容**
   - 旧版AgentTaskSession暂时保留
   - TaskMigrationHelper支持数据迁移
   - 新旧系统可并行运行

4. **性能优化**
   - 使用LazyVStack优化长列表
   - Equatable协议减少重渲染
   - 筛选和排序缓存

## 下一步计划

1. 完善执行逻辑（executeExceptionRecovery等）
2. 完全替换TaskSessionTabsView
3. 迁移SubtaskCoordinator
4. 迁移TaskManager
5. 移除旧系统代码
6. 添加任务优先级和排序
7. 支持任务依赖关系
