//
//  RequestPlanner.swift
//  MacAssistant
//

import Foundation

protocol RequestPlannerProvider {
    var providerID: String { get }
    func plan(_ envelope: RequestEnvelope) async -> RequestPlan
}

protocol RequestPlannerShadowProvider {
    var providerID: String { get }
    func planShadow(_ envelope: RequestEnvelope) async -> RequestPlan?
}

final class RequestPlanner {
    static let shared = RequestPlanner()

    private let ruleProvider: RequestPlannerProvider
    private let intentAgentProvider: IntentAgentShadowPlannerProvider
    private let preferences = UserPreferenceStore.shared

    init(
        primaryProvider: RequestPlannerProvider = RuleBasedRequestPlannerProvider.shared,
        shadowProvider: IntentAgentShadowPlannerProvider = IntentAgentShadowPlannerProvider.shared
    ) {
        self.ruleProvider = primaryProvider
        self.intentAgentProvider = shadowProvider
    }

    func plan(_ envelope: RequestEnvelope) async -> RequestPlan {
        if let preflightPlan = RuleBasedRequestPlannerProvider.shared.priorityLocalPlan(envelope) {
            return preflightPlan.withPlannerID(ruleProvider.providerID)
        }

        switch preferences.plannerPrimaryStrategy {
        case .ruleBased:
            async let primary = ruleProvider.plan(envelope)
            async let shadow = intentAgentProvider.planShadow(envelope)

            let primaryPlan = await primary.withPlannerID(ruleProvider.providerID)

            if let shadowPlan = await shadow?.withPlannerID(intentAgentProvider.providerID) {
                logShadowComparison(primary: primaryPlan, shadow: shadowPlan)
            }

            return primaryPlan

        case .agentPrimary:
            async let fallbackRule = ruleProvider.plan(envelope)
            async let primaryCandidate = intentAgentProvider.planPrimary(envelope)

            let fallbackPlan = await fallbackRule.withPlannerID(ruleProvider.providerID)

            if let primaryPlan = await primaryCandidate?.withPlannerID(intentAgentProvider.primaryProviderID) {
                if preferences.plannerShadowEnabled {
                    logShadowComparison(primary: primaryPlan, shadow: fallbackPlan.withPlannerID("rule-based-shadow"))
                }
                return primaryPlan
            }

            LogInfo("RequestPlanner primary agent fallback -> rule-based")
            return fallbackPlan
        }
    }

    private func logShadowComparison(primary: RequestPlan, shadow: RequestPlan) {
        Task { @MainActor [primary, shadow] in
            PlannerShadowMonitor.shared.record(primary: primary, shadow: shadow)
        }

        guard primary.comparisonSignature != shadow.comparisonSignature else {
            LogDebug(
                "RequestPlanner shadow match primary=\(primary.plannerID) shadow=\(shadow.plannerID) " +
                "decision=\(primary.summary)"
            )
            return
        }

        LogInfo(
            "RequestPlanner shadow diff primary=\(primary.plannerID):\(primary.summary) " +
            "shadow=\(shadow.plannerID):\(shadow.summary) " +
            "primaryReason=\(primary.reason) shadowReason=\(shadow.reason)"
        )
    }
}

final class RuleBasedRequestPlannerProvider: RequestPlannerProvider {
    static let shared = RuleBasedRequestPlannerProvider()

    let providerID = "rule-based-v1"

    private let intelligence = ConversationIntelligence.shared
    private let toolSkillRegistry = SkillRegistry.shared
    private let orchestrator = AgentOrchestrator.shared
    private let agentStore = AgentStore.shared

    private init() {}

    func priorityLocalPlan(_ envelope: RequestEnvelope) -> RequestPlan? {
        let normalized = RequestPlanningHeuristics.normalized(envelope.originalText)
        let parsed = intelligence.analyzeInput(envelope.originalText)

        if envelope.creationFlowActive {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .continueAgentCreationFlow(input: envelope.originalText),
                confidence: .high,
                reason: "当前正在 Agent 创建流程中，优先把输入交给创建向导。"
            )
        }

