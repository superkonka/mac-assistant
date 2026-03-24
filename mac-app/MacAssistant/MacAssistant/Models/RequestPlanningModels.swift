//
//  RequestPlanningModels.swift
//  MacAssistant
//

import Foundation

enum AgentCreationRequestKind {
    case runtimeSetup
    case workflowDesign
}

// MARK: - Intent Classification

/// 用户意图类型
enum IntentKind: String, Codable, Equatable {
    case chat                    // 纯聊天
    case singleTask              // 单次任务
    case workflow                // 工作流编排
    case service                 // 服务/自动化
    case clarificationNeeded     // 需要澄清
}

// MARK: - Planning Slots

/// 信息槽位（用于补全 workflow 所需信息）
struct PlanningSlot: Codable, Equatable {
    let name: String            // 槽位名称
    let description: String     // 槽位描述
    let isRequired: Bool        // 是否必填
    var value: String?          // 已填充的值
    
    var isFilled: Bool { value != nil && !value!.isEmpty }
}

// MARK: - Workflow Candidate

/// Workflow 候选推荐
struct WorkflowCandidate: Codable, Equatable {
    let name: String                    // workflow 名称
    let description: String             // 描述
    let stepsPreview: [String]          // 步骤预览
    let estimatedSteps: Int             // 预估步骤数
    let needsConfirmation: Bool         // 是否需要用户确认
    let requiredCapabilities: [String]  // 所需能力
    let missingSlots: [PlanningSlot]    // 缺失的槽位
}

// MARK: - Planner Evidence

/// Planner 决策证据
struct PlannerEvidence: Codable, Equatable {
    let timestamp: Date
    let source: EvidenceSource
    let description: String
    let confidence: Double  // 0.0 - 1.0
    
    enum EvidenceSource: String, Codable {
        case heuristic       // 启发式规则
        case agentAnalysis   // Agent 分析
        case userHistory     // 用户历史
        case contextMatch    // 上下文匹配
        case explicitIntent  // 明确意图
    }
}

// MARK: - Replan Reason

/// 重规划原因
struct ReplanReason: Codable, Equatable {
    let timestamp: Date
    let trigger: ReplanTrigger
    let description: String
    let previousPlanID: String?
    
    enum ReplanTrigger: String, Codable {
        case userRequest         // 用户明确要求
        case stepFailed          // 步骤失败
        case stepCompleted       // 步骤完成
        case newInformation      // 新信息出现
        case timeout             // 超时
        case externalEvent       // 外部事件
        case reflectionDecision  // 反思决策
    }
}

enum PlannerConfidence: String {
    case high
    case medium
    case low
}

enum PlannerPrimaryStrategy: String, CaseIterable, Identifiable {
    case ruleBased
    case agentPrimary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ruleBased:
            return "规则优先"
        case .agentPrimary:
            return "Planner Agent 接管"
        }
    }

    var summary: String {
        switch self {
        case .ruleBased:
            return "主意图分析由本地规则 planner 执行。"
        case .agentPrimary:
            return "主意图分析优先交给选中的 Planner Agent，失败时自动回退规则 planner。"
        }
    }
}

enum RequestExecutionMode: String {
    case mainSession
    case sideSession
    case parallelSubtasks
}

enum PlannedTaskKind: String {
    case setupFlow
    case recovery
    case conversationControl
    case toolSkill
    case localSystemAction
    case explicitSkill
    case detectedSkill
    case agentSuggestion
    case mainConversation
    case background      // 新增：后台任务
    case workflow        // 新增：workflow 任务
}

struct PlannedTaskSpec: Identifiable, Hashable {
    let id: String
    let kind: PlannedTaskKind
    let title: String
    let executorLabel: String
    let summary: String
    let returnsToMainConversation: Bool
}

enum ExecutionAssignmentKind: String, Codable, Equatable {
    case conversation
    case skill
    case workflow
    case service
    case browser
    case subtask
    case agent
    case recovery
    case setup
    case background
    case notification
}

struct ExecutionAssignment: Identifiable, Codable, Equatable {
    let id: String
    let kind: ExecutionAssignmentKind
    let title: String
    let executorLabel: String
    let summary: String
    let targetID: String?
    let returnsToMainConversation: Bool
    let requiresApproval: Bool

    init(
        id: String,
        kind: ExecutionAssignmentKind,
        title: String,
        executorLabel: String,
        summary: String,
        targetID: String? = nil,
        returnsToMainConversation: Bool,
        requiresApproval: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.executorLabel = executorLabel
        self.summary = summary
        self.targetID = targetID
        self.returnsToMainConversation = returnsToMainConversation
        self.requiresApproval = requiresApproval
    }

