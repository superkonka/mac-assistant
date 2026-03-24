# 主会话协同型 Browser Agent 设计

## 设计目标

本方案解决的不是“怎么打开网页”，而是下面这条完整链路：

1. 用户给一个网页或说“打开某网站”
2. 系统用可见的 Safari/Chrome 打开页面
3. AI 读取当前网页的最小必要上下文
4. 主会话用自然语言告诉用户“我识别到这是一个什么页面”
5. 主会话继续和用户确认“接下来你要我做什么”
6. 用户回复后，AI 在同一个浏览器上下文里继续执行

目标场景是“人机共驾的 Web Agent”，不是纯后台爬虫。

## 当前代码现状

仓库里实际有两套浏览器链路：

- `SimpleBrowserAgent`
  - 使用 AppleScript 控制系统 Safari/Chrome
  - 适合可见浏览器、人机共视、扫码登录
- `BrowserAgentService`
  - 使用 Node.js + Playwright + Chromium
  - 适合无头自动化、截图、DOM 抽取、复杂流程

但现在两套实现没有统一到同一个主会话上下文：

- 聊天输入经 `ConversationController.processInput()` 进入
- 浏览器命令会在 `ConversationController` 被提前拦截并直接调用 `SimpleBrowserAgent`
- 主会话会收到“已打开 Safari”这类消息
- 但浏览器页面状态没有进入 `ConversationStores` / `RequestEnvelope`
- 因此用户下一句“这个页面帮我看看”时，planner 并不知道“当前页面是什么”

## 设计原则

- 继续使用系统浏览器作为有头执行器
  - 登录、扫码、授权、首次配置必须可见
- 主会话拥有最高控制权
  - 可以继续、确认、拒绝、取消
- 浏览器状态必须进入会话上下文
  - 否则主会话无法持续协同
- 浏览器动作先走确定性规则，再决定是否需要 LLM 推理
  - 避免把所有点击/输入都交给大模型猜
- 破坏性操作必须显式确认
  - 发送消息、提交表单、购买、删除、发布等
- 保留 Playwright 作为二阶段能力，不作为当前主链路依赖
  - 可作为 headless fallback 或高级自动化实现

## 总体架构

```text
用户输入
  -> ConversationController
  -> RequestPlanner
  -> ConversationRuntime / CommandRunner
  -> BrowserSessionCoordinator
  -> BrowserRuntime
     -> SystemBrowserRuntime(SimpleBrowserAgent)
     -> PlaywrightBrowserRuntime(BrowserAgentService) [可选二阶段]
```

## 核心新增对象

### 1. BrowserRuntime

定义统一浏览器执行协议，屏蔽系统浏览器和 Playwright 的差异。

```swift
protocol BrowserRuntime {
    var mode: BrowserRuntimeMode { get }
    func ensureStarted() async throws
    func navigate(to url: String) async throws
    func evaluate(_ script: String) async throws -> String?
    func captureSnapshot() async throws -> BrowserPageSnapshot
    func screenshot() async throws -> BrowserScreenshot?
    func activate() async throws
    func stop() async
}
```

建议实现：

- `SystemBrowserRuntime`
  - 基于 `SimpleBrowserAgent`
  - 主链路默认使用它
- `PlaywrightBrowserRuntime`
  - 基于 `BrowserAgentService`
  - 作为高级模式或后台任务 fallback

### 2. BrowserPageSnapshot

页面快照是主会话理解网页的最小单元。

```swift
struct BrowserPageSnapshot: Codable {
    let title: String
    let url: String
    let textExcerpt: String
    let pageKind: BrowserPageKind
    let authState: BrowserAuthState
    let actionableElements: [BrowserElementCandidate]
    let screenshotPath: String?
    let capturedAt: Date
}
```

其中：

- `pageKind`
  - login
  - dashboard
  - search
  - form
  - article
  - list
  - checkout
  - unknown
- `authState`
  - unknown
  - needsLogin
  - needsScan
  - ready

### 3. BrowserSession

浏览器会话必须是一等状态，而不是 UI 边角料。

