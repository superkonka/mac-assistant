# Interaction Information Architecture

## Goal

`mac-assistant` should present OpenClaw as the runtime core and the desktop app as the entry point.
That means the UI must distinguish between:

- semantic conversation content
- runtime routing and execution traces
- delegated task sessions
- evidence and artifacts
- global system state

If all of those are rendered as normal chat bubbles, the main conversation becomes noisy and users lose track of what the AI actually answered.

## Core Principles

1. Main conversation is sacred.
Only user messages and final AI responses belong in the main transcript.

2. Runtime information is visible but weak.
Routing, tool execution, fallback, and provider handoff should be observable without competing with the answer.

3. Delegation becomes a task session.
If OpenClaw delegates work to another Agent or tool chain, that process should live in a child task session with its own lifecycle.

4. Evidence is attached, not injected.
Files read, screenshots used, commands run, and sources referenced should appear as support material under the relevant response.

5. Global issues stay global.
Permissions, authentication failures, gateway reconnects, and missing setup should appear as banners, status bars, or toasts, not as chat content.

## Information Layers

### L1. Main Conversation

Strongest visual weight.

Contains:

- user input
- assistant final answer
- assistant follow-up questions
- assistant conclusion after analyzing delegated task results

Must not contain:

- routing traces
- provider selection
- execution progress
- tool stdout
- auth diagnostics

UI form:

- current chat bubbles
- clean, readable, copyable

Current code anchor:

- `ChatMessage` in [ChatModels.swift](/Users/konka/code/mac-assistant/mac-app/MacAssistant/MacAssistant/Models/ChatModels.swift)
- `MessageBubble` in [MessageBubble.swift](/Users/konka/code/mac-assistant/mac-app/MacAssistant/MacAssistant/Views/MessageBubble.swift)

Recommendation:

- keep `ChatMessage` semantic-only
- reduce `.system` usage in the main transcript

### L2. Input Context Layer

Lightweight, request-scoped context shown near the composer.

Contains:

- selected Agent
- selected Skill
- attached screenshot or files
- current project/workspace scope
- temporary mode, such as "image analysis" or "code review"

UI form:

- chips above or below input
- removable tokens
- not persisted as transcript messages

Best placement:

- integrated with [IntelligentInputView.swift](/Users/konka/code/mac-assistant/mac-app/MacAssistant/MacAssistant/Views/Chat/IntelligentInputView.swift)

### L3. Execution Trace Layer

Weak, transient routing visibility for the current request.

Contains:

- `OpenClaw -> Agent -> Intent`
- fallback happened
- tool invocation started
- reasoning stage changes like `analyzing`, `delegating`, `synthesizing`

UI form:

- a compact trace strip
- small type, muted color
- step chips or breadcrumb
- spinner while active
- fade or collapse on completion

Good example copy:

- `OpenClaw · Kimi Coder · 一般对话`
- `OpenClaw · 委托给 Moonshot · 图片分析`
- `OpenClaw · 汇总子任务结果`

Bad example copy:

- `OpenClaw 正在使用 Kimi Coder 处理一般对话请求`

Current code anchor:

- route info is currently appended as `.system` messages in [CommandRunner.swift](/Users/konka/code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/CommandRunner.swift)

Recommendation:

- replace message-based route notices with a dedicated `ExecutionTrace` state model
- render that state in [ChatView.swift](/Users/konka/code/mac-assistant/mac-app/MacAssistant/MacAssistant/Views/Chat/ChatView.swift), not in `MessageBubble`

### L4. Task Session Layer

Medium visual weight for delegated work.

Contains:

- sub-agent execution
- long-running tool flows
- multi-step analysis tasks
- retries and status transitions

UI form:

- task card embedded in the main timeline
- shows title, status, owning agent, delegated agent, task type
- expandable transcript
- collapses automatically after completion

Current code anchor:

- `AgentTaskSession` in [ChatModels.swift](/Users/konka/code/mac-assistant/mac-app/MacAssistant/MacAssistant/Models/ChatModels.swift)
- [TaskSessionCardView.swift](/Users/konka/code/mac-assistant/mac-app/MacAssistant/MacAssistant/Views/Chat/TaskSessionCardView.swift)

Recommendation:

- use task cards only for real delegated work
- do not use them for every route hint

### L5. Evidence Layer

Support material attached to a final answer.

Contains:

- screenshot used
- files inspected
- commands executed
- search results or docs read
- provider/model used if user cares to inspect

UI form:

- collapsible evidence section under the assistant answer
- thumbnail previews
- file chips
- command cards
- source links

User value:

- improves trust
- makes AI work inspectable
- supports debugging without polluting the answer

Recommendation:

- attach evidence to the response that used it
- do not render evidence as standalone conversation bubbles

### L6. System State Layer

Global application status, not bound to one message.

Contains:

- screen capture permission missing
- provider auth failed
- OpenClaw gateway reconnecting
- no Agent configured
- background service unavailable

UI form:

- top banner
- status footer
- toast
- setup panel

Current code anchor:

- these cases often become assistant or system messages inside [CommandRunner.swift](/Users/konka/code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/CommandRunner.swift)

Recommendation:

- move persistent app-wide issues into a dedicated global status presenter

## Suggested UI Regions

### 1. Top Bar

Purpose:

- current main Agent
- session mode
- quick access to Agents and Skills
- optional global system badge

Current base:

- [ChatView.swift](/Users/konka/code/mac-assistant/mac-app/MacAssistant/MacAssistant/Views/Chat/ChatView.swift) `topBar`

### 2. Main Timeline

Purpose:

- user messages
- final assistant messages
- embedded task cards

Rules:

- only semantic chat items and task session cards
- no global errors
- no one-line route diagnostics as normal messages

### 3. Per-Request Trace Strip

Placement:

- directly between the triggering user message and the pending assistant response

Purpose:

- show transient runtime chain

Behavior:

- appears when request starts
- updates during routing
- fades or compresses when response completes
- expands into detail on click

### 4. Composer Context Rail

Placement:

- attached to the input area

Purpose:

- show current request context before send

Contents:

- Agent chip
- Skill chip
- screenshot/file chips
- project path chip

### 5. Inspector Panel

Placement:

- optional right-side drawer or popover

Purpose:

- raw traces
- tool details
- gateway events
- evidence
- provider metadata

This is where technical transparency belongs.
It should exist, but it should not compete with the main timeline.

## Data Model Refactor

### Problem Today

The main `messages` array is carrying too many responsibilities:

- semantic dialogue
- route diagnostics
- setup guidance
- fallback notices
- task card anchors

That is why the transcript feels mixed and unstable.

### Recommended Split

#### 1. Main transcript items

Keep semantic items only.

Possible direction:

```swift
enum TimelineItem: Identifiable, Equatable {
    case message(ChatMessage)
    case taskCard(String) // task session id
}
```

#### 2. Request-scoped execution trace

```swift
struct ExecutionTrace: Identifiable, Equatable {
    let id: UUID
    let requestID: UUID
    var steps: [ExecutionTraceStep]
    var state: TraceState
    var startedAt: Date
    var finishedAt: Date?
}
```

Use for:

- routing
- delegation
- fallback
- synthesis stage

#### 3. Global app status

```swift
struct AppStatusBanner: Identifiable, Equatable {
    let id: UUID
    let level: StatusLevel
    let title: String
    let detail: String
    let actionTitle: String?
}
```

Use for:

- auth
- missing permissions
- gateway disconnected
- setup required

#### 4. Evidence bundle

```swift
struct ResponseEvidence: Equatable {
    var screenshots: [String]
    var files: [String]
    var commands: [String]
    var sources: [String]
}
```

Attach to final assistant messages through metadata or a stronger typed field.

## Migration Mapping To Current Code

### Keep

- [TaskSessionCardView.swift](/Users/konka/code/mac-assistant/mac-app/MacAssistant/MacAssistant/Views/Chat/TaskSessionCardView.swift)
- `AgentTaskSession`
- main `ChatView` layout skeleton

### Change

- [CommandRunner.swift](/Users/konka/code/mac-assistant/mac-app/MacAssistant/MacAssistant/Services/CommandRunner.swift)
  - stop appending route hints as `.system` transcript messages
  - publish `currentExecutionTrace`
  - publish global status items separately
  - keep task session creation for real delegated tasks

- [MessageBubble.swift](/Users/konka/code/mac-assistant/mac-app/MacAssistant/MacAssistant/Views/MessageBubble.swift)
  - render semantic chat only
  - do not become a catch-all renderer for every system event

- [ChatView.swift](/Users/konka/code/mac-assistant/mac-app/MacAssistant/MacAssistant/Views/Chat/ChatView.swift)
  - add `TraceStripView`
  - add `ComposerContextBar`
  - add optional `StatusBannerView`
  - keep task cards inside the timeline

### Add

- `ExecutionTrace.swift`
- `TraceStripView.swift`
- `ComposerContextBar.swift`
- `StatusBannerView.swift`
- optional `InspectorPanelView.swift`

## Interaction Rules

### When user sends a normal message

Show:

- user bubble
- transient trace strip
- assistant final answer

Do not show:

- provider routing as a bubble

### When OpenClaw delegates to another Agent

Show:

- user bubble
- trace strip updates to `delegating`
- task session card appears
- task session completes and collapses
- assistant final synthesis answer

### When auth fails or permission is missing

Show:

- banner or inline actionable system state
- optional retry/configure action

Do not show:

- raw API error text as main answer content

### When user wants technical detail

Show:

- inspector panel or expanded task card

Do not show by default:

- verbose raw runtime logs

## Rollout Order

### Phase 1

- move route notices out of `messages`
- introduce `TraceStripView`
- keep current task card design

### Phase 2

- add composer context bar
- add global status banner system

### Phase 3

- add evidence attachments under final assistant replies
- add inspector panel for full trace and tool details

### Phase 4

- unify timeline into explicit `TimelineItem`
- reduce special-case rendering logic in `MessageBubble`

## Product Outcome

After this refactor, the user should feel that:

- the conversation is clean
- OpenClaw is visibly orchestrating work
- delegated tasks are inspectable
- technical detail is available on demand
- the desktop app is a deliberate interface over OpenClaw, not a debug console