    init(taskSpec: PlannedTaskSpec) {
        self.init(
            id: taskSpec.id,
            kind: Self.assignmentKind(for: taskSpec.kind),
            title: taskSpec.title,
            executorLabel: taskSpec.executorLabel,
            summary: taskSpec.summary,
            returnsToMainConversation: taskSpec.returnsToMainConversation,
            requiresApproval: false
        )
    }

    private static func assignmentKind(for kind: PlannedTaskKind) -> ExecutionAssignmentKind {
        switch kind {
        case .setupFlow:
            return .setup
        case .recovery:
            return .recovery
        case .conversationControl, .mainConversation:
            return .conversation
        case .toolSkill, .explicitSkill, .detectedSkill:
            return .skill
        case .localSystemAction:
            return .service
        case .agentSuggestion:
            return .agent
        case .background:
            return .background
        case .workflow:
            return .workflow
        }
    }
}

struct PlannerSelectedResources: Codable, Equatable {
    var workflowDefinitionID: String?
    var workflowRunID: String?
    var browserSessionID: String?
    var serviceIDs: [String]
    var skillIDs: [String]
    var subtaskIDs: [String]
    var agentIDs: [String]

    init(
        workflowDefinitionID: String? = nil,
        workflowRunID: String? = nil,
        browserSessionID: String? = nil,
        serviceIDs: [String] = [],
        skillIDs: [String] = [],
        subtaskIDs: [String] = [],
        agentIDs: [String] = []
    ) {
        self.workflowDefinitionID = workflowDefinitionID
        self.workflowRunID = workflowRunID
        self.browserSessionID = browserSessionID
        self.serviceIDs = serviceIDs
        self.skillIDs = skillIDs
        self.subtaskIDs = subtaskIDs
        self.agentIDs = agentIDs
    }
}

struct CommitteeSignal: Codable, Equatable {
    let triggerReason: CommitteeTriggerReason
    let summary: String
    let confidenceScore: Double
    let riskScore: Double
}

struct WorkflowDesignContinuationContext {
    let sessionID: String
    let originalInput: String
}

struct RequestEnvelope {
    let id: UUID
    let originalText: String
    let images: [String]
    let createdAt: Date
    let sessionTopology: ConversationSessionTopology
    let currentAgent: Agent?
    let needsInitialSetup: Bool
    let lastMessage: ChatMessage?
    let creationFlowActive: Bool
    let resumableTaskSessionID: String?
    let activeWorkflowDesignContext: WorkflowDesignContinuationContext?
    let activeBrowserSession: BrowserSession?
    let activeBrowserSnapshot: BrowserPageSnapshot?
    let activeBrowserObservation: BrowserObservation?
    let activeBrowserDelta: BrowserObservationDelta?
    let activeBrowserPlannerState: BrowserPlannerState?

    init(
        id: UUID = UUID(),
        originalText: String,
        images: [String],
        createdAt: Date = Date(),
        sessionTopology: ConversationSessionTopology,
        currentAgent: Agent?,
        needsInitialSetup: Bool,
        lastMessage: ChatMessage?,
        creationFlowActive: Bool,
        resumableTaskSessionID: String?,
        activeWorkflowDesignContext: WorkflowDesignContinuationContext?,
        activeBrowserSession: BrowserSession?,
        activeBrowserSnapshot: BrowserPageSnapshot?,
        activeBrowserObservation: BrowserObservation?,
        activeBrowserDelta: BrowserObservationDelta?,
        activeBrowserPlannerState: BrowserPlannerState?
    ) {
        self.id = id
        self.originalText = originalText
        self.images = images
        self.createdAt = createdAt
        self.sessionTopology = sessionTopology
        self.currentAgent = currentAgent
        self.needsInitialSetup = needsInitialSetup
        self.lastMessage = lastMessage
        self.creationFlowActive = creationFlowActive
        self.resumableTaskSessionID = resumableTaskSessionID
        self.activeWorkflowDesignContext = activeWorkflowDesignContext
        self.activeBrowserSession = activeBrowserSession
        self.activeBrowserSnapshot = activeBrowserSnapshot
        self.activeBrowserObservation = activeBrowserObservation
        self.activeBrowserDelta = activeBrowserDelta
        self.activeBrowserPlannerState = activeBrowserPlannerState
    }
}

struct PlannedAgentSwitch {
    let agent: Agent
    let reason: String
    let requiredCapability: Capability?
}

