# Planner Orchestration 重构方案

## 一句话定案

`主会话负责对外协商，Planner 负责唯一调度，专家组是 Planner 的增强决策机制，Task/WorkflowRun 是执行态事实源，Service 是长期封装，Skill 是原子能力，Subtask 是 Planner 拆出来的执行单元。`

## 这次要解决的核心问题

当前系统已经有很多模块，但控制平面还没有真正收口到 Planner：

- `CommandRunner` 仍然承担了太多“边执行边决定”的职责。
- `RequestPlanner` 已经是入口，但更像分流器，还不是唯一总调度。
- `SubtaskCoordinator` 还保留了一套相对独立的分解逻辑，不是 Planner 的下游。
- `ServiceManager` 管的是服务生命周期，但 Planner 还没有把服务当成可规划资源。
- `SkillCatalog` 已经接近正确形态，但还没有成为 Planner 的标准能力目录。
- `PlannerCommitteeService` 已有“多 LLM 会诊”雏形，但现在更像旁路 reviewer，而不是 Planner 的专家组能力。

## 现状诊断

### 1. 主会话、Planner、执行层的边界还不够清晰

当前主链大致是：

`主会话输入 -> RequestPlanner -> CommandRunner -> 各种执行模块`

问题在于：

- `RequestPlanner` 主要返回 `primaryAction`，偏“路由”。
- `CommandRunner` 里仍然有大量对后续执行路径的决定。
- 一些高层决策又下沉到了 Browser/Workflow/Service 等模块里。

结果是控制权分散。

### 2. 子任务仍然是并行规划路径，不是 Planner 的执行单元

`SubtaskCoordinator` 目前是“基于向量意图匹配的智能任务分解”。

这意味着它实际上在做一部分 planning：

- 判断是否需要拆解
- 决定拆成几个子任务
- 给每个子任务分配 strategy

这和 Planner 的职责重叠了。正确关系应该反过来：

- Planner 决定是否拆解
- Planner 决定拆成哪些子任务
- SubtaskCoordinator 只负责子任务生命周期和状态同步

### 3. Service 还没有成为 Planner 的一等资源

`ServiceManager` 目前主要负责：

- 加载服务定义
- 启停服务
- 检查服务状态
- 同步 runtime info

这说明它定位正确，是“长期运行资源管理器”，不是 Planner。

问题在于 Planner 目前还没有成熟地做这些判断：

- 该诉求是一次性任务，还是应该复用现有服务
- 是直接调用 skill，还是先启动 service
- 服务异常后是提醒用户、自动修复，还是升级为 workflow run

### 4. Skill 已经基本是正确形态，但没有完全成为统一能力目录

`SkillCatalog` 当前已经是相对正确的方向：

- 有 manifest
- 有 capability
- 有 executor type
- 有查询/匹配能力

这意味着 Skill 应该继续被定义为：

- 原子能力
- 可发现、可匹配、可执行
- 不负责高层编排

### 5. PlannerCommitteeService 现在有结构性问题

当前委员会雏形是对的，但实现上有两个关键问题：

- 它还是旁路触发，不是 Planner 内部的正式决策阶段。
- `shouldTriggerCommittee(for:)` 在读取 `RequestPlan.metadata` 时，把 `[String: String]` 当成结构化对象来取 `Double` 和 `WorkflowRunState`，这在现状下会失效。

也就是说，当前专家组机制不只是“能力不够强”，而是“数据接口不对”。

## 目标架构

### 分层模型

新的目标架构如下：

`Main Session -> Planner -> Planner Expert Group -> Dispatch Plan -> Task/WorkflowRun -> Executors(Skill / Service / Browser / Agent / Subtask) -> Observation -> Planner Replan`

### 角色定义

#### 1. 主会话 Main Session

职责：

- 接收用户请求
- 展示 Planner 的问题、建议、审批点、结论
- 展示任务卡、服务状态、提醒
- 承接用户继续输入、取消、确认、补槽位

不负责：

- 自己决定调哪个 skill
- 自己决定是否拆子任务
- 自己决定 workflow 编排

