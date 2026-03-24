# Browser Agent 接入 Planner 重构方案

## 目标

把浏览器自动化从“BrowserSessionCoordinator 内部自我决策”改成“Planner 驱动、Workflow 承载、Browser 执行”。

目标链路：

`Browser Observation -> Planner Decision -> Workflow / Pending Approval -> Browser Executor`

用户体验目标：

1. 用户说“打开 WhatsApp”
2. 浏览器打开网页，系统自动识别页面状态
3. 登录成功或页面变化后，Planner 自动被唤醒
4. Planner 基于当前网页状态决定：
   - 继续追问
   - 提出下一步建议
   - 生成可确认动作
   - 升级为长期 workflow
5. Browser 只负责执行已规划的网页动作，不负责高层理解

## 当前问题

### 1. Planner 只做了入口分流，没有真正规划浏览器任务

当前 `RequestPlanner` 对浏览器只会产出两种动作：

- `startBrowserSession`
- `continueBrowserSession`

问题在于，这只是“把请求送进浏览器模块”，不是“生成浏览器执行计划”。

### 2. BrowserSessionCoordinator 承担了过多高层决策

当前 `BrowserSessionCoordinator` 既负责：

- 导航
- 抓取页面快照
- 判断页面状态
- 决定下一句追问
- 推断待确认动作
- 部分站点特化处理（如 WhatsApp）

这使它变成了事实上的“浏览器内 planner”。

### 3. 浏览器观察信息没有正式进入 Planner 决策模型

虽然 `RequestEnvelope` 已经带有：

- `activeBrowserSession`
- `activeBrowserSnapshot`

但 planner 目前主要只在 `shouldContinueBrowserSession` 中用这些信息做轻量判定，而不是结构化规划。

### 4. 浏览器事件没有系统性唤醒 Planner

当前 `PlannerWakeService` 主要围绕 workflow run。

网页登录成功、页面跳转、新消息出现、未读变化、DOM 变化，这些事件还没有成为 planner 的正式唤醒源。

### 5. Browser session 还不是正式的可规划对象

现在 `BrowserSession` 更像：

- 页面状态缓存
- 最近动作列表
- 待确认动作容器

它缺少：

- planner 决策状态
- 当前自动化目标
- 自主等级
- 待澄清问题
- 上一次观察与本次观察的差异
- 是否应提升为 workflow 的信号

## 设计原则

1. Browser 是执行层，不是规划层
2. Planner 必须能直接消费浏览器观察信息
3. 持续性浏览器任务应升级为 workflow run，而不是长期停留在 browser session
4. 页面变化应当成为 planner wake trigger
5. 高层意图、页面观察、执行动作、审批点必须分层建模

## 目标架构

### 分层

#### 1. Browser Observation Layer

职责：

- 抓取当前页面结构化信息
- 做轻量语义分类
- 产生页面变化事件

输出对象：

- `BrowserObservation`
- `BrowserObservationDelta`
- `BrowserAutomationSignal`

#### 2. Planner Layer

职责：

- 理解用户高层目标
- 结合当前页面观察做下一步规划
- 决定是：
  - 追问
  - 给建议
  - 生成待确认动作
  - 自动执行一步
  - 升级为 workflow

#### 3. Workflow Layer

职责：

- 承载长期运行的浏览器自动化任务
- 管理审批、等待、重规划、提醒、恢复

#### 4. Browser Executor Layer

职责：

- 执行已规划好的浏览器动作
- 回传执行结果
- 不做高层推断

## 一句话定案

短会话网页协同可以停留在 `BrowserSession`。  
持续/代聊/监控/托管这类需求必须提升为 `WorkflowRun`。  
Planner 决定何时从前者进入后者。

## 数据模型改造

### A. 扩展 BrowserSessionModels.swift

文件：

- `mac-app/MacAssistant/MacAssistant/Models/BrowserSessionModels.swift`

新增模型：