enum RequestPlannerPrimaryAction {
    case cancelPendingFlow
    case startBrowserSession(url: String, originalInput: String)
    case continueBrowserSession(sessionID: String, input: String)
    case continueAgentCreationFlow(input: String)
    case resumeInterruptedTask(sessionID: String)
    case respondToSkillEvolution(proposalID: String, accepted: Bool)
    case startWorkflowDesignSession(input: String)
    case continueWorkflowDesignSession(sessionID: String, originalInput: String, followUpInput: String)
    case respondToWorkflowDesignGuidance(originalInput: String, followUpInput: String, accepted: Bool)
    case respondToDetectedSkillSuggestion(messageID: UUID, action: DetectedSkillSuggestionAction)
    case respondToLegacySkillSuggestion(skill: AISkill, input: String, accepted: Bool)
    case requestInitialSetup
    case showSkillEvolutionOverview
    case showPlannerConsole
    case executeToolSkill(name: String, input: String)
    case showSkillOverview
    case showAgentCreationGuidance(kind: AgentCreationRequestKind)
    case executeLocalToolSkill(name: String, input: String)
    case executeExplicitSkill(skill: AISkill, input: String)
    case handleDetectedSkill(skill: AISkill, input: String, executionInput: String)
    case handleAgentSuggestion(AgentSuggestion, input: String)
    case executeNativeSkill(skillID: String, parameters: [String: String], title: String)
    case executeNativeServiceLifecycle(serviceID: String, action: AgentTaskSession.ServiceAction, title: String)
    case executeSubtaskPlan(plan: SubtaskPlan, originalInput: String)
    case routeMainConversation(input: String)
    
    // MARK: - 异常处理场景（新增）
    /// 处理流中断异常
    case handleStreamInterrupted(sessionID: String, originalRequest: String, partialResult: String?)
    /// 查询任务状态
    case checkTaskStatus(sessionID: String)
    /// 后台自动恢复
    case autoRecoverTask(sessionID: String, delaySeconds: Int)
    
    // MARK: - Workflow 编排场景（新增）
    /// 请求 workflow 澄清（缺槽位时）
    case requestWorkflowClarification(candidate: WorkflowCandidate, missingSlots: [PlanningSlot])
    /// 创建 workflow draft（槽位齐全时）
    case createWorkflowDraft(candidate: WorkflowCandidate, originalInput: String)
    /// 启动 workflow run
    case startWorkflowRun(definitionID: String, initialContext: [String: String])
    /// 继续 workflow run
    case continueWorkflowRun(runID: String, stepID: String?, userResponse: String)
    /// 反思 workflow run（定时或事件触发）
    case reflectWorkflowRun(runID: String, trigger: ReplanReason.ReplanTrigger)
    /// 提醒用户关于 workflow
    case remindUserAboutWorkflow(runID: String, reason: String, priority: Priority)
    
    /// 直接调用 MCP 服务（Phase 2: 原生 MCP 调度）
    case executeMCPService(
        serviceID: String,
        operation: String,
        parameters: [String: String]
    )
}

struct RequestPlan {
    let envelope: RequestEnvelope
    let parsedInput: ParsedInput
    let preparedInput: String
    let notices: [String]
    let requestedAgentSwitch: PlannedAgentSwitch?
    let primaryAction: RequestPlannerPrimaryAction
    let confidence: PlannerConfidence
    let reason: String
    let plannerID: String
    
    // MARK: - Workflow 编排扩展（新增）
    let intentKind: IntentKind                    // 意图类型
    let missingSlots: [PlanningSlot]              // 缺失的槽位
    let workflowCandidate: WorkflowCandidate?     // workflow 候选
    let evidence: [PlannerEvidence]               // 决策证据链
    let replanReason: ReplanReason?               // 重规划原因（如果是重规划）

    // MARK: - Planner Dispatch 扩展
    let dispatchAssignments: [ExecutionAssignment]
    let selectedResources: PlannerSelectedResources
    let committeeSignals: [CommitteeSignal]
    
    // MARK: - Committee 扩展（Phase 5）
    let metadata: [String: String]  // 额外元数据（用于 Committee 决策）