在现有代码里，对应：

- `CommandRunner.processInput(...)`
- `ContextAssembler`
- 对话消息展示层

主会话应该退化成：

- `输入装配`
- `Planner 调用`
- `执行结果展示`

#### 2. Planner

Planner 必须是唯一控制平面。

职责：

- 理解用户目标
- 识别是聊天、单次任务、工作流、服务、恢复、浏览器协同还是长期自动化
- 决定是否需要澄清
- 决定使用哪些 skill / service / browser / agent
- 决定是否拆 subtasks
- 决定是否创建或继续 workflow run
- 决定是否唤醒专家组
- 决定何时提醒用户、何时自动继续、何时重规划

不负责：

- 直接执行 browser/service/skill
- 自己维护任务运行状态

### 3. Planner Expert Group

专家组不是独立于 Planner 的第二个调度器。

正确定位是：

- `Planner 的增强决策阶段`
- `在特定条件下被 Planner 召集`
- `输出结构化意见，仍由 Planner 收敛成最终 dispatch decision`

不能变成：

- 一个绕过 Planner 的平行系统
- 一个只做日志分析和“看起来很聪明”的旁路 reviewer

### 4. Task / WorkflowRun

这层是执行态事实源。

职责：

- 保存定义
- 保存运行实例
- 保存 phase / checkpoint / approvals / failures / outputs
- 保存下一次唤醒时间和等待条件

在现有代码里：

- `TaskCenterFacade` 应继续作为运行态总入口
- `WorkflowRunCoordinator` 应继续作为 workflow runtime 执行器

### 5. Service

Service 不是 skill，也不是 subtask。

Service 的定义应该是：

- 长期存在的受管资源或自动化产品外壳
- 可启停、可检查、可恢复
- 可绑定 workflow definition
- 可被 Planner 当作长期能力资产来调用

例如：

- MCP 服务
- 浏览器托管助手
- 消息监听服务
- 定时报表服务

### 6. Skill

Skill 是原子能力。

职责：

- 做一件清晰且边界明确的事
- 被 Planner 发现和调用
- 可用于 workflow step
- 可作为 subtasks 的执行器之一

不能承担：

- 长期状态机
- 用户协商
- 高层规划

### 7. Subtask

Subtask 应从“用户感知的一套并行任务系统”降级成“Planner 拆出来的执行单元”。

建议定义：

- Subtask 是有边界的子工作项
- 可以并行
- 可以委托给 Agent / Skill / Service / Browser executor
- 可以挂在 workflow run 下，也可以挂在单次复杂任务下

但默认不应该抢主视觉。

UI 原则：

- 默认显示 Task / WorkflowRun
- Subtask 只在“执行详情”“并行步骤”“失败细节”里展开
- 不应该与 Task 平级竞争用户注意力

## Planner 的正式调度模型

### 新的 Planner 决策输出

Planner 不应只返回一个 `primaryAction`。

短期为了兼容可以保留 `primaryAction`，但目标模型应升级为：

```swift
struct PlannerDispatchDecision {
    let intent: PlannerIntent
    let controlMode: PlannerControlMode
    let needsClarification: Bool
    let clarificationItems: [PlanningSlot]
    let assignments: [ExecutionAssignment]
    let selectedWorkflowID: String?
    let selectedServiceID: String?
    let selectedSkills: [String]
    let selectedSubtasks: [SubtaskBlueprint]
    let committeeReview: CommitteeReview?
    let evidence: [PlannerEvidence]
    let replanReason: ReplanReason?
}
```

兼容期做法：

- `RequestPlan.primaryAction` 继续保留
- 新增 `dispatchAssignments`
- 新增 `committeeSignals`
- 新增 `selectedResources`
- 最终再逐步从单 action 迁到多 assignment

### Planner 的标准判断顺序

#### Step 1. 识别目标类型

先判断当前请求属于哪类：

- 普通聊天
- 单次低复杂任务
- 多步骤 workflow
- 长期 service/automation
- 现有 workflow 的继续输入
- 浏览器协同
- 恢复/异常处理

