# Planner 指挥 CLI 服务管理 - 构建状态

## 已完成的部分

### Phase 1: CLI 层 ✅
- `ExecutionContext.swift` - Planner 构建的执行上下文
- `CLIExecutor.swift` - 无状态 CLI 执行器（带重试机制）
- `CLICapabilityDetector.swift` - CLI 能力检测

### Phase 2: Planner 集成 ✅
- `ServicePlanner.swift` - Planner 调度器
- `RequestPlanner.swift` - 添加服务意图检测

### Phase 3: 状态管理 ✅
- `ServiceStateStore.swift` - 单一状态数据源
- `ServiceManager.swift` - UI 入口

### Phase 4: UI 层 ✅
- `ServiceManagerView.swift` - 服务管理主界面
- `ServiceEntryButton.swift` - 快速入口按钮

## 剩余的兼容性问题

以下文件使用了旧的 ServiceManager API，需要更新：

1. **CommandRunner.swift** - 使用了 `SkillExecutionResult`, `SkillAdapterRegistry`, `HealthSeverity` 等未定义类型
2. **IntentAgentShadowPlannerProvider.swift** - 使用了旧的 `ServiceManager.runtimeInfos` API
3. **RequestPlanner.swift** - 部分代码使用了旧的 `ServiceDefinition` 类型
4. **HealthMonitorConfig.swift** - 已替换为占位符
5. **ServiceDiscoveryView.swift** - 已替换为占位符

## 架构总结

```
UI (ServiceManagerView)
    ↓
ServiceManager
    ↓
ServicePlanner (构建 ExecutionContext)
    ↓
CLIExecutor (无状态执行)
    ↓
ServiceStateStore (更新状态)
    ↓
UI (刷新)
```

## 下一步

1. 修复 CommandRunner.swift 中的类型定义
2. 统一 ServiceDefinition 和 ServiceStateSnapshot 的使用
3. 更新所有引用旧 API 的视图文件