```swift
struct BrowserObservation: Equatable, Codable {
    let id: String
    let sessionID: String
    let title: String
    let url: String
    let pageKind: BrowserPageKind
    let authState: BrowserAuthState
    let textExcerpt: String
    let actionableElements: [BrowserElementCandidate]
    let screenshotPath: String?
    let capturedAt: Date
}

struct BrowserObservationDelta: Equatable, Codable {
    let fromObservationID: String?
    let toObservationID: String
    let urlChanged: Bool
    let authStateChanged: Bool
    let pageKindChanged: Bool
    let majorTextChanged: Bool
    let newActionables: [BrowserElementCandidate]
}

enum BrowserAutonomyMode: String, Codable, Equatable {
    case assistive          // 只建议，不执行
    case approvalRequired   // 先给动作/回复草稿，待用户确认
    case autoExecute        // 低风险动作自动执行
}

struct BrowserPlannerState: Equatable, Codable {
    var userGoal: String?
    var autonomyMode: BrowserAutonomyMode
    var pendingQuestion: String?
    var pendingQuestionSlots: [PlanningSlot]
    var lastPlannerSummary: String?
    var lastPlannerDecisionAt: Date?
    var suggestedNextSteps: [String]
    var shouldPromoteToWorkflow: Bool
}

struct BrowserActionProposal: Equatable, Codable, Identifiable {
    let id: String
    let sessionID: String
    let actionType: String
    let target: String?
    let value: String?
    let rationale: String
    let confidence: Double
    let requiresApproval: Bool
}
```

对 `BrowserSession` 增加：

```swift
var latestObservation: BrowserObservation?
var previousObservation: BrowserObservation?
var latestDelta: BrowserObservationDelta?
var plannerState: BrowserPlannerState
var pendingProposal: BrowserActionProposal?
var linkedWorkflowRunID: String?
```

### B. 扩展 RequestPlanningModels.swift

文件：

- `mac-app/MacAssistant/MacAssistant/Models/RequestPlanningModels.swift`

对 `RequestEnvelope` 增加：

```swift
let activeBrowserObservation: BrowserObservation?
let activeBrowserDelta: BrowserObservationDelta?
```

新增 planner 动作：

```swift
case requestBrowserClarification(
    sessionID: String,
    question: String,
    slots: [PlanningSlot]
)
case proposeBrowserAction(
    sessionID: String,
    proposal: BrowserActionProposal
)
case executeBrowserProposal(
    sessionID: String,
    proposalID: String
)
case promoteBrowserSessionToWorkflow(
    sessionID: String,
    candidate: WorkflowCandidate
)
case analyzeBrowserObservation(
    sessionID: String,
    trigger: PlannerCheckpoint.WakeUpTrigger
)
```

对 `RequestPlan` 增加：

```swift
let browserProposal: BrowserActionProposal?
let browserSessionID: String?
let browserNeedsObservationRefresh: Bool
```

说明：

- 不建议把浏览器规划结果塞进 `metadata` 黑盒字符串。
- 这部分要升级成正式字段，避免浏览器自动化长期停留在“消息 metadata 驱动流程”。

## Planner 改造

### A. 新增 browser-aware planning

文件：

- `mac-app/MacAssistant/MacAssistant/Services/RequestPlanner.swift`
- `mac-app/MacAssistant/MacAssistant/Services/RequestPlanningHeuristics.swift`

新增内部方法：

```swift
private func planForActiveBrowserSession(
    envelope: RequestEnvelope,
    parsed: ParsedInput
) -> RequestPlan?

private func planForBrowserObservation(
    session: BrowserSession,
    observation: BrowserObservation,
    delta: BrowserObservationDelta?,
    userInput: String,
    lastMessage: ChatMessage?
) -> RequestPlan
```

Planner 不应只做：

- `continueBrowserSession(sessionID:input:)`

而要做以下判断：

1. 当前页面是否仍处于登录/扫码阻塞态
2. 页面是否已从登录页切到业务页
3. 当前用户输入是高层目标，还是具体动作
4. 当前任务应停留在 browser session 还是提升为 workflow
5. 当前动作是否需要先审批
6. 是否应自动刷新观察再规划

### B. 新增 browser heuristics

`RequestPlanningHeuristics.swift` 增加：

```swift
static func browserIntentKind(
    text: String,
    session: BrowserSession?,
    observation: BrowserObservation?
) -> BrowserIntentKind

static func shouldPromoteBrowserSessionToWorkflow(
    text: String,
    session: BrowserSession,
    observation: BrowserObservation?
) -> Bool

static func browserClarificationSlots(
    text: String,
    observation: BrowserObservation?
) -> [PlanningSlot]

static func buildBrowserActionProposal(
    text: String,
    observation: BrowserObservation,
    session: BrowserSession
) -> BrowserActionProposal?
```

浏览器输入至少要被分成：

- `describePage`
- `fillOrClick`
- `highLevelAutomationGoal`
- `reviewPendingProposal`
- `resumeAfterAuth`
- `promoteToWorkflow`

## BrowserSessionCoordinator 改造

文件：

- `mac-app/MacAssistant/MacAssistant/Services/BrowserAgent/BrowserSessionCoordinator.swift`

### 当前职责过重，需要下沉