    init(
        envelope: RequestEnvelope,
        parsedInput: ParsedInput,
        preparedInput: String,
        notices: [String],
        requestedAgentSwitch: PlannedAgentSwitch?,
        primaryAction: RequestPlannerPrimaryAction,
        confidence: PlannerConfidence,
        reason: String,
        plannerID: String = "unknown",
        intentKind: IntentKind = .chat,
        missingSlots: [PlanningSlot] = [],
        workflowCandidate: WorkflowCandidate? = nil,
        evidence: [PlannerEvidence] = [],
        replanReason: ReplanReason? = nil,
        dispatchAssignments: [ExecutionAssignment] = [],
        selectedResources: PlannerSelectedResources = .init(),
        committeeSignals: [CommitteeSignal] = [],
        metadata: [String: String] = [:]
    ) {
        self.envelope = envelope
        self.parsedInput = parsedInput
        self.preparedInput = preparedInput
        self.notices = notices
        self.requestedAgentSwitch = requestedAgentSwitch
        self.primaryAction = primaryAction
        self.confidence = confidence
        self.reason = reason
        self.plannerID = plannerID
        self.intentKind = intentKind
        self.missingSlots = missingSlots
        self.workflowCandidate = workflowCandidate
        self.evidence = evidence
        self.replanReason = replanReason
        self.dispatchAssignments = dispatchAssignments
        self.selectedResources = selectedResources
        self.committeeSignals = committeeSignals
        self.metadata = metadata
    }

    var shouldAppendUserMessage: Bool {
        switch primaryAction {
        case .continueAgentCreationFlow,
                .respondToSkillEvolution,
                .respondToWorkflowDesignGuidance,
                .respondToDetectedSkillSuggestion,
                .respondToLegacySkillSuggestion:
            return false
        default:
            return true
        }
    }

    var executionMode: RequestExecutionMode {
        switch primaryAction {
        case .respondToWorkflowDesignGuidance(_, _, let accepted):
            return accepted ? .sideSession : .mainSession
        case .startWorkflowDesignSession:
            return .sideSession
        case .continueWorkflowDesignSession:
            return .sideSession
        case .handleDetectedSkill:
            return .sideSession
        default:
            return .mainSession
        }
    }

