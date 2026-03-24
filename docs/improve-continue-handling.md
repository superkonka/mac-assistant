# "继续处理"意图交互改进方案

## 当前问题

用户说"继续处理"时，系统直接恢复最近的一个可恢复任务，没有：
1. 分析有哪些可以处理的事情
2. 向用户确认
3. 提供其他可能需要处理的事情

## 改进方案

### 交互流程

```
用户: 继续处理
        │
        ▼
┌─────────────────────────────┐
│  Planner 分析阶段            │
│  1. 查询所有可恢复的任务      │
│  2. 查询服务管理中待处理的    │
│  3. 分析主会话中的未完成项    │
└─────────────────────────────┘
        │
        ▼
┌─────────────────────────────┐
│ 决策分支                      │
└─────────────────────────────┘
        │
    ┌───┴───┐
    ▼       ▼
 有明确    多个可选
  单个     或不确定
    │       │
    ▼       ▼
启动子任务  主会话询问
处理它      用户选择
    │
    ▼
同时在主会话提供
"其他可能需要处理的事情"
```

### 实现方案

#### 1. 新增 `analyzeContinueIntent()` 方法

```swift
struct ContinueIntentAnalysis {
    let resumableTasks: [ResumableTaskInfo]      // 可恢复的任务
    let pendingServices: [PendingServiceInfo]    // 服务管理中待处理的
    let incompleteRequests: [IncompleteRequest]  // 主会话未完成项
    let suggestions: [ContinueSuggestion]        // 建议选项
    
    var hasClearSingleOption: Bool {
        resumableTasks.count == 1 && 
        pendingServices.isEmpty && 
        incompleteRequests.isEmpty
    }
}

struct ContinueSuggestion {
    let id: String
    let title: String
    let description: String
    let priority: Priority
    let action: ContinueAction
    
    enum ContinueAction {
        case resumeTask(sessionID: String)
        case startService(serviceID: String)
        case handleInRequest(messageID: UUID)
        case newRequest(prompt: String)
    }
}
```

#### 2. 修改 Planner 决策逻辑

```swift
case "continue_processing":
    let analysis = await analyzeContinueIntent(envelope: envelope)
    
    if analysis.hasClearSingleOption, 
       let task = analysis.resumableTasks.first {
        // 只有一个明确的任务，直接恢复
        return RequestPlan(
            primaryAction: .resumeInterruptedTask(sessionID: task.sessionID),
            notices: [createOtherOptionsNotice(analysis)],  // 同时提供其他选项
            ...
        )
    } else {
        // 多个选项或不确定，询问用户
        return RequestPlan(
            primaryAction: .presentContinueOptions(analysis.suggestions),
            ...
        )
    }
```

#### 3. UI 交互设计

**情况 A: 只有一个明确的任务**

```
[系统消息]
🔄 正在恢复「微信 MCP 启动」任务...

💡 您可能还需要处理：
   • 小红书 MCP 服务已停止 [启动]
   • 富途 OpenD 需要重新授权 [处理]
```

**情况 B: 多个选项**

```
[系统消息]
🤔 我发现以下几件事情可以"继续处理"：

**高优先级：**
1. 🔄 恢复未完成的任务：微信 MCP 启动
   状态：等待扫码授权 | 点击继续

**服务管理：**
2. 🚀 启动服务：小红书 MCP（已停止）
3. 🛑 停止服务：富途 MCP（端口冲突）

**其他：**
4. 💬 继续之前的对话：关于部署配置的讨论

请选择一项，或告诉我具体要做什么。
```

#### 4. 代码实现

```swift
// IntentAgentShadowPlannerProvider.swift

case "continue_processing":
    let analysis = await analyzeContinueIntent(
        taskSessions: commandRunner.taskSessions,
        services: serviceManager.services,
        messages: commandRunner.messages
    )
    
    if analysis.hasClearSingleOption {
        // 直接恢复，但同时在主会话提供其他选项
        let primaryTask = analysis.resumableTasks.first!
        
        // 启动子任务
        let plan = RequestPlan(
            envelope: envelope,
            primaryAction: .resumeInterruptedTask(sessionID: primaryTask.sessionID),
            ...
        )
        
        // 同时在主会话发送"其他选项"消息
        await sendOtherOptionsMessage(analysis, excluding: primaryTask.id)
        
        return plan
    } else {
        // 显示选择界面
        return RequestPlan(
            envelope: envelope,
            primaryAction: .presentContinueOptions(analysis.toSuggestionList()),
            ...
        )
    }
```

### 优先级规则

1. **最高优先级**: 用户明确提到的任务（通过意图识别）
2. **高优先级**: 最近失败/等待用户输入的任务
3. **中优先级**: 服务管理中需要处理的状态变更
4. **低优先级**: 历史对话中未完成的话题

### 具体实现步骤

1. **添加分析器** (`ContinueIntentAnalyzer`)
   - 收集所有可恢复的任务
   - 检查服务管理状态
   - 分析主会话上下文

2. **修改 Shadow Planner**
   - 添加 `continue_processing` 意图处理
   - 集成分析器
   - 根据分析结果决策

3. **新增 UI 组件**
   - `ContinueOptionsView`: 选项列表
   - `ResumableTaskCard`: 可恢复任务卡片
   - 在主会话中显示相关建议

4. **优化消息模板**
   - 清晰的优先级分组
   - 简洁的操作按钮
   - 友好的引导文案

## 示例场景

### 场景 1: 只有一个任务需要继续
```
用户: 继续处理
系统: 🔄 正在恢复「部署 MongoDB」任务...
      [任务卡片显示执行进度]
      
      💡 其他可能需要处理：
      • 小红书 MCP 服务已停止 [启动]
      
用户: 继续处理（再次）
系统: 小红书 MCP 正在启动...
```

### 场景 2: 多个任务需要选择
```
用户: 继续处理
系统: 🤔 发现以下可继续处理的事项：
      
      **紧急**
      1. 🔄 微信 MCP - 等待扫码授权
      
      **服务管理**
      2. 🚀 启动小红书 MCP
      3. 🔄 重启富途 MCP
      
      请选择（输入数字或描述）

用户: 2
系统: 🚀 正在启动小红书 MCP...
```

这个改进让用户感受到：
1. 系统"理解"了"继续处理"的意图
2. 清晰地展示了所有可选项
3. 帮助用户发现可能遗忘的任务
4. 提供了便捷的恢复机制
