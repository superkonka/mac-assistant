//
//  RequestPlanningModels.swift
//  MacAssistant
//

import Foundation

enum AgentCreationRequestKind {
    case runtimeSetup
    case workflowDesign
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
}

struct PlannedTaskSpec: Identifiable, Hashable {
    let id: String
    let kind: PlannedTaskKind
    let title: String
    let executorLabel: String
    let summary: String
    let returnsToMainConversation: Bool
}

struct RequestEnvelope {
    let id: UUID
    let originalText: String
    let images: [String]
    let createdAt: Date
    let currentAgent: Agent?
    let needsInitialSetup: Bool
    let lastMessage: ChatMessage?
    let creationFlowActive: Bool
    let resumableTaskSessionID: String?

    init(
        id: UUID = UUID(),
        originalText: String,
        images: [String],
        createdAt: Date = Date(),
        currentAgent: Agent?,
        needsInitialSetup: Bool,
        lastMessage: ChatMessage?,
        creationFlowActive: Bool,
        resumableTaskSessionID: String?
    ) {
        self.id = id
        self.originalText = originalText
        self.images = images
        self.createdAt = createdAt
        self.currentAgent = currentAgent
        self.needsInitialSetup = needsInitialSetup
        self.lastMessage = lastMessage
        self.creationFlowActive = creationFlowActive
        self.resumableTaskSessionID = resumableTaskSessionID
    }
}

struct PlannedAgentSwitch {
    let agent: Agent
    let reason: String
    let requiredCapability: Capability?
}

enum RequestPlannerPrimaryAction {
    case continueAgentCreationFlow(input: String)
    case resumeInterruptedTask(sessionID: String)
    case respondToSkillEvolution(proposalID: String, accepted: Bool)
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
    case routeParallelLinkResearch(input: String)
    case routeMainConversation(input: String)
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

    init(
        envelope: RequestEnvelope,
        parsedInput: ParsedInput,
        preparedInput: String,
        notices: [String],
        requestedAgentSwitch: PlannedAgentSwitch?,
        primaryAction: RequestPlannerPrimaryAction,
        confidence: PlannerConfidence,
        reason: String,
        plannerID: String = "unknown"
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
    }

    var shouldAppendUserMessage: Bool {
        switch primaryAction {
        case .continueAgentCreationFlow,
                .resumeInterruptedTask,
                .respondToSkillEvolution,
                .respondToDetectedSkillSuggestion,
                .respondToLegacySkillSuggestion:
            return false
        default:
            return true
        }
    }

    var executionMode: RequestExecutionMode {
        switch primaryAction {
        case .handleDetectedSkill:
            return .sideSession
        case .routeParallelLinkResearch:
            return .parallelSubtasks
        default:
            return .mainSession
        }
    }

    var taskSpecs: [PlannedTaskSpec] {
        switch primaryAction {
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
        case .routeParallelLinkResearch:
            return [
                PlannedTaskSpec(
                    id: "parallel-link-main",
                    kind: .mainConversation,
                    title: "主会话回答",
                    executorLabel: envelope.currentAgent?.displayName ?? "自动路由",
                    summary: "主会话先继续回答，不阻塞当前对话。",
                    returnsToMainConversation: true
                ),
                PlannedTaskSpec(
                    id: "parallel-link-research",
                    kind: .recovery,
                    title: "链接抓取子任务",
                    executorLabel: "WebContextAgent",
                    summary: "并行抓取链接内容并提炼补充上下文。",
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
        }
    }

    var taskSummary: String {
        guard !taskSpecs.isEmpty else {
            return "none"
        }
        return taskSpecs.map { "\($0.kind.rawValue):\($0.executorLabel)" }.joined(separator: ",")
    }

    var summary: String {
        switch primaryAction {
        case .continueAgentCreationFlow:
            return "continue_agent_creation_flow"
        case .resumeInterruptedTask(let sessionID):
            return "resume_interrupted_task:\(sessionID)"
        case .respondToSkillEvolution(let proposalID, let accepted):
            return "respond_skill_evolution:\(proposalID):\(accepted)"
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
        case .routeParallelLinkResearch:
            return "route_parallel_link_research"
        case .routeMainConversation:
            return "route_main_conversation"
        }
    }

    var comparisonSignature: String {
        let switchID = requestedAgentSwitch?.agent.id ?? "none"
        let normalizedPreparedInput = preparedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(summary)|mode=\(executionMode.rawValue)|tasks=\(taskSummary)|switch=\(switchID)|append=\(shouldAppendUserMessage)|prepared=\(normalizedPreparedInput)"
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
            plannerID: plannerID
        )
    }
}