    var taskSpecs: [PlannedTaskSpec] {
        switch primaryAction {
        case .cancelPendingFlow:
            return [
                PlannedTaskSpec(
                    id: "cancel-pending-flow",
                    kind: .conversationControl,
                    title: "取消挂起流程",
                    executorLabel: "主会话",
                    summary: "主会话主动终止当前挂起的确认/创建流程，恢复普通对话。",
                    returnsToMainConversation: true
                )
            ]
        case .startBrowserSession(_, _):
            return [
                PlannedTaskSpec(
                    id: "browser-session-start",
                    kind: .conversationControl,
                    title: "打开网页并建立浏览器会话",
                    executorLabel: "Browser Agent",
                    summary: "启动可见浏览器、抓取页面摘要并回到主会话确认下一步。",
                    returnsToMainConversation: true
                )
            ]
        case .continueBrowserSession(let sessionID, _):
            return [
                PlannedTaskSpec(
                    id: "browser-session-continue-\(sessionID)",
                    kind: .conversationControl,
                    title: "继续当前网页会话",
                    executorLabel: "Browser Agent",
                    summary: "沿用当前浏览器上下文继续网页识别、确认和操作。",
                    returnsToMainConversation: true
                )
            ]
        case .continueAgentCreationFlow:
            return [
                PlannedTaskSpec(
                    id: "agent-creation-flow",
                    kind: .setupFlow,
                    title: "继续 Agent 创建流程",
                    executorLabel: "Agent 创建向导",
                    summary: "沿用当前创建上下文继续收集信息。",
                    returnsToMainConversation: true
                )
            ]
        case .resumeInterruptedTask(let sessionID):
            return [
                PlannedTaskSpec(
                    id: "resume-\(sessionID)",
                    kind: .recovery,
                    title: "恢复中断任务",
                    executorLabel: "恢复引擎",
                    summary: "回查并继续最近的中断任务会话。",
                    returnsToMainConversation: true
                )
            ]
        case .respondToSkillEvolution(let proposalID, _):
            return [
                PlannedTaskSpec(
                    id: "skill-evolution-\(proposalID)",
                    kind: .conversationControl,
                    title: "处理 Skill 迭代确认",
                    executorLabel: "Skill 迭代顾问",
                    summary: "应用或忽略当前 Skill 优化提案。",
                    returnsToMainConversation: true
                )
            ]
        case .startWorkflowDesignSession:
            return [
                PlannedTaskSpec(
                    id: "workflow-design-start",
                    kind: .agentSuggestion,
                    title: "启动业务工作流设计",
                    executorLabel: "工作流设计子任务",
                    summary: "立即拆出独立工作流设计任务，避免先停在纯说明文案。",
                    returnsToMainConversation: true
                )
            ]
        case .continueWorkflowDesignSession(let sessionID, _, _):
            return [
                PlannedTaskSpec(
                    id: "workflow-design-continue-\(sessionID)",
                    kind: .agentSuggestion,
                    title: "继续业务工作流设计",
                    executorLabel: "工作流设计子任务",
                    summary: "把新的补充信息续写到现有工作流设计 session，不再回落到主会话自由发挥。",
                    returnsToMainConversation: true
                )
            ]
        case .respondToWorkflowDesignGuidance(_, _, let accepted):
            return [
                PlannedTaskSpec(
                    id: "workflow-design-guidance",
                    kind: accepted ? .agentSuggestion : .conversationControl,
                    title: accepted ? "继续业务工作流设计" : "结束业务工作流设计引导",
                    executorLabel: accepted ? "工作流设计子任务" : "Agent 创建顾问",
                    summary: accepted
                        ? "拆出独立工作流设计子任务，避免旧主会话上下文串题。"
                        : "结束这次业务工作流设计引导，回到普通对话。",
                    returnsToMainConversation: true
                )
            ]
        case .respondToDetectedSkillSuggestion(let messageID, _):
            return [
                PlannedTaskSpec(
                    id: "detected-skill-\(messageID.uuidString)",
                    kind: .conversationControl,
                    title: "处理 Skill 建议卡片",
                    executorLabel: "秘书层",
                    summary: "按用户选择决定是否拆出独立处理任务。",
                    returnsToMainConversation: true
                )
            ]
        case .respondToLegacySkillSuggestion(let skill, _, _):
            return [
                PlannedTaskSpec(
                    id: "legacy-skill-\(skill.rawValue)",
                    kind: .conversationControl,
                    title: "处理旧版 Skill 建议",
                    executorLabel: skill.name,
                    summary: "按确认结果决定是否转成独立处理。",
                    returnsToMainConversation: true
                )
            ]
        case .requestInitialSetup:
            return [
                PlannedTaskSpec(
                    id: "initial-setup",
                    kind: .setupFlow,
                    title: "初始化配置",
                    executorLabel: "配置向导",
                    summary: "引导用户先配出至少一个可用 Agent。",
                    returnsToMainConversation: true
                )
            ]
        case .showSkillEvolutionOverview:
            return [
                PlannedTaskSpec(
                    id: "skill-evolution-overview",
                    kind: .conversationControl,
                    title: "展示 Skill 迭代概览",
                    executorLabel: "Skill 迭代顾问",
                    summary: "输出当前可优化 Skill 的摘要。",
                    returnsToMainConversation: true
                )
            ]
        case .showPlannerConsole:
            return [
                PlannedTaskSpec(
                    id: "planner-console",
                    kind: .conversationControl,
                    title: "展示 Planner Console",
                    executorLabel: "秘书层",
                    summary: "返回当前意图分析/调度模块的真实状态，并打开控制台。",
                    returnsToMainConversation: true
                )
            ]
        case .executeToolSkill(let name, _):
            return [
                PlannedTaskSpec(
                    id: "tool-skill-\(name)",
                    kind: .toolSkill,
                    title: "执行工具命令 /\(name)",
                    executorLabel: "/\(name)",
                    summary: "直接执行显式工具命令。",
                    returnsToMainConversation: true
                )
            ]
        case .showSkillOverview:
            return [
                PlannedTaskSpec(
                    id: "skill-overview",
                    kind: .conversationControl,
                    title: "展示 Skills 概览",
                    executorLabel: "秘书层",
                    summary: "打开 Skills 面板并汇总当前能力。",
                    returnsToMainConversation: true
                )
            ]
        case .showAgentCreationGuidance(let kind):
            let title = kind == .runtimeSetup ? "模型 Agent 创建引导" : "工作流 Agent 设计引导"
            return [
                PlannedTaskSpec(
                    id: "agent-creation-guidance-\(kind)",
                    kind: .setupFlow,
                    title: title,
                    executorLabel: "Agent 创建向导",
                    summary: "先澄清这是模型接入还是业务工作流设计。",
                    returnsToMainConversation: true
                )
            ]
        case .executeLocalToolSkill(let name, _):
            return [
                PlannedTaskSpec(
                    id: "local-tool-\(name)",
                    kind: .localSystemAction,
                    title: "执行本地系统动作",
                    executorLabel: name,
                    summary: "走本机可验证执行链，不通过远端 Agent 幻觉执行。",
                    returnsToMainConversation: true
                )
            ]
        case .executeExplicitSkill(let skill, _):
            return [
                PlannedTaskSpec(
                    id: "explicit-skill-\(skill.rawValue)",
                    kind: .explicitSkill,
                    title: "执行显式 Skill",
                    executorLabel: skill.name,
                    summary: "按用户显式指定直接执行对应 Skill。",
                    returnsToMainConversation: true
                )
            ]
        case .handleDetectedSkill(let skill, _, _):
            return [
                PlannedTaskSpec(
                    id: "detected-skill-side-task-\(skill.rawValue)",
                    kind: .detectedSkill,
                    title: "\(skill.name) 独立处理",
                    executorLabel: skill.name,
                    summary: "从主会话拆出 side task，独立执行并把结果留在任务卡片。",
                    returnsToMainConversation: false
                )
            ]
        case .handleAgentSuggestion(let suggestion, _):
            return [
                PlannedTaskSpec(
                    id: "agent-suggestion",
                    kind: .agentSuggestion,
                    title: "处理 Agent 建议",
                    executorLabel: suggestion.suggestedAgent?.displayName ?? "秘书层",
                    summary: "决定是否切换或补齐能力后再继续处理。",
                    returnsToMainConversation: true
                )
            ]
        case .executeNativeSkill(let skillID, let parameters, let title):
            let endpoint = parameters["endpoint"] ?? "default"
            return [
                PlannedTaskSpec(
                    id: "native-skill-\(skillID)",
                    kind: .localSystemAction,
                    title: title,
                    executorLabel: "Native Skill Runtime",
                    summary: "直接通过原生执行链调用 \(skillID)（endpoint: \(endpoint)），不再回落到主会话网关。",
                    returnsToMainConversation: true
                )
            ]
        case .executeNativeServiceLifecycle(let serviceID, let action, let title):
            return [
                PlannedTaskSpec(
                    id: "native-service-lifecycle-\(serviceID)-\(action.rawValue)",
                    kind: .localSystemAction,
                    title: title,
                    executorLabel: "Native Service Runtime",
                    summary: "直接通过原生服务执行链处理 \(serviceID) 的 \(action.rawValue) 操作。",
                    returnsToMainConversation: true
                )
            ]
        case .executeSubtaskPlan(let plan, _):
            return [
                PlannedTaskSpec(
                    id: "subtask-plan-\(plan.parentTaskID)",
                    kind: .background,
                    title: "拆解并执行子任务",
                    executorLabel: "Subtask Planner",
                    summary: "把复杂请求拆成 \(plan.blueprints.count) 个子任务，并交给任务中心执行。",
                    returnsToMainConversation: true
                )
            ]
        case .routeMainConversation:
            return [
                PlannedTaskSpec(
                    id: "main-conversation",
                    kind: .mainConversation,
                    title: "继续主会话处理",
                    executorLabel: envelope.currentAgent?.displayName ?? "自动路由",
                    summary: "交给当前 Agent / 路由器进入主对话执行链。",
                    returnsToMainConversation: true
                )
            ]
        case .handleStreamInterrupted(let sessionID, _, _):
            return [
                PlannedTaskSpec(
                    id: "stream-interrupted-\(sessionID)",
                    kind: .recovery,
                    title: "处理流中断",
                    executorLabel: "异常恢复",
                    summary: "处理流式响应中断，触发自动恢复机制。",
                    returnsToMainConversation: true
                )
            ]
        case .checkTaskStatus(let sessionID):
            return [
                PlannedTaskSpec(
                    id: "check-status-\(sessionID)",
                    kind: .mainConversation,
                    title: "检查任务状态",
                    executorLabel: "状态检查",
                    summary: "查询指定任务会话的当前状态。",
                    returnsToMainConversation: true
                )
            ]
        case .autoRecoverTask(let sessionID, let delay):
            return [
                PlannedTaskSpec(
                    id: "auto-recover-\(sessionID)",
                    kind: .recovery,
                    title: "自动恢复任务",
                    executorLabel: "后台恢复",
                    summary: "安排在\(delay)秒后自动尝试恢复任务。",
                    returnsToMainConversation: true
                )
            ]
            
        // MARK: - Workflow 编排场景
        case .requestWorkflowClarification(let candidate, let slots):
            return [
                PlannedTaskSpec(
                    id: "workflow-clarify-\(candidate.name)",
                    kind: .conversationControl,
                    title: "澄清 Workflow 信息",
                    executorLabel: "Workflow Planner",
                    summary: "需要补充 \(slots.filter { !$0.isFilled }.count) 个信息槽位才能创建 workflow。",
                    returnsToMainConversation: true
                )
            ]
        case .createWorkflowDraft(let candidate, _):
            return [
                PlannedTaskSpec(
                    id: "workflow-draft-\(candidate.name)",
                    kind: .agentSuggestion,
                    title: "创建 Workflow Draft",
                    executorLabel: "Workflow Planner",
                    summary: "基于用户输入创建 \(candidate.name) workflow 草稿，等待用户确认。",
                    returnsToMainConversation: true
                )
            ]
        case .startWorkflowRun(let definitionID, _):
            return [
                PlannedTaskSpec(
                    id: "workflow-start-\(definitionID)",
                    kind: .background,
                    title: "启动 Workflow",
                    executorLabel: "Workflow Runner",
                    summary: "启动 workflow 实例并执行第一步。",
                    returnsToMainConversation: true
                )
            ]
        case .continueWorkflowRun(let runID, let stepID, _):
            return [
                PlannedTaskSpec(
                    id: "workflow-continue-\(runID)",
                    kind: .background,
                    title: "继续 Workflow",
                    executorLabel: "Workflow Runner",
                    summary: "继续执行 workflow \(stepID != nil ? "步骤 \(stepID!)" : "下一步")。",
                    returnsToMainConversation: true
                )
            ]
        case .reflectWorkflowRun(let runID, let trigger):
            return [
                PlannedTaskSpec(
                    id: "workflow-reflect-\(runID)",
                    kind: .background,
                    title: "反思 Workflow",
                    executorLabel: "Reflection Planner",
                    summary: "因 \(trigger.rawValue) 触发 workflow 反思。",
                    returnsToMainConversation: false
                )
            ]
        case .remindUserAboutWorkflow(let runID, let reason, let priority):
            return [
                PlannedTaskSpec(
                    id: "workflow-remind-\(runID)",
                    kind: priority == .critical ? .conversationControl : .background,
                    title: "Workflow 提醒",
                    executorLabel: "Reflection Planner",
                    summary: reason,
                    returnsToMainConversation: priority == .critical
                )
            ]
            
        // Phase 2: MCP 原生调度
        case .executeMCPService(let serviceID, let operation, _):
            return [
                PlannedTaskSpec(
                    id: "mcp-service-\(serviceID)-\(operation)",
                    kind: .localSystemAction,
                    title: "执行 MCP 服务",
                    executorLabel: serviceID,
                    summary: "直接调用 MCP 服务 \(serviceID)，执行 \(operation) 操作。",
                    returnsToMainConversation: true
                )
            ]
        }
    }