```swift
struct BrowserSession: Identifiable, Codable {
    let id: String
    let runtimeKind: BrowserRuntimeKind
    let createdAt: Date
    var updatedAt: Date
    var currentURL: String
    var latestSnapshot: BrowserPageSnapshot?
    var pendingAction: BrowserPendingAction?
    var lastUserGoal: String?
    var recentActions: [BrowserSessionAction]
    var status: BrowserSessionStatus
}
```

建议状态：

- idle
- navigating
- waitingUser
- executing
- blockedByAuth
- completed
- failed

### 4. BrowserSessionStore

负责把浏览器会话暴露给主会话。

职责：

- 管理 `activeBrowserSessionID`
- 存取 `BrowserSession`
- 向 `ConversationRuntime` 提供当前浏览器上下文
- 持久化轻量状态

## 会话上下文改造

### 1. ConversationStores

现在 `ConversationStores` 没有任何 browser context。需要新增：

```swift
var activeBrowserSessionID: String?
var browserSessions: [BrowserSession]
```

### 2. RequestEnvelope

现在 `RequestEnvelope` 里也没有浏览器上下文。建议增加：

```swift
let activeBrowserSession: BrowserSession?
let activeBrowserSnapshot: BrowserPageSnapshot?
```

### 3. ChatMessage metadata

为了让 planner 能处理“网页后续确认流”，需要标准 metadata：

- `pending_browser_session_id`
- `browser_prompt_kind`
- `browser_page_kind`
- `browser_url`
- `browser_requires_confirmation`

## 主会话交互流

### 流程 A：打开网页并识别

```text
用户: 打开 https://example.com
  -> BrowserRuntime.navigate()
  -> BrowserRuntime.captureSnapshot()
  -> BrowserPageAnalyzer 生成识别摘要
  -> 主会话追加 assistant 消息:
     “我已打开页面。识别到这是登录页/表单页/列表页。
      你希望我继续做什么？”
  -> 消息 metadata 写入 pending_browser_session_id
```

### 流程 B：主会话继续协同

```text
用户: 帮我登录
  -> planner 发现 activeBrowserSession / pending_browser_session_id
  -> continueBrowserSession(sessionID, input)
  -> BrowserActionPlanner 生成动作计划
  -> 若动作需要用户确认，主会话先确认
  -> 否则执行动作
  -> captureSnapshot()
  -> 汇报执行结果
```

### 流程 C：需要用户人工介入

```text
AI: 我识别到这是扫码登录页，请你先完成扫码。
    完成后直接回复“继续”或告诉我下一步。
```

这类状态应写入：

- `BrowserSession.status = .blockedByAuth`
- `authState = .needsScan`

### 流程 D：取消

浏览器协同流必须纳入主会话最高优先级取消链。

沿用现有 `cancelPendingFlow` 机制即可，但要覆盖：

- 浏览器待确认消息
- 当前 browser session 的 pendingAction
- blockedByAuth 等待状态

## Planner 设计

### 新增动作

```swift
enum RequestPlannerPrimaryAction {
    case startBrowserSession(url: String, originalInput: String)
    case continueBrowserSession(sessionID: String, input: String)
    case requestBrowserConfirmation(sessionID: String, prompt: String)
    case cancelPendingFlow
    ...
}
```

### 判定优先级

浏览器相关建议顺序：

1. `cancelPendingFlow`
2. `continueBrowserSession`
3. `startBrowserSession`
4. 普通 Agent / Skill 路由

### 新增 heuristics

- 识别直接 URL
- 识别“打开/访问/进入 + 网站”
- 识别“当前页面/这个页面/网页上/浏览器里”
- 识别“继续网页登录/继续网页操作”

### 关键点

不要把所有浏览器逻辑永久硬编码在 `ConversationController.detectBrowserCommand()` 里。  
最小迁移策略可以先保留它做首轮入口，但 browser session 的延续必须交给 planner。

## BrowserPageAnalyzer

建议新增轻量分析器，而不是一上来就用大模型控制浏览器。

输入：

- title
- url
- body text excerpt
- 可交互元素候选

输出：

- 页面类型
- 是否要求登录/扫码
- 可推荐下一步
- 是否需要用户确认

第一版可以纯规则：

- URL / 标题包含 `login/signin/auth`
- 页面正文包含 `扫码/二维码/验证码`
- 存在大量 `input[type=password]`
- 存在明显按钮文本：登录、授权、继续、提交、支付、发送

