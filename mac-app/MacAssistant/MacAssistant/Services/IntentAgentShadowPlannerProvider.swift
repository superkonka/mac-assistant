//
//  IntentAgentShadowPlannerProvider.swift
//  MacAssistant
//

import Foundation

final class IntentAgentShadowPlannerProvider: RequestPlannerShadowProvider {
    private struct ShadowDecision: Codable {
        let action: String
        let confidence: String
        let reason: String
        let localToolName: String?
        let agentCreationKind: String?
        let skillName: String?
    }

    static let shared = IntentAgentShadowPlannerProvider()

    let providerID = "intent-agent-shadow"
    let primaryProviderID = "intent-agent-primary"
    private let allowedActions: Set<String> = [
        "continue_agent_creation_flow",
        "resume_interrupted_task",
        "respond_to_confirmation",
        "request_initial_setup",
        "show_skill_evolution_overview",
        "show_planner_console",
        "execute_tool_skill",
        "show_skill_overview",
        "show_agent_creation_guidance",
        "execute_local_tool_skill",
        "execute_explicit_skill",
        "handle_detected_skill",
        "handle_agent_suggestion",
        "route_parallel_link_research",
        "route_main_conversation"
    ]
    private let allowedConfidence: Set<String> = ["high", "medium", "low"]

    private let preferences = UserPreferenceStore.shared
    private let agentStore = AgentStore.shared
    private let gatewayClient = OpenClawGatewayClient.shared
    private let intelligence = ConversationIntelligence.shared

    private init() {}

    func planPrimary(_ envelope: RequestEnvelope) async -> RequestPlan? {
        await planWithAgent(
            envelope,
            sessionPrefix: "planner-primary",
            sessionLabel: "Planner Primary"
        )
    }

    func planShadow(_ envelope: RequestEnvelope) async -> RequestPlan? {
        guard preferences.plannerShadowEnabled else {
            return nil
        }

        return await planWithAgent(
            envelope,
            sessionPrefix: "planner-shadow",
            sessionLabel: "Planner Shadow"
        )
    }

    private func planWithAgent(
        _ envelope: RequestEnvelope,
        sessionPrefix: String,
        sessionLabel: String
    ) async -> RequestPlan? {

        guard let agent = selectPlannerAgent(for: envelope) else {
            LogDebug("IntentAgentShadow skipped: no usable planner agent")
            return nil
        }

        let parsed = intelligence.analyzeInput(envelope.originalText)
        let prompt = buildPrompt(envelope: envelope, parsed: parsed)
        let sessionKey = "\(sessionPrefix)-\(envelope.id.uuidString.lowercased())"
        let resolvedSessionLabel = OpenClawGatewayClient.uniqueSessionLabel(
            base: sessionLabel,
            uniqueSource: sessionKey
        )

        do {
            let raw = try await gatewayClient.sendMessage(
                agent: agent,
                sessionKey: sessionKey,
                sessionLabel: resolvedSessionLabel,
                requestID: envelope.id.uuidString,
                text: prompt,
                images: []
            )
            guard let decision = decodeDecision(from: raw) else {
                LogInfo("IntentAgentShadow returned unparsable payload agent=\(agent.id)")
                return nil
            }
            return await convert(decision: decision, envelope: envelope, parsed: parsed)
        } catch {
            LogInfo("IntentAgentShadow failed agent=\(agent.id) error=\((error as NSError).localizedDescription)")
            return nil
        }
    }

    private func selectPlannerAgent(for envelope: RequestEnvelope) -> Agent? {
        let usable = agentStore.usableAgents
        guard !usable.isEmpty else { return nil }

        if let preferred = agentStore.plannerPreferredAgent {
            return preferred
        }

        if let preferredID = preferences.plannerShadowPreferredAgentID,
           let preferred = usable.first(where: { $0.id == preferredID && agentStore.hasRole(.planner, for: $0) }) {
            return preferred
        }

        if let apiAgent = usable.first(where: { $0.provider != .ollama }) {
            return apiAgent
        }

        if let current = envelope.currentAgent,
           usable.contains(where: { $0.id == current.id }) {
            return current
        }

        return agentStore.defaultAgent ?? usable.first
    }