    var taskSummary: String {
        guard !taskSpecs.isEmpty else {
            return "none"
        }
        return taskSpecs.map { "\($0.kind.rawValue):\($0.executorLabel)" }.joined(separator: ",")
    }

    var effectiveDispatchAssignments: [ExecutionAssignment] {
        if !dispatchAssignments.isEmpty {
            return dispatchAssignments
        }
        return taskSpecs.map(ExecutionAssignment.init(taskSpec:))
    }

    var confidenceScore: Double {
        if let signalScore = committeeSignals.map(\.confidenceScore).max() {
            return signalScore
        }

        switch confidence {
        case .high:
            return 0.85
        case .medium:
            return 0.62
        case .low:
            return 0.35
        }
    }

    var riskScore: Double {
        if let signalScore = committeeSignals.map(\.riskScore).max() {
            return signalScore
        }

        var score = 0.15

        switch intentKind {
        case .chat:
            score += 0.0
        case .singleTask:
            score += 0.1
        case .workflow:
            score += 0.25
        case .service:
            score += 0.2
        case .clarificationNeeded:
            score += 0.05
        }

        let text = envelope.originalText.lowercased()
        let higherRiskKeywords = [
            "delete", "remove", "restart", "stop", "send", "reply",
            "删除", "移除", "重启", "停止", "发送", "回复", "代聊", "托管", "监控"
        ]
        if higherRiskKeywords.contains(where: { text.contains($0) }) {
            score += 0.2
        }

        if effectiveDispatchAssignments.contains(where: { $0.kind == .browser || $0.kind == .service }) {
            score += 0.15
        }
        if effectiveDispatchAssignments.contains(where: { $0.kind == .workflow }) {
            score += 0.15
        }
        if replanReason != nil {
            score += 0.1
        }

        return min(score, 1.0)
    }