#### Step 2. 识别约束

Planner 必须抽取这些约束：

- 风险等级
- 是否需要审批
- 是否涉及外部通信
- 是否存在长时运行
- 是否需要服务依赖
- 是否可并行拆解
- 是否需要专家组

#### Step 3. 选调度策略

Planner 只允许从以下几类路径里选：

- `routeToMainConversation`
- `executeSingleSkill`
- `startOrContinueWorkflow`
- `startOrReuseService`
- `decomposeIntoSubtasks`
- `askForClarification`
- `escalateToExpertGroup`

#### Step 4. 产出执行分配

执行分配应该是结构化的：

- 谁执行
- 依赖什么
- 是否串行或并行
- 是否要审批
- 执行结果回到哪里

#### Step 5. 注册观察与唤醒条件

每次规划完，不仅要生成动作，还要生成 wake 条件：

- 等用户回复
- 等任务完成
- 等服务状态变化
- 等浏览器页面变化
- 等时间到

## Skill、Service、Subtask、Workflow 的关系

### Skill 与 Service 的关系

- Skill 是原子动作
- Service 是长期运行资源或自动化产品

一个 Service 可以依赖多个 Skill。  
一个 Skill 也可以被多个 Service / Workflow 复用。

### Workflow 与 Subtask 的关系

- Workflow 是长期状态化编排
- Subtask 是执行颗粒

一个 WorkflowRun 可以派生多个 Subtask。  
Subtask 完成后把结果回填到 WorkflowRun。

### Service 与 Workflow 的关系

推荐关系是：

- `Service` 负责“长期可启停、可管理的产品外壳”
- `WorkflowDefinition` 负责“这个服务内部如何运作”

也就是说：

- 有些 Service 直接绑定一个 WorkflowDefinition
- 有些 Service 只暴露一个运行资源，由 Planner 按需调用

## 专家组 Planner 设计

### 定位

专家组不是“多几个 LLM 一起回答”。

它的正确定义是：

- 对高价值、高风险、跨域、低置信度场景的增强分析层
- 产出结构化意见
- 仍由主 Planner 收敛为唯一决策

### 何时触发专家组

建议只在这些场景触发：

- Planner 置信度低
- 请求跨多个执行域
- 涉及外部通信和自动发送
- 存在高风险动作
- workflow 连续失败
- 需要长期 autonomy 策略判断
- 用户明确要求“专家组”“会诊”“多模型判断”

不建议：

- 每条输入都拉起专家组
- 把专家组当默认 planner

### 专家组角色

建议固定 4 个常驻角色，加 1 个动态专家：

- `Intake Expert`
  - 负责理解真实诉求和用户意图
- `Capability Expert`
  - 负责匹配 skill / service / tool / browser capability
- `Runtime Expert`
  - 负责判断 workflow、subtask、service 的最优执行形态
- `Risk & Policy Expert`
  - 负责自动化边界、审批策略、风险限制
- `Domain Specialist`
  - 按需选择 browser / communication / coding / system / service 等专家

### 专家组输出

专家组必须输出结构化结果，而不是只有文字意见：

```swift
struct CommitteeReview {
    let triggerReason: CommitteeTriggerReason
    let participatingExperts: [ExpertRole]
    let decision: CommitteeDecision
    let confidence: Double
    let recommendedAssignments: [ExecutionAssignment]
    let requiredApprovals: [ApprovalRequirement]
    let requiredClarifications: [PlanningSlot]
    let risks: [CommitteeRisk]
    let dissentNotes: [String]
}
```

### 专家组与主 Planner 的关系

正确流程：

`Planner 初判 -> 触发专家组 -> 专家组给结构化意见 -> Planner 合并意见 -> 产出最终 dispatch`

不应该：

`Planner 给一个方案 -> 专家组异步发点评论 -> 主链继续照旧跑`

## 调度规则

### 什么时候直接调 Skill

满足这些条件时优先直接走 Skill：

- 单步即可完成
- 风险低
- 不需要长状态
- 不需要多阶段审批
- 不依赖长期运行服务

示例：