保留职责：

- `startSession`
- `refreshObservation`
- `executeProposal`
- `captureObservation`
- `cancelPendingProposal`

迁出职责：

- 决定要不要问用户下一步
- 决定 WhatsApp 代聊意图怎么理解
- 决定是否要升级为 workflow
- 决定是否自动执行

### 推荐接口

```swift
func startSession(url: String, originalInput: String) async -> BrowserSessionStartResult
func refreshObservation(sessionID: String) async -> BrowserObservation?
func executeProposal(sessionID: String, proposal: BrowserActionProposal) async -> BrowserExecutionResult
func applyPlannerState(sessionID: String, state: BrowserPlannerState)
```

### 明确原则

`BrowserSessionCoordinator` 不再直接生成“你可以告诉我要继续做什么”这种高层话术。  
这些应该由 planner 决定，再由 `CommandRunner` 表达给用户。

## Browser Observation 抽取

新增文件：

- `mac-app/MacAssistant/MacAssistant/Services/BrowserAgent/BrowserObservationBuilder.swift`
- `mac-app/MacAssistant/MacAssistant/Services/BrowserAgent/BrowserObservationDiffer.swift`

职责：

- 从 `SimpleBrowserAgent.captureSnapshot()` 结果构建 `BrowserObservation`
- 比较前后观察结果，得到 `BrowserObservationDelta`

这样可以避免：

- `SimpleBrowserAgent` 同时负责抓取、分析、分类、差异检测

## CommandRunner 改造

文件：

- `mac-app/MacAssistant/MacAssistant/Services/CommandRunner.swift`

新增处理分支：

```swift
case .requestBrowserClarification(...)
case .proposeBrowserAction(...)
case .executeBrowserProposal(...)
case .promoteBrowserSessionToWorkflow(...)
case .analyzeBrowserObservation(...)
```

职责：

- 把 planner 的 browser 决策投影成主会话消息
- 维护 pending control message
- 执行用户对 proposal 的确认/拒绝
- 当 browser session 升级为 workflow 时，创建 draft 或直接启动 run

## ContextAssembler 改造

文件：

- `mac-app/MacAssistant/MacAssistant/Services/ContextAssembler.swift`

新增组装内容：

- `activeBrowserObservation`
- `activeBrowserDelta`
- `activeBrowserSession.plannerState`

这一步很关键。  
如果只把 `snapshot` 放进去，而不把 `delta`、`plannerState` 放进去，planner 仍然无法理解：

- 是刚登录成功
- 还是刚收到新消息
- 还是上一步操作失败

## Planner Wake 改造

文件：

- `mac-app/MacAssistant/MacAssistant/Services/Planner/PlannerWakeService.swift`

### 当前问题

目前 wake 服务主要围绕 workflow run。  
要扩成同时支持 browser session。

新增上下文：

```swift
struct BrowserWakeContext {
    let sessionID: String
    let observation: BrowserObservation?
    let delta: BrowserObservationDelta?
    let plannerState: BrowserPlannerState?
}
```

新增 wake 触发源：

- 页面 URL 变化
- authState 变化
- pageKind 变化
- 新消息出现
- 可操作元素显著变化
- 动作执行完成
- 动作执行失败

新增执行动作：

- `analyzeBrowserObservation`
- `promoteBrowserSessionToWorkflow`
- `requestBrowserClarification`
- `proposeBrowserAction`

### 唤醒优先级

高优先级：

- `authStateChanged`
- `newMessageReceived`
- `actionFailed`

中优先级：

- `pageKindChanged`
- `majorTextChanged`

低优先级：

- 周期巡检

## Workflow 集成策略

### 关键原则

不要新建一套 `BrowserRun` 与 `WorkflowRun` 并行竞争。  
浏览器自动化的长期任务，应该进入现有 workflow 系统。

### 升级条件

当满足以下任一条件时，从 browser session 提升为 workflow：

1. 用户目标是持续性的
   - 监控
   - 托管
   - 自动回复
   - 长期接待
2. 任务需要多轮页面变化
3. 任务包含审批/提醒/重规划
4. 任务要跨时间运行

### 升级结果

- `BrowserSession` 保留为 execution context
- `WorkflowRun` 成为 orchestration container
- `BrowserStepExecutor` 负责实际网页动作

## WhatsApp 代聊场景示例

### 目标行为

用户说：

`打开 WhatsApp`

执行过程：

1. Browser 打开 WhatsApp
2. Observation 识别为 `needsScan`
3. Planner 输出：
   - “当前是扫码登录页，请登录后我再继续规划”