    var summary: String {
        switch primaryAction {
        case .cancelPendingFlow:
            return "cancel_pending_flow"
        case .startBrowserSession(let url, _):
            return "start_browser_session:\(url)"
        case .continueBrowserSession(let sessionID, _):
            return "continue_browser_session:\(sessionID)"
        case .continueAgentCreationFlow:
            return "continue_agent_creation_flow"
        case .resumeInterruptedTask(let sessionID):
            return "resume_interrupted_task:\(sessionID)"
        case .respondToSkillEvolution(let proposalID, let accepted):
            return "respond_skill_evolution:\(proposalID):\(accepted)"
        case .startWorkflowDesignSession:
            return "start_workflow_design_session"
        case .continueWorkflowDesignSession(let sessionID, _, _):
            return "continue_workflow_design_session:\(sessionID)"
        case .respondToWorkflowDesignGuidance(_, _, let accepted):
            return "respond_workflow_design_guidance:\(accepted)"
        case .respondToDetectedSkillSuggestion(let messageID, let action):
            return "respond_detected_skill:\(messageID.uuidString):\(String(describing: action))"
        case .respondToLegacySkillSuggestion(let skill, _, let accepted):
            return "respond_legacy_skill:\(skill.rawValue):\(accepted)"
        case .requestInitialSetup:
            return "request_initial_setup"
        case .showSkillEvolutionOverview:
            return "show_skill_evolution_overview"
        case .showPlannerConsole:
            return "show_planner_console"
        case .executeToolSkill(let name, _):
            return "execute_tool_skill:\(name)"
        case .showSkillOverview:
            return "show_skill_overview"
        case .showAgentCreationGuidance(let kind):
            switch kind {
            case .runtimeSetup:
                return "show_agent_creation_guidance:runtime_setup"
            case .workflowDesign:
                return "show_agent_creation_guidance:workflow_design"
            }
        case .executeLocalToolSkill(let name, _):
            return "execute_local_tool_skill:\(name)"
        case .executeExplicitSkill(let skill, _):
            return "execute_explicit_skill:\(skill.rawValue)"
        case .handleDetectedSkill(let skill, _, _):
            return "handle_detected_skill:\(skill.rawValue)"
        case .handleAgentSuggestion(_, _):
            return "handle_agent_suggestion"
        case .executeNativeSkill(let skillID, let parameters, _):
            let operation = parameters["operation"] ?? "invoke"
            return "execute_native_skill:\(skillID):\(operation)"
        case .executeNativeServiceLifecycle(let serviceID, let action, _):
            return "execute_native_service_lifecycle:\(serviceID):\(action.rawValue)"
        case .executeSubtaskPlan(let plan, _):
            return "execute_subtask_plan:\(plan.parentTaskID):\(plan.blueprints.count)"
        case .routeMainConversation:
            return "route_main_conversation"
        case .handleStreamInterrupted(let sessionID, _, _):
            return "handle_stream_interrupted:\(sessionID)"
        case .checkTaskStatus(let sessionID):
            return "check_task_status:\(sessionID)"
        case .autoRecoverTask(let sessionID, let delay):
            return "auto_recover_task:\(sessionID):\(delay)"
            
        // MARK: - Workflow 编排场景
        case .requestWorkflowClarification(let candidate, _):
            return "request_workflow_clarification:\(candidate.name)"
        case .createWorkflowDraft(let candidate, _):
            return "create_workflow_draft:\(candidate.name)"
        case .startWorkflowRun(let definitionID, _):
            return "start_workflow_run:\(definitionID)"
        case .continueWorkflowRun(let runID, let stepID, _):
            return "continue_workflow_run:\(runID):\(stepID ?? "next")"
        case .reflectWorkflowRun(let runID, let trigger):
            return "reflect_workflow_run:\(runID):\(trigger.rawValue)"
        case .remindUserAboutWorkflow(let runID, _, let priority):
            return "remind_workflow:\(runID):\(priority.rawValue)"
            
        // Phase 2: MCP 原生调度
        case .executeMCPService(let serviceID, let operation, _):
            return "execute_mcp_service:\(serviceID):\(operation)"
        }
    }