- 截图
- 读取当前页面
- 查询服务状态
- 格式转换

### 什么时候创建 Subtasks

满足这些条件时拆子任务：

- 问题天然可并行
- 需要多个执行域协同
- 某些步骤适合交给不同 agent / executor
- 主 Planner 不希望在一个大任务里串行阻塞

示例：

- “分析一个项目，找 bug、补测试、总结风险”
- “同时检查 3 个服务状态并生成恢复建议”

### 什么时候升级成 Workflow

满足这些条件时必须进入 Workflow：

- 多步骤
- 有审批/等待输入
- 有失败重试
- 有定时或事件唤醒
- 有长期状态
- 有代办、监控、托管属性

示例：

- 浏览器接管 WhatsApp 会话
- 服务故障恢复链路
- 定时报表采集与发送

### 什么时候走 Service

满足这些条件时优先利用 Service：

- 已存在长期运行资源
- 任务依赖服务 runtime
- 用户要的是“持续能力”，不是单次动作
- 需要启停、状态检查、健康恢复

示例：

- 启动/停止 MCP 服务
- 使用已运行的 Browser automation service
- 使用消息监听 service

## 浏览器场景里的 Planner 调度原则

浏览器只是执行层。

对浏览器相关诉求，Planner 应这样决策：

- 轻量页面操作 -> 直接 skill/browser executor
- 当前会话继续操作 -> continue browser session
- 登录后长期托管/代聊/监控 -> 升级为 workflow
- 自动回复 / 外部沟通 -> 高风险，触发专家组或至少触发 risk expert

浏览器观察结果必须自动回流 Planner：

- 页面切换
- 登录成功
- 新消息出现
- 按钮状态变化
- DOM 显著变化
- 操作失败

## UI 展示原则

### 主会话

主会话展示：

- Planner 的问题和建议
- 当前 task/workflow 的摘要卡片
- 需要用户审批或补槽位的事项
- 服务状态变化提醒

主会话不展示：

- 默认全量 subtasks 列表
- 所有执行细节日志

### 任务中心

任务中心主视角应是：

- Task / WorkflowRun

Subtask 只在以下情况展开：

- 用户点开详情
- 子任务失败
- 子任务等待用户输入
- 子任务是当前瓶颈

### 服务页

服务页只展示：

- 服务定义
- 当前 runtime
- 健康状态
- 绑定的 workflow / task 概览

不负责替代 Planner 做调度。

## 基于当前代码的具体收口建议

### A. `RequestPlanner.swift`

目标：

- 保留入口
- 升级成真正的 `PlannerCoordinator`

建议拆成内部阶段：

- `IntakePlannerStage`
- `DispatchPlannerStage`
- `CommitteePlannerStage`
- `ReflectionPlannerStage`

但对外 API 先不改：

```swift
func plan(_ envelope: RequestEnvelope) async -> RequestPlan
```

### B. `PlannerCommitteeService.swift`

目标：

- 从旁路 reviewer 变成 Planner 的正式增强阶段

近期必须先修：

- 不再从 `[String: String]` 硬读 `Double` 和 `WorkflowRunState`
- 只消费结构化字段：
  - `confidence`
  - `evidence`
  - `replanReason`
  - `workflowCandidate`
  - `taskSpecs`
  - `intentKind`
  - `RequestEnvelope`

建议新增：

- `CommitteeSignal`
- `CommitteeReview`
- `ExpertRole`
- `CommitteePolicy`

### C. `CommandRunner.swift`

目标：

- 降级为“主会话 IO + plan executor”

需要逐步迁出：

- 边执行边规划的逻辑
- 大量跨域判断
- 一些实际上属于 planner 的 follow-up 判断

保留职责：

- 装配上下文
- 调 Planner
- 执行 Planner 输出
- 呈现消息和任务卡

### D. `SubtaskCoordinator.swift`

目标：

- 从“独立智能拆解器”降级为“Planner 下游的执行容器”

建议保留：

- 子任务模型
- 生命周期管理
- 与 `UnifiedTaskManager` / `TaskCenterFacade` 的映射