第二版再接 LLM，总结成自然语言：

```text
我识别到这是 GitHub 登录页。
你现在可以让我：
1. 输入用户名
2. 输入密码
3. 等你手动完成 2FA 后继续
4. 截图给你确认
```

## BrowserActionPlanner

负责把用户意图变成浏览器动作。

优先级：

1. 规则动作
   - navigate
   - click
   - fill
   - scroll
   - wait
   - extract
2. LLM 辅助推理
   - 当页面复杂且规则无法匹配时

建议动作模型：

```swift
struct BrowserExecutionPlan {
    let summary: String
    let needsConfirmation: Bool
    let steps: [BrowserExecutionStep]
}
```

需要确认的动作：

- 发送消息
- 提交表单
- 发布内容
- 下单/支付
- 删除/退出/关闭

## 对现有实现的具体调整建议

### 1. 保留 `SimpleBrowserAgent`，但升级为 `SystemBrowserRuntime`

需要补齐：

- `captureSnapshot()`
  - `document.title`
  - `location.href`
  - `document.body.innerText.slice(0, 3000)`
  - 提取可交互元素候选
- `screenshot()`
- 更稳妥的 AppleScript / JS 转义
- 真正的默认浏览器检测

### 2. `ConversationController`

从“直接处理浏览器对话”收敛为“识别浏览器入口请求并交给 runtime + planner”。

首轮保留：

- 对明显 URL/打开网站请求做快速导航

但导航完成后必须：

- 创建 `BrowserSession`
- 抓取 `BrowserPageSnapshot`
- 追加带 metadata 的 assistant 消息
- 后续回复走 planner 而不是继续在 `ConversationController` 里特殊分支

### 3. `ConversationRuntime / CommandRunner`

增加：

- `BrowserSessionStore` 绑定
- `startBrowserSession`
- `continueBrowserSession`
- `executeBrowserPlan`
- `appendBrowserFollowUpMessage`

### 4. `BrowserAgentView`

现在 UI 入口仍绑定旧 `BrowserAgentService`。建议改成统一浏览器工作台：

- 顶部显示当前 runtime
- 当前页标题/URL
- 最近动作
- 当前 browser session 状态
- “回到主会话继续”提示

`SimpleBrowserAgentView` 可并入该工作台，不建议继续平行维护两套 UI。

## 推荐分期

### Phase 1：可用闭环

目标：

- 打开可见浏览器
- 抓页面快照
- 主会话识别页面并询问下一步
- 用户回复后继续在同一页面执行

只做：

- SystemBrowserRuntime
- BrowserSessionStore
- start / continue browser session
- 基础页面识别

### Phase 2：安全执行

目标：

- 提交前确认
- 更稳的表单填写
- 发送消息/提交表单/发布等动作保护

### Phase 3：高级模式

目标：

- Playwright fallback
- 持久会话
- 工作流录制
- 后台自动化

## 成功标准

完成后，下面这段对话必须成立：

```text
用户: 打开 https://github.com/login
AI: 我已打开 GitHub 登录页，识别到这是账号登录页面。
    你要我帮你输入账号，还是等你手动登录后再继续？

用户: 先输入账号
AI: 好，我准备填写账号栏。填写后不会自动提交。
    请确认是否继续？

用户: 继续
AI: 已填写账号。接下来你可以让我输入密码，或你手动处理 2FA 后让我继续。
```

如果这段做不到，就说明浏览器还是“能打开”，但还不是“主会话协同型 Browser Agent”。

## 推荐的最小实现切片

第一刀不要做太大，建议只交付下面这组文件改造：

- `Services/BrowserAgent/SimpleBrowserAgent.swift`
  - 增加 `captureSnapshot()`
- `Services/BrowserAgent/`
  - 新增 `BrowserSessionStore.swift`
  - 新增 `BrowserPageAnalyzer.swift`
  - 新增 `BrowserSessionCoordinator.swift`
- `Models/ConversationPipelineModels.swift`
  - 新增 browser session 状态
- `Models/RequestPlanningModels.swift`
  - 新增 browser actions
- `Services/RequestPlanner.swift`
  - 新增 browser flow 判定
- `Services/CommandRunner.swift`
  - 新增 browser flow 执行

这样改动最小，但链路完整。
