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
        "continue_processing",          // 新增：智能继续处理
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
        "route_main_conversation"
    ]
    private let allowedConfidence: Set<String> = ["high", "medium", "low"]

    private let preferences = UserPreferenceStore.shared
    private let agentStore = AgentStore.shared
    private let runtimeAdapter: ConversationRuntimeAdapter = NativeConversationRuntimeAdapter.shared
    private let intelligence = ConversationIntelligence.shared

    private init() {}

    func planPrimary(_ envelope: RequestEnvelope) async -> RequestPlan? {
        await planWithAgent(envelope)
    }

    func planShadow(_ envelope: RequestEnvelope) async -> RequestPlan? {
        guard preferences.plannerShadowEnabled else {
            return nil
        }

        return await planWithAgent(envelope)
    }

    private func planWithAgent(_ envelope: RequestEnvelope) async -> RequestPlan? {
        guard let agent = selectPlannerAgent(for: envelope) else {
            LogDebug("IntentAgentShadow skipped: no usable planner agent")
            return nil
        }

        guard agent.provider != .ollama else {
            LogInfo(
                "IntentAgentShadow skipped for local CLI planner agent=\(agent.id) provider=\(agent.provider.rawValue)"
            )
            return nil
        }

        let parsed = intelligence.analyzeInput(envelope.originalText)
        let prompt = buildPrompt(envelope: envelope, parsed: parsed)
        let sessionKey = envelope.sessionTopology.shadowSessionKey
        do {
            let raw = try await runtimeAdapter.sendMessage(
                agent: agent,
                sessionKey: sessionKey,
                sessionLabel: envelope.sessionTopology.shadowSessionLabel,
                requestID: envelope.id.uuidString.lowercased(),
                text: prompt,
                images: [],
                systemPrompt: nil,
                onAssistantText: nil
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

        if let preferredID = preferences.plannerShadowPreferredAgentID,
           let preferred = usable.first(where: { $0.id == preferredID && agentStore.hasRole(.planner, for: $0) }) {
            return preferred
        }

        if let current = envelope.currentAgent,
           usable.contains(where: { $0.id == current.id }),
           current.supports(.textChat) {
            return current
        }

        if let preferred = agentStore.plannerPreferredAgent {
            return preferred
        }

        if let apiAgent = usable.first(where: { $0.provider != .ollama }) {
            return apiAgent
        }

        return agentStore.defaultAgent ?? usable.first
    }

    private func buildPrompt(envelope: RequestEnvelope, parsed: ParsedInput) -> String {
        let capabilities = envelope.currentAgent?.capabilities.map(\.rawValue).joined(separator: ", ") ?? "none"
        let lastMessageSummary = envelope.lastMessage.map { "\($0.role.rawValue): \($0.content.prefix(120))" } ?? "none"

        return """
        你是一个只负责意图判定的规划器。不要回答用户问题，不要解释，不要输出 Markdown，只返回一个 JSON 对象。

        可选 action：
        - continue_processing: 用户说"继续"、"继续处理"、"接着做"等，需要分析所有可继续的事项（任务、服务、对话）
        - resume_interrupted_task: 明确指定要继续某个特定任务（如"继续微信那个任务"）
        - continue_agent_creation_flow
        - respond_to_confirmation
        - request_initial_setup
        - show_skill_evolution_overview
        - show_planner_console
        - execute_tool_skill
        - show_skill_overview: 用户明确想查看/管理 Skills（如"打开 Skills"、"/skills"）
        - show_agent_creation_guidance
        - execute_local_tool_skill
        - execute_explicit_skill
        - handle_detected_skill
        - handle_agent_suggestion
        - route_main_conversation: 默认路由，普通对话、服务状态查询等都走这个
        
        重要区分：
        - 用户问"有哪些服务"、"服务状态"、"运行中的服务" → 这是服务状态查询，使用 route_main_conversation
        - 用户说"打开 Skills"、"/skills"、"技能管理" → 这才是 show_skill_overview
        
        注意：当用户说"继续"、"继续处理"等模糊指令时，优先使用 continue_processing 而不是 resume_interrupted_task

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
        - conversationID: \(jsonString(envelope.sessionTopology.conversationID))
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

        case "resume_interrupted_task", "continue_processing":
            // 统一处理所有"继续"类意图
            return await handleContinueProcessingIntent(
                envelope: envelope,
                parsed: parsed,
                preparedInput: preparedInput,
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
            guard let skill = parsed.skillCommand?.skill ?? AISkill(rawValue: decision.skillName ?? "") else {
                break
            }
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
            guard let skill = parsed.detectedSkill ?? AISkill(rawValue: decision.skillName ?? "") else {
                break
            }
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
    
    // MARK: - 智能"继续处理"意图处理
    
    /// 处理"继续处理"意图
    /// 分析所有可选项，根据情况自动恢复或询问用户
    private func handleContinueProcessingIntent(
        envelope: RequestEnvelope,
        parsed: ParsedInput,
        preparedInput: String,
        confidence: PlannerConfidence,
        reason: String
    ) async -> RequestPlan {
        
        // 获取当前任务会话和服务状态
        let (taskSessions, services, runtimes, messages, activeServiceTasks) = await MainActor.run {
            (
                CommandRunner.shared.taskSessions,
                ServiceManager.shared.services.map { $0.toServiceDefinition() },
                [:] as [String: ServiceRuntimeInfo],  // runtimeInfos 简化
                CommandRunner.shared.messages,
                [] as [String]    // activeServiceTasks 简化
            )
        }
        
        // 分析可继续处理的事项
        let analysis = ContinueIntentAnalyzer.shared.analyze(
            taskSessions: taskSessions,
            services: services,
            serviceRuntimes: runtimes,
            messages: messages,
            activeServiceTasks: Set(activeServiceTasks)
        )
        
        // 根据分析结果决策
        if analysis.hasClearSingleOption,
           let primaryOption = analysis.highestPriorityOption {
            // 只有一个明确的选项，直接处理
            // 同时在主会话显示其他可能需要处理的事项
            
            let otherOptionsMessage = analysis.formatAsOtherOptionsMessage(
                excluding: primaryOption.id
            )
            
            var notices: [String] = []
            if !otherOptionsMessage.isEmpty {
                notices.append(otherOptionsMessage)
            }
            
            // 根据选项类型执行相应操作
            let primaryAction: RequestPlannerPrimaryAction
            switch primaryOption.action {
            case .resumeTask(let sessionID):
                primaryAction = .resumeInterruptedTask(sessionID: sessionID)
            case .startService(let serviceID, _):
                // 启动服务通过主会话路由，让 AI 处理
                let service = services.first { $0.id == serviceID }
                let prompt = "帮我启动服务「\(service?.name ?? serviceID)」"
                primaryAction = .routeMainConversation(input: prompt)
            case .restartService(let serviceID, _):
                let service = services.first { $0.id == serviceID }
                let prompt = "帮我重启服务「\(service?.name ?? serviceID)」"
                primaryAction = .routeMainConversation(input: prompt)
            case .newRequest(let prompt):
                primaryAction = .routeMainConversation(input: prompt)
            default:
                primaryAction = .routeMainConversation(input: preparedInput)
            }
            
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: notices,
                requestedAgentSwitch: nil,
                primaryAction: primaryAction,
                confidence: .high,
                reason: "找到明确的继续处理项: \(primaryOption.title)"
            )
            
        } else if analysis.options.isEmpty {
            // 没有可继续处理的事项
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: ["没有发现需要继续处理的事项。您可以从头开始一个新的任务。"],
                requestedAgentSwitch: nil,
                primaryAction: .routeMainConversation(input: preparedInput),
                confidence: .medium,
                reason: "没有可继续处理的事项"
            )
            
        } else {
            // 有多个选项，询问用户 - 通过主会话路由，让 AI 展示选项
            let userMessage = analysis.formatAsUserMessage()
            
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: userMessage,  // 使用格式化的消息作为输入
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .routeMainConversation(input: userMessage),
                confidence: .medium,
                reason: "有 \(analysis.options.count) 个可继续处理的选项，需要用户选择"
            )
        }
    }

    private func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