建议迁出：

- `decomposeTask(_:)`
- 由向量匹配直接决定 strategy 的逻辑

正确模式应是：

- Planner 产出 `SubtaskBlueprint[]`
- SubtaskCoordinator 执行和追踪

### E. `TaskCenterFacade.swift`

目标：

- 保持执行态事实源

建议新增能力：

- 记录 planner checkpoints
- 记录 workflow -> subtask 的映射
- 记录 service -> workflow run 的映射
- 给主会话提供统一 attention/query API

### F. `ServiceManager.swift`

目标：

- 保持长期资源管理器定位

建议新增能力：

- 暴露给 Planner 的 service inventory API
- 标记 service 的 planner-affinity：
  - 可直接调用
  - 必须先启动
  - 适合后台巡检
  - 适合 workflow 绑定

### G. `SkillCatalog.swift`

目标：

- 保持原子能力目录定位

建议新增能力：

- 按风险等级过滤
- 按 autonomy mode 过滤
- 按 domain 和 executor 优先级排序

## 建议新增的数据模型

### 1. PlannerDispatchModels.swift

建议新增：

- `PlannerIntent`
- `PlannerDispatchDecision`
- `ExecutionAssignment`
- `ExecutionAssignmentKind`
- `SubtaskBlueprint`
- `CommitteeSignal`
- `CommitteeReview`

### 2. PlannerCheckpointModels.swift

建议新增：

- `PlannerCheckpoint`
- `PlannerWakeEvent`
- `PlannerDecisionSnapshot`

### 3. ServicePlanningModels.swift

建议新增：

- `ServicePlanningProfile`
- `ServiceBinding`
- `ServiceAutomationMode`

## 分阶段落地路径

### Phase 1. 收口职责，不大改外部接口

目标：

- 明确 Planner 是唯一总调度
- 让 `SubtaskCoordinator` 不再主动做分解
- 让 `PlannerCommitteeService` 改成结构化 review

动作：

- 给 `RequestPlan` 增结构化 dispatch 字段
- 把 committee 触发条件改成读结构化字段
- 禁止新功能继续把 planning 逻辑塞进执行器

### Phase 2. 让 Planner 真正调度 Skill / Service / Workflow / Subtask

目标：

- Planner 产出 `ExecutionAssignment[]`

动作：

- Skill 直接 assignment
- Service 启停 assignment
- Workflow 启动/继续 assignment
- Subtask blueprint assignment

### Phase 3. 重构 Subtask

目标：

- 子任务成为 Planner 下游执行单元

动作：

- `SubtaskCoordinator` 只负责执行和同步
- 任务中心把 subtasks 默认收起
- 只在详情层展示 subtasks

### Phase 4. 专家组接管高价值规划

目标：

- 专家组成为 Planner 的正式增强层

动作：

- 固定 4+1 专家角色
- 输出结构化 review
- 把 browser/service/communication 这些高自治场景接入 committee gating

### Phase 5. Reflection / Wake 完整闭环

目标：

- 所有重要观察都能唤醒 Planner

事件源：

- workflow state change
- service health change
- browser observation change
- subtask failure
- timer wake

## 推荐的最终关系图

```text
主会话
  -> Planner
      -> 专家组（按需）
      -> 选择 Skill
      -> 选择 Service
      -> 创建/继续 WorkflowRun
      -> 拆解 Subtasks
  -> TaskCenter / WorkflowRun 作为执行态事实源
  -> 执行器层执行
  -> Observation 回流 Planner
```

## 最终结论

- `主会话` 是秘书窗口，不是调度器。
- `Planner` 必须是唯一总调度。
- `专家组` 是 Planner 的增强决策机制，不是平行系统。
- `Task/WorkflowRun` 是执行态事实源。
- `Service` 是长期封装和受管资源。
- `Skill` 是原子能力。
- `Subtask` 是 Planner 派生出来的执行单元，不应继续做独立规划。

如果坚持这条边界，整个系统会从“很多模块各自聪明一点”变成“Planner 统一看全局、其他模块只做本职执行”。