    var comparisonSignature: String {
        let switchID = requestedAgentSwitch?.agent.id ?? "none"
        let normalizedPreparedInput = preparedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = intentKind.rawValue
        let workflow = workflowCandidate?.name ?? "none"
        let assignments = effectiveDispatchAssignments.map { "\($0.kind.rawValue):\($0.executorLabel)" }.joined(separator: ",")
        return "\(summary)|mode=\(executionMode.rawValue)|tasks=\(taskSummary)|assignments=\(assignments)|switch=\(switchID)|append=\(shouldAppendUserMessage)|prepared=\(normalizedPreparedInput)|intent=\(intent)|workflow=\(workflow)"
    }
}

extension RequestPlan {
    func withPlannerID(_ plannerID: String) -> RequestPlan {
        RequestPlan(
            envelope: envelope,
            parsedInput: parsedInput,
            preparedInput: preparedInput,
            notices: notices,
            requestedAgentSwitch: requestedAgentSwitch,
            primaryAction: primaryAction,
            confidence: confidence,
            reason: reason,
            plannerID: plannerID,
            intentKind: intentKind,
            missingSlots: missingSlots,
            workflowCandidate: workflowCandidate,
            evidence: evidence,
            replanReason: replanReason,
            dispatchAssignments: dispatchAssignments,
            selectedResources: selectedResources,
            committeeSignals: committeeSignals,
            metadata: metadata
        )
    }
}