        if let sessionID = envelope.resumableTaskSessionID,
           RequestPlanningHeuristics.shouldTreatAsResumeCommand(normalized) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .resumeInterruptedTask(sessionID: sessionID),
                confidence: .high,
                reason: "识别到继续/恢复命令，优先恢复最近的可续跑任务。"
            )
        }

        if let lastMessage = envelope.lastMessage,
           let pendingProposalID = lastMessage.metadata?["pending_skill_evolution_id"],
           let accepted = RequestPlanningHeuristics.acceptanceDecision(from: normalized) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .respondToSkillEvolution(proposalID: pendingProposalID, accepted: accepted),
                confidence: .high,
                reason: "当前输入是在响应 Skill 迭代提案确认。"
            )
        }

        if let lastMessage = envelope.lastMessage,
           lastMessage.metadata?["pending_workflow_design"] == "true",
           let originalInput = lastMessage.metadata?["workflow_original_input"],
           let accepted = RequestPlanningHeuristics.workflowGuidanceDecision(from: envelope.originalText) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .respondToWorkflowDesignGuidance(
                    originalInput: originalInput,
                    followUpInput: envelope.originalText,
                    accepted: accepted
                ),
                confidence: .high,
                reason: "当前输入是在响应业务工作流设计引导，优先继续本地工作流设计链。"
            )
        }

        if let workflowContext = envelope.activeWorkflowDesignContext,
           RequestPlanningHeuristics.shouldContinueWorkflowDesign(
            with: envelope.originalText,
            context: workflowContext
           ) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .continueWorkflowDesignSession(
                    sessionID: workflowContext.sessionID,
                    originalInput: workflowContext.originalInput,
                    followUpInput: envelope.originalText
                ),
                confidence: .medium,
                reason: "检测到当前仍在补充同一条业务工作流设计，继续复用现有工作流 session。"
            )
        }

        if let lastMessage = envelope.lastMessage,
           let pendingSuggestion = lastMessage.detectedSkillSuggestion,
           let accepted = RequestPlanningHeuristics.acceptanceDecision(from: normalized) {
            let action: DetectedSkillSuggestionAction = accepted ? .runOnce : .dismissOnce
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .respondToDetectedSkillSuggestion(
                    messageID: pendingSuggestion.messageID,
                    action: action
                ),
                confidence: .high,
                reason: "当前输入是在响应检测到的 Skill 建议卡片。"
            )
        }

        if let lastMessage = envelope.lastMessage,
           let pendingSkill = lastMessage.metadata?["pending_skill"],
           let skillInput = lastMessage.metadata?["skill_input"],
           let skill = AISkill(rawValue: pendingSkill),
           let accepted = RequestPlanningHeuristics.acceptanceDecision(from: normalized) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .respondToLegacySkillSuggestion(
                    skill: skill,
                    input: skillInput,
                    accepted: accepted
                ),
                confidence: .high,
                reason: "当前输入是在响应旧版 Skill 建议确认消息。"
            )
        }

        return nil
    }

    func plan(_ envelope: RequestEnvelope) async -> RequestPlan {
        if let priorityPlan = priorityLocalPlan(envelope) {
            return priorityPlan
        }

        let normalized = RequestPlanningHeuristics.normalized(envelope.originalText)
        let parsed = intelligence.analyzeInput(envelope.originalText)
        let hasLinkRequest = WebContextAgent.shared.hasLinkRequest(for: envelope.originalText, images: envelope.images)
        let respectCurrentAgentSelection = RequestPlanningHeuristics.shouldRespectCurrentAgentSelection(
            for: envelope.originalText,
            images: envelope.images,
            currentAgent: envelope.currentAgent
        )

        if envelope.creationFlowActive {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .continueAgentCreationFlow(input: envelope.originalText),
                confidence: .high,
                reason: "当前正在 Agent 创建流程中，优先把输入交给创建向导。"
            )
        }

        if let sessionID = envelope.resumableTaskSessionID,
           RequestPlanningHeuristics.shouldTreatAsResumeCommand(normalized) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .resumeInterruptedTask(sessionID: sessionID),
                confidence: .high,
                reason: "识别到继续/恢复命令，优先恢复最近的可续跑任务。"
            )
        }

        if let lastMessage = envelope.lastMessage,
           let pendingProposalID = lastMessage.metadata?["pending_skill_evolution_id"],
           let accepted = RequestPlanningHeuristics.acceptanceDecision(from: normalized) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .respondToSkillEvolution(proposalID: pendingProposalID, accepted: accepted),
                confidence: .high,
                reason: "当前输入是在响应 Skill 迭代提案确认。"
            )
        }

        if let lastMessage = envelope.lastMessage,
           lastMessage.metadata?["pending_workflow_design"] == "true",
           let originalInput = lastMessage.metadata?["workflow_original_input"],
           let accepted = RequestPlanningHeuristics.workflowGuidanceDecision(from: envelope.originalText) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .respondToWorkflowDesignGuidance(
                    originalInput: originalInput,
                    followUpInput: envelope.originalText,
                    accepted: accepted
                ),
                confidence: .high,
                reason: "当前输入是在响应业务工作流设计引导，优先继续本地工作流设计链。"
            )
        }

        if let lastMessage = envelope.lastMessage,
           let pendingSuggestion = lastMessage.detectedSkillSuggestion,
           let accepted = RequestPlanningHeuristics.acceptanceDecision(from: normalized) {
            let action: DetectedSkillSuggestionAction = accepted ? .runOnce : .dismissOnce
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .respondToDetectedSkillSuggestion(
                    messageID: pendingSuggestion.messageID,
                    action: action
                ),
                confidence: .high,
                reason: "当前输入是在响应检测到的 Skill 建议卡片。"
            )
        }

        if let lastMessage = envelope.lastMessage,
           let pendingSkill = lastMessage.metadata?["pending_skill"],
           let skillInput = lastMessage.metadata?["skill_input"],
           let skill = AISkill(rawValue: pendingSkill),
           let accepted = RequestPlanningHeuristics.acceptanceDecision(from: normalized) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .respondToLegacySkillSuggestion(
                    skill: skill,
                    input: skillInput,
                    accepted: accepted
                ),
                confidence: .high,
                reason: "当前输入是在响应旧版 Skill 建议确认消息。"
            )
        }

        if envelope.needsInitialSetup {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .requestInitialSetup,
                confidence: .high,
                reason: "当前没有可用 Agent，先进入初始化配置流程。"
            )
        }

        if RequestPlanningHeuristics.shouldShowSkillEvolutionOverview(for: normalized) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .showSkillEvolutionOverview,
                confidence: .medium,
                reason: "用户在询问当前有哪些 Skill 需要优化或迭代。"
            )
        }

        if RequestPlanningHeuristics.shouldShowPlannerConsole(for: normalized) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .showPlannerConsole,
                confidence: .high,
                reason: "用户在询问当前意图分析、调度链路或 Planner 状态。"
            )
        }

        if let toolSkillCommand = RequestPlanningHeuristics.detectToolSkillCommand(
            in: envelope.originalText,
            toolSkillRegistry: toolSkillRegistry
        ) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .executeToolSkill(name: toolSkillCommand.name, input: toolSkillCommand.input),
                confidence: .high,
                reason: "检测到显式工具命令，直接执行本地 tool skill。"
            )
        }

        if RequestPlanningHeuristics.shouldRespondWithProjectSkillOverview(
            to: envelope.originalText,
            images: envelope.images
        ) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .showSkillOverview,
                confidence: .high,
                reason: "用户在查询可用 skills/能力概览。"
            )
        }

        if let kind = RequestPlanningHeuristics.classifyAgentCreationRequest(envelope.originalText) {
            let primaryAction: RequestPlannerPrimaryAction
            switch kind {
            case .workflowDesign:
                primaryAction = .startWorkflowDesignSession(input: envelope.originalText)
            case .runtimeSetup:
                primaryAction = .showAgentCreationGuidance(kind: kind)
            }
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: primaryAction,
                confidence: .medium,
                reason: "用户请求创建 Agent，需要先区分模型接入与业务工作流。"
            )
        }

        let prepared = await prepareInput(from: parsed.cleanText, images: envelope.images)
        let requestedAgentSwitch = RequestPlanningHeuristics.plannedAgentSwitch(for: parsed, images: envelope.images)

        if !hasLinkRequest,
           let nativeMacSkillName = await MacSystemAgent.shared.suggestedSkillName(for: envelope.originalText) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: prepared.text,
                notices: prepared.notices,
                requestedAgentSwitch: requestedAgentSwitch,
                primaryAction: .executeLocalToolSkill(name: nativeMacSkillName, input: envelope.originalText),
                confidence: .medium,
                reason: "识别为本机系统操作请求，优先走本地可验证执行链。"
            )
        }

        if parsed.skillCommand == nil,
           RequestPlanningHeuristics.shouldUseParallelLinkResearch(
            for: envelope.originalText,
            images: envelope.images
        ) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: prepared.text,
                notices: prepared.notices,
                requestedAgentSwitch: requestedAgentSwitch,
                primaryAction: .routeParallelLinkResearch(input: prepared.text),
                confidence: .medium,
                reason: "识别为链接研究类请求，拆成主回答与并行链接抓取子任务。"
            )
        }

        if let skillCommand = parsed.skillCommand {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: prepared.text,
                notices: prepared.notices,
                requestedAgentSwitch: requestedAgentSwitch,
                primaryAction: .executeExplicitSkill(skill: skillCommand.skill, input: parsed.cleanText),
                confidence: .high,
                reason: "检测到显式 /Skill 指令。"
            )
        }

        if !respectCurrentAgentSelection, let detectedSkill = parsed.detectedSkill {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: prepared.text,
                notices: prepared.notices,
                requestedAgentSwitch: requestedAgentSwitch,
                primaryAction: .handleDetectedSkill(
                    skill: detectedSkill,
                    input: parsed.cleanText,
                    executionInput: prepared.text
                ),
                confidence: .medium,
                reason: "自然语言意图更接近内置 Skill，先进入 Skill 建议/独立处理链。"
            )
        }

        if !respectCurrentAgentSelection, let suggestedAgent = parsed.suggestedAgent {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: prepared.text,
                notices: prepared.notices,
                requestedAgentSwitch: requestedAgentSwitch,
                primaryAction: .handleAgentSuggestion(suggestedAgent, input: parsed.cleanText),
                confidence: .medium,
                reason: "当前请求更适合切换或补齐特定能力 Agent。"
            )
        }

        return RequestPlan(
            envelope: envelope,
            parsedInput: parsed,
            preparedInput: prepared.text,
            notices: prepared.notices,
            requestedAgentSwitch: requestedAgentSwitch,
            primaryAction: .routeMainConversation(input: prepared.text),
            confidence: .medium,
            reason: "未命中特殊分支，进入主对话路由链。"
        )
    }

    private func prepareInput(from text: String, images: [String]) async -> (text: String, notices: [String]) {
        let preferClawTools = shouldPreferClawURLHandling(for: text, images: images)
        guard preferClawTools,
              let attachment = await WebContextAgent.shared.attachmentIfNeeded(
                for: text,
                images: images,
                preferClawTools: true
              ) else {
            return (text, [])
        }

        return (attachment.augmentedInput, [attachment.notice])
    }

    private func shouldPreferClawURLHandling(for text: String, images: [String]) -> Bool {
        guard WebContextAgent.shared.hasLinkRequest(for: text, images: images) else {
            return false
        }
        return preferredOpenClawToolAgent(for: images) != nil
    }

    private func preferredOpenClawToolAgent(for images: [String]) -> Agent? {
        let requiredCapability: Capability = images.isEmpty ? .textChat : .vision
        return agentStore.preferredSubtaskWorker(
            for: requiredCapability,
            requireToolSupport: true
        )
    }
}