    private func buildPrompt(envelope: RequestEnvelope, parsed: ParsedInput) -> String {
        let capabilities = envelope.currentAgent?.capabilities.map(\.rawValue).joined(separator: ", ") ?? "none"
        let lastMessageSummary = envelope.lastMessage.map { "\($0.role.rawValue): \($0.content.prefix(120))" } ?? "none"

        return """
        你是一个只负责意图判定的规划器。不要回答用户问题，不要解释，不要输出 Markdown，只返回一个 JSON 对象。

        可选 action：
        - continue_agent_creation_flow
        - resume_interrupted_task
        - respond_to_confirmation
        - request_initial_setup
        - show_skill_evolution_overview
        - show_planner_console
        - execute_tool_skill
        - show_skill_overview
        - show_agent_creation_guidance
        - execute_local_tool_skill
        - execute_explicit_skill
        - handle_detected_skill
        - handle_agent_suggestion
        - route_parallel_link_research
        - route_main_conversation

        输出 JSON schema：
        {
          "action": "上面的一个值",
          "confidence": "high|medium|low",
          "reason": "一句中文原因",
          "localToolName": "可选，例如 app/futu",
          "agentCreationKind": "可选，runtimeSetup 或 workflowDesign",
          "skillName": "可选，内置 skill rawValue"
        }

        判定上下文：
        - 用户原文: \(jsonString(envelope.originalText))
        - cleanText: \(jsonString(parsed.cleanText))
        - 图片数量: \(envelope.images.count)
        - 当前 Agent: \(jsonString(envelope.currentAgent?.id ?? "none"))
        - 当前 Agent capabilities: \(jsonString(capabilities))
        - needsInitialSetup: \(envelope.needsInitialSetup)
        - creationFlowActive: \(envelope.creationFlowActive)
        - resumableTaskSessionID: \(jsonString(envelope.resumableTaskSessionID ?? "none"))
        - 最近一条消息摘要: \(jsonString(lastMessageSummary))
        - 解析出的显式 /Skill: \(jsonString(parsed.skillCommand?.skill.rawValue ?? "none"))
        - 解析出的 detectedSkill: \(jsonString(parsed.detectedSkill?.rawValue ?? "none"))
        - 解析出的 suggestedAgent: \(jsonString(parsed.suggestedAgent?.suggestedAgent?.id ?? "none"))

        只返回 JSON。
        """
    }

    private func decodeDecision(from raw: String) -> ShadowDecision? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = extractJSONObject(from: trimmed) ?? trimmed
        guard let data = candidate.data(using: .utf8) else {
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(ShadowDecision.self, from: data) else {
            return nil
        }
        return sanitize(decoded)
    }