4. 用户扫码成功
5. Browser 页面变化触发 wake
6. Planner 重新分析 observation，识别为 `chat`
7. Planner 主动追问：
   - “我已进入聊天页。你是要我只读取未读，还是进入托管回复模式？”
8. 用户说：
   - “托管回复，但每次先给我草稿确认”
9. Planner 识别为长期自动化目标，生成 workflow draft
10. 用户确认
11. Workflow run 启动：
   - 读取未读
   - 生成回复草稿
   - 等用户确认
   - Browser executor 发回消息

这条链路里，浏览器只负责：

- 读取页面
- 搜索联系人
- 输入文字
- 点击发送

Planner 负责：

- 判断当前阶段
- 生成追问
- 识别托管模式
- 决定升级为 workflow

## 文件级改造清单

### 新增文件

- `mac-app/MacAssistant/MacAssistant/Services/BrowserAgent/BrowserObservationBuilder.swift`
- `mac-app/MacAssistant/MacAssistant/Services/BrowserAgent/BrowserObservationDiffer.swift`
- `mac-app/MacAssistant/MacAssistant/Services/BrowserAgent/BrowserPlannerBridge.swift`

### 修改文件

- `mac-app/MacAssistant/MacAssistant/Models/BrowserSessionModels.swift`
- `mac-app/MacAssistant/MacAssistant/Models/RequestPlanningModels.swift`
- `mac-app/MacAssistant/MacAssistant/Services/ContextAssembler.swift`
- `mac-app/MacAssistant/MacAssistant/Services/RequestPlanningHeuristics.swift`
- `mac-app/MacAssistant/MacAssistant/Services/RequestPlanner.swift`
- `mac-app/MacAssistant/MacAssistant/Services/CommandRunner.swift`
- `mac-app/MacAssistant/MacAssistant/Services/BrowserAgent/BrowserSessionStore.swift`
- `mac-app/MacAssistant/MacAssistant/Services/BrowserAgent/BrowserSessionCoordinator.swift`
- `mac-app/MacAssistant/MacAssistant/Services/Planner/PlannerWakeService.swift`
- `mac-app/MacAssistant/MacAssistant/Services/Workflow/StepExecutors/BrowserStepExecutor.swift`

## 实施阶段

### Phase 1: Observation 入 Planner

目标：

- 让 planner 真的看到浏览器观察信息

内容：

- 新增 `BrowserObservation`
- `ContextAssembler` 注入 observation / delta / plannerState
- `RequestPlanner` 新增 `planForActiveBrowserSession`

验收：

- 登录成功后，不需要用户再说“看看当前页面”，planner 也能理解页面已切换

### Phase 2: Browser 决策从 Coordinator 迁回 Planner

目标：

- 让高层判断回到 planner

内容：

- `BrowserSessionCoordinator` 下沉为执行层
- planner 产出 `requestBrowserClarification / proposeBrowserAction`

验收：

- “继续登录”“读取未读”“托管回复”这类高层指令由 planner 解释，不再由 browser coordinator 猜

### Phase 3: Browser -> Workflow 提升

目标：

- 浏览器持续任务进入统一 workflow runtime

内容：

- 新增 `promoteBrowserSessionToWorkflow`
- `BrowserStepExecutor` 使用 planner 产生的 proposal 或 workflow step spec

验收：

- WhatsApp 托管回复能落成 workflow run，而不是停留在 browser session

### Phase 4: Browser Wake

目标：

- 页面变化主动唤醒 planner

内容：

- Browser store / coordinator 发布 observation changed 事件
- `PlannerWakeService` 增加 browser session 扫描与事件处理

验收：

- 登录后 planner 自动追问下一步
- 新消息出现时 planner 自动生成下一步建议或 workflow reminder

## 最小落地建议

如果只做一轮最小切片，建议按这个顺序：

1. 扩展 `BrowserSessionModels.swift`
2. 扩展 `ContextAssembler.swift`
3. 在 `RequestPlanner.swift` 里新增 `planForActiveBrowserSession`
4. 把 `BrowserSessionCoordinator` 的“高层追问生成”迁回 `CommandRunner + Planner`
5. 再接 `PlannerWakeService`

## 最后结论

浏览器自动化不该继续靠 `BrowserSessionCoordinator` 内部规则堆智能。  
真正合理的方向是：

- Browser 负责观察与执行
- Planner 负责理解与规划
- Workflow 负责持续编排
- Wake Service 负责在页面变化后重新唤醒 Planner

只有这样，浏览器自动化才会从“工具调用”升级成真正的 AutoAgent。