    private func extractJSONObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}") else {
            return nil
        }
        return String(raw[start...end])
    }

    private func sanitize(_ decision: ShadowDecision) -> ShadowDecision? {
        let normalizedAction = decision.action.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConfidence = decision.confidence.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLocalTool = decision.localToolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCreationKind = decision.agentCreationKind?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSkill = decision.skillName?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard allowedActions.contains(normalizedAction),
              allowedConfidence.contains(normalizedConfidence),
              !decision.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if normalizedAction == "execute_local_tool_skill",
           let normalizedLocalTool,
           !["app", "futu"].contains(normalizedLocalTool) {
            return nil
        }

        if normalizedAction == "show_agent_creation_guidance",
           let normalizedCreationKind,
           !["runtimeSetup", "workflowDesign"].contains(normalizedCreationKind) {
            return nil
        }

        if ["execute_explicit_skill", "handle_detected_skill"].contains(normalizedAction),
           let normalizedSkill,
           AISkill(rawValue: normalizedSkill) == nil {
            return nil
        }

        return ShadowDecision(
            action: normalizedAction,
            confidence: normalizedConfidence,
            reason: decision.reason.trimmingCharacters(in: .whitespacesAndNewlines),
            localToolName: normalizedLocalTool,
            agentCreationKind: normalizedCreationKind,
            skillName: normalizedSkill
        )
    }

    private func convert(
        decision: ShadowDecision,
        envelope: RequestEnvelope,
        parsed: ParsedInput
    ) async -> RequestPlan {
        let confidence = PlannerConfidence(rawValue: decision.confidence.lowercased()) ?? .low
        let preparedInput = parsed.cleanText

        switch decision.action {
        case "continue_agent_creation_flow":
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .continueAgentCreationFlow(input: envelope.originalText),
                confidence: confidence,
                reason: decision.reason
            )

        case "resume_interrupted_task":
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .resumeInterruptedTask(sessionID: envelope.resumableTaskSessionID ?? "unknown"),
                confidence: confidence,
                reason: decision.reason
            )

        case "request_initial_setup":
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .requestInitialSetup,
                confidence: confidence,
                reason: decision.reason
            )

        case "show_skill_evolution_overview":
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .showSkillEvolutionOverview,
                confidence: confidence,
                reason: decision.reason
            )

        case "show_planner_console":
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .showPlannerConsole,
                confidence: confidence,
                reason: decision.reason
            )

        case "execute_tool_skill":
            let command = RequestPlanningHeuristics.detectToolSkillCommand(
                in: envelope.originalText,
                toolSkillRegistry: SkillRegistry.shared
            )
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .executeToolSkill(
                    name: command?.name ?? "unknown",
                    input: command?.input ?? preparedInput
                ),
                confidence: confidence,
                reason: decision.reason
            )

        case "show_skill_overview":
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .showSkillOverview,
                confidence: confidence,
                reason: decision.reason
            )

        case "show_agent_creation_guidance":
            let kind: AgentCreationRequestKind = decision.agentCreationKind == "workflowDesign" ? .workflowDesign : .runtimeSetup
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: kind == .workflowDesign
                    ? .startWorkflowDesignSession(input: envelope.originalText)
                    : .showAgentCreationGuidance(kind: kind),
                confidence: confidence,
                reason: decision.reason
            )

        case "execute_local_tool_skill":
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .executeLocalToolSkill(
                    name: decision.localToolName ?? "unknown",
                    input: envelope.originalText
                ),
                confidence: confidence,
                reason: decision.reason
            )

        case "execute_explicit_skill":
            let skill = parsed.skillCommand?.skill ?? AISkill(rawValue: decision.skillName ?? "") ?? .webSearch
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: RequestPlanningHeuristics.plannedAgentSwitch(for: parsed, images: envelope.images),
                primaryAction: .executeExplicitSkill(skill: skill, input: parsed.cleanText),
                confidence: confidence,
                reason: decision.reason
            )

        case "handle_detected_skill":
            let skill = parsed.detectedSkill ?? AISkill(rawValue: decision.skillName ?? "") ?? .webSearch
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: RequestPlanningHeuristics.plannedAgentSwitch(for: parsed, images: envelope.images),
                primaryAction: .handleDetectedSkill(
                    skill: skill,
                    input: parsed.cleanText,
                    executionInput: preparedInput
                ),
                confidence: confidence,
                reason: decision.reason
            )

        case "handle_agent_suggestion":
            if let suggestion = parsed.suggestedAgent {
                return RequestPlan(
                    envelope: envelope,
                    parsedInput: parsed,
                    preparedInput: preparedInput,
                    notices: [],
                    requestedAgentSwitch: RequestPlanningHeuristics.plannedAgentSwitch(for: parsed, images: envelope.images),
                    primaryAction: .handleAgentSuggestion(suggestion, input: parsed.cleanText),
                    confidence: confidence,
                    reason: decision.reason
                )
            }

        case "route_parallel_link_research":
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: RequestPlanningHeuristics.plannedAgentSwitch(for: parsed, images: envelope.images),
                primaryAction: .routeParallelLinkResearch(input: preparedInput),
                confidence: confidence,
                reason: decision.reason
            )

        case "respond_to_confirmation":
            break

        default:
            break
        }

        return RequestPlan(
            envelope: envelope,
            parsedInput: parsed,
            preparedInput: preparedInput,
            notices: [],
            requestedAgentSwitch: RequestPlanningHeuristics.plannedAgentSwitch(for: parsed, images: envelope.images),
            primaryAction: .routeMainConversation(input: preparedInput),
            confidence: confidence,
            reason: decision.reason
        )
    }

    private func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
