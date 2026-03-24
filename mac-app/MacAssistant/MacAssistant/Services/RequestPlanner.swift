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
        // Phase 2: MCP 服务前置检测（最高优先级）
        if let mcpPlan = await detectMCPDirectExecution(envelope) {
            LogInfo("[RequestPlanner] MCP 直接执行检测命中: \(mcpPlan.reason)")
            return mcpPlan.withPlannerID("mcp-direct")
        }
        
        if let preflightPlan = await RuleBasedRequestPlannerProvider.shared.priorityLocalPlan(envelope) {
            return preflightPlan.withPlannerID(ruleProvider.providerID)
        }

        switch preferences.plannerPrimaryStrategy {
        case .ruleBased:
            let primaryPlan = await ruleProvider.plan(envelope).withPlannerID(ruleProvider.providerID)
            
            // 检查是否需要 Committee 会诊
            let committeeCheck = await PlannerCommitteeService.shared.shouldTriggerCommittee(for: primaryPlan)
            if committeeCheck.shouldTrigger, let reason = committeeCheck.reason {
                LogInfo("[RequestPlanner] 触发 Planner Committee，原因: \(reason.rawValue)")
                
                // 异步召集委员会（不阻塞主流程）
                Task {
                    await conveneCommitteeIfNeeded(for: primaryPlan, reason: reason, envelope: envelope)
                }
            }

            if preferences.plannerShadowEnabled {
                let shadowProvider = self.intentAgentProvider
                Task { [primaryPlan] in
                    if let shadowPlan = await shadowProvider.planShadow(envelope)?.withPlannerID(shadowProvider.providerID) {
                        self.logShadowComparison(primary: primaryPlan, shadow: shadowPlan)
                    }
                }
            }

            return primaryPlan

        case .agentPrimary:
            async let fallbackRule = ruleProvider.plan(envelope)
            async let primaryCandidate = intentAgentProvider.planPrimary(envelope)

            let fallbackPlan = await fallbackRule.withPlannerID(ruleProvider.providerID)

            if let primaryPlan = await primaryCandidate?.withPlannerID(intentAgentProvider.primaryProviderID) {
                // 检查是否需要 Committee 会诊
                let committeeCheck = await PlannerCommitteeService.shared.shouldTriggerCommittee(for: primaryPlan)
                if committeeCheck.shouldTrigger, let reason = committeeCheck.reason {
                    LogInfo("[RequestPlanner] 触发 Planner Committee，原因: \(reason.rawValue)")
                    
                    Task {
                        await conveneCommitteeIfNeeded(for: primaryPlan, reason: reason, envelope: envelope)
                    }
                }
                
                if preferences.plannerShadowEnabled {
                    logShadowComparison(primary: primaryPlan, shadow: fallbackPlan.withPlannerID("rule-based-shadow"))
                }
                return primaryPlan
            }

            LogInfo("RequestPlanner primary agent fallback -> rule-based")
            return fallbackPlan
        }
    }
    
    /// 召集委员会进行会诊
    @MainActor
    private func conveneCommitteeIfNeeded(
        for plan: RequestPlan,
        reason: CommitteeTriggerReason,
        envelope: RequestEnvelope
    ) async {
        do {
            // 构建委员会请求
            let request = buildCommitteeRequest(plan: plan, reason: reason, envelope: envelope)
            
            // 召集委员会
            let conclusion = try await PlannerCommitteeService.shared.conveneCommittee(
                request: request,
                timeout: 30.0
            )
            
            // 根据委员会结论处理
            await handleCommitteeConclusion(conclusion, originalPlan: plan)
            
            // 保存决策记录
            let record = CommitteeDecisionRecord(
                id: UUID().uuidString,
                timestamp: Date(),
                triggerReason: reason.rawValue,
                decision: conclusion.decision.rawValue,
                consensusLevel: conclusion.consensusLevel.rawValue,
                summary: conclusion.summary,
                memberCount: conclusion.memberOpinions.count
            )
            CommitteeDecisionStore.shared.save(record)
            
        } catch {
            LogError("[RequestPlanner] Committee 会诊失败: \(error)")
        }
    }
    
    /// 构建委员会请求
    @MainActor
    private func buildCommitteeRequest(
        plan: RequestPlan,
        reason: CommitteeTriggerReason,
        envelope: RequestEnvelope
    ) -> CommitteeDecisionRequest {
        // 构建风险评估
        let riskScore = plan.riskScore
        let riskLevel: RiskLevel
        if riskScore > 0.8 {
            riskLevel = .critical
        } else if riskScore > 0.6 {
            riskLevel = .high
        } else if riskScore > 0.3 {
            riskLevel = .medium
        } else {
            riskLevel = .low
        }
        
        let riskAssessment = CommitteeDecisionRequest.RiskAssessment(
            level: riskLevel,
            factors: [
                .init(
                    type: "confidence",
                    severity: 1.0 - plan.confidenceScore,
                    description: "低置信度"
                ),
                .init(
                    type: "complexity",
                    severity: min(Double(plan.effectiveDispatchAssignments.count) / 6.0, 1.0),
                    description: "任务复杂度"
                ),
                .init(
                    type: "intent",
                    severity: plan.intentKind == .workflow || plan.intentKind == .service ? 0.7 : 0.2,
                    description: "意图类型影响"
                )
            ],
            score: riskScore
        )
        
        // 获取可用技能
        let availableSkills = SkillCatalog.shared.skills
        
        let workflowState: WorkflowRunState?
        switch plan.primaryAction {
        case .continueWorkflowRun(let runID, _, _):
            workflowState = WorkflowRunCoordinator.shared.runState(runID: runID)
        case .reflectWorkflowRun(let runID, _):
            workflowState = WorkflowRunCoordinator.shared.runState(runID: runID)
        case .remindUserAboutWorkflow(let runID, _, _):
            workflowState = WorkflowRunCoordinator.shared.runState(runID: runID)
        default:
            if let runID = plan.selectedResources.workflowRunID ?? plan.metadata["workflow_run_id"] {
                workflowState = WorkflowRunCoordinator.shared.runState(runID: runID)
            } else {
                workflowState = nil
            }
        }

        // 构建上下文
        let context = CommitteeDecisionRequest.CommitteeContext(
            intentKind: plan.intentKind,
            workflowState: workflowState,
            recentActions: [], // 可以从执行日志获取
            userPreferences: .init(
                autoApproveLowRisk: true,
                requireApprovalFor: ["delete", "modify"],
                preferredNotificationStyle: .banner
            ),
            availableSkills: availableSkills,
            riskAssessment: riskAssessment,
            plannerEvidence: plan.evidence,
            dispatchAssignments: plan.effectiveDispatchAssignments,
            selectedResources: plan.selectedResources,
            committeeSignals: plan.committeeSignals
        )

        let urgency: UrgencyLevel
        if riskScore > 0.9 {
            urgency = .critical
        } else if riskScore > 0.75 {
            urgency = .high
        } else if riskScore > 0.45 {
            urgency = .medium
        } else {
            urgency = .low
        }
        
        return CommitteeDecisionRequest(
            query: envelope.originalText,
            context: context,
            urgency: urgency,
            triggerReason: reason
        )
    }
    
    /// 处理委员会结论
    @MainActor
    private func handleCommitteeConclusion(_ conclusion: CommitteeConclusion, originalPlan: RequestPlan) async {
        switch conclusion.decision {
        case .proceed:
            LogInfo("[RequestPlanner] Committee 决定继续执行原方案")
            // 继续执行原方案
            
        case .pause, .escalate, .delegateToUser:
            LogInfo("[RequestPlanner] Committee 决定需要用户确认")
            // 发送通知给用户
            await NotificationManager.shared.send(
                title: "需要您的决策",
                body: conclusion.summary,
                priority: .high
            )
            
        case .replan:
            LogInfo("[RequestPlanner] Committee 建议重新规划")
            // 可以触发重新规划逻辑
            
        case .abort:
            LogWarning("[RequestPlanner] Committee 建议中止")
            // 发送取消通知
            await NotificationManager.shared.send(
                title: "任务已取消",
                body: "委员会建议中止此任务",
                priority: .medium
            )
            
        case .requestMoreInfo:
            LogInfo("[RequestPlanner] Committee 需要更多信息")
            // 可以请求用户提供更多信息
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
    
    // MARK: - Phase 2: MCP 原生调度
    
    /// 检测是否是直接的 MCP 服务调用请求
    /// 如果检测到用户明确想使用某个 MCP 服务，直接返回执行计划，不经过 LLM
    private func detectMCPDirectExecution(_ envelope: RequestEnvelope) async -> RequestPlan? {
        let text = envelope.originalText.lowercased()
        
        // 获取所有可用的 MCP 服务
        let mcpServices = await MainActor.run {
            ServiceManager.shared.services.filter {
                $0.category == .mcp &&
                ServiceManager.shared.runtimeInfos[$0.id]?.status == .running
            }
        }
        
        guard !mcpServices.isEmpty else {
            return nil
        }
        
        // 规则 1: 明确提到 "用/通过/调用 [服务名] MCP"
        for service in mcpServices {
            let servicePatterns = [
                "用\(service.name)",
                "通过\(service.name)",
                "调用\(service.name)",
                "使用\(service.name)",
                "\(service.name)mcp",
                "\(service.name) mcp",
                "\(service.name)服务"
            ]
            
            if servicePatterns.contains(where: { text.contains($0) }) {
                let (operation, params) = extractMCPOperation(from: text, service: service)
                
                return buildMCPPlan(
                    envelope: envelope,
                    service: service,
                    operation: operation,
                    parameters: params
                )
            }
        }
        
        // 规则 2: 特定功能关键词匹配
        // 小红书 + 热搜/热门/趋势
        if text.contains("小红书") && (text.contains("热搜") || text.contains("热门") || text.contains("趋势")) {
            if let xhsService = mcpServices.first(where: { $0.id.contains("xiaohongshu") || $0.name.contains("小红书") }) {
                return buildMCPPlan(
                    envelope: envelope,
                    service: xhsService,
                    operation: "trending",
                    parameters: [:]
                )
            }
        }
        
        // 规则 3: GitHub + issue/PR/repo 相关
        if text.contains("github") && (text.contains("issue") || text.contains("pr") || text.contains("仓库")) {
            if let ghService = mcpServices.first(where: { $0.id.contains("github") || $0.name.contains("GitHub") }) {
                return buildMCPPlan(
                    envelope: envelope,
                    service: ghService,
                    operation: "query",
                    parameters: extractGitHubParameters(from: text)
                )
            }
        }
        
        return nil
    }
    
    /// 从用户输入中提取 MCP 操作和参数
    private func extractMCPOperation(from text: String, service: ServiceDefinition) -> (operation: String, parameters: [String: String]) {
        var operation = "health"
        var parameters: [String: String] = [:]
        
        // 根据服务类型和关键词提取操作
        switch service.id {
        case let id where id.contains("xiaohongshu"):
            if text.contains("搜索") || text.contains("查找") || text.contains("搜") {
                operation = "search"
                // 提取搜索关键词（简单实现：取"搜索"后面的词）
                if let range = text.range(of: "搜索") {
                    let after = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty {
                        parameters["keyword"] = String(after.prefix(20))
                    }
                }
            } else if text.contains("热搜") || text.contains("热门") || text.contains("趋势") {
                operation = "trending"
            }
            
        case let id where id.contains("github"):
            if text.contains("issue") {
                operation = "list_issues"
            } else if text.contains("pr") || text.contains("pull request") {
                operation = "list_prs"
            } else if text.contains("repo") || text.contains("仓库") {
                operation = "get_repo"
            }
            
        default:
            operation = "health"
        }
        
        return (operation, parameters)
    }
    
    /// 提取 GitHub 相关参数
    private func extractGitHubParameters(from text: String) -> [String: String] {
        var params: [String: String] = [:]
        
        // 简单提取：查找 owner/repo 格式的内容
        let pattern = #"([a-zA-Z0-9_-]+)/([a-zA-Z0-9_-]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let ownerRange = Range(match.range(at: 1), in: text),
               let repoRange = Range(match.range(at: 2), in: text) {
                params["owner"] = String(text[ownerRange])
                params["repo"] = String(text[repoRange])
            }
        }
        
        return params
    }
    
    /// 构建 MCP 执行计划
    private func buildMCPPlan(
        envelope: RequestEnvelope,
        service: ServiceDefinition,
        operation: String,
        parameters: [String: String]
    ) -> RequestPlan {
        RequestPlan(
            envelope: envelope,
            parsedInput: ParsedInput(
                original: envelope.originalText,
                cleanText: envelope.originalText
            ),
            preparedInput: envelope.originalText,
            notices: ["🚀 直接调用 MCP 服务: \(service.name)"],
            requestedAgentSwitch: nil,
            primaryAction: .executeMCPService(
                serviceID: service.id,
                operation: operation,
                parameters: parameters
            ),
            confidence: .high,
            reason: "用户明确请求使用 MCP 服务: \(service.name), 操作: \(operation)"
        )
    }
}

final class RuleBasedRequestPlannerProvider: RequestPlannerProvider {
    static let shared = RuleBasedRequestPlannerProvider()

    let providerID = "rule-based-v1"
    private let workflowDraftIDKey = "workflow_draft_id"
    private let pendingWorkflowDraftKey = "pending_workflow_draft"
    private let pendingWorkflowClarificationKey = "pending_workflow_clarification"
    private let workflowClarificationInputKey = "workflow_clarification_input"
    private let workflowModificationInputKey = "workflow_modification_input"
    private let pendingWorkflowRunKey = "pending_workflow_run"
    private let pendingWorkflowReplanKey = "pending_workflow_replan"
    private let workflowRunIDKey = "workflow_run_id"
    private let workflowTaskDefinitionIDKey = "workflow_task_definition_id"
    private let workflowStepIDKey = "workflow_step_id"

    private let intelligence = ConversationIntelligence.shared
    private let toolSkillRegistry = SkillRegistry.shared
    private let orchestrator = AgentOrchestrator.shared

    private struct NativeServiceExecutionCandidate {
        let service: ServiceDefinition
        let skillID: String
        let operation: String
        let endpoint: String?
        let method: String?
        let jsonBody: String?
        let title: String
        let reason: String
    }

    private init() {}

    private func executorLabel(for strategy: SubtaskStrategy) -> String {
        switch strategy {
        case .useBuiltin(let service):
            return service.rawValue
        case .useSkill(let skillID):
            return "Skill:\(skillID)"
        case .useAgent(let agentID):
            return "Agent:\(agentID)"
        case .useOpenClaw(let agentID):
            return "OpenClaw:\(agentID)"
        case .custom:
            return "Auto"
        }
    }

    private func selectedResources(for plan: SubtaskPlan) -> PlannerSelectedResources {
        var serviceIDs: [String] = []
        var skillIDs: [String] = []
        var agentIDs: [String] = []

        for blueprint in plan.blueprints {
            switch blueprint.strategy {
            case .useBuiltin(let builtin):
                serviceIDs.append(builtin.rawValue)
            case .useSkill(let skillID):
                skillIDs.append(skillID)
            case .useAgent(let agentID):
                agentIDs.append(agentID)
            case .useOpenClaw(let agentID):
                agentIDs.append(agentID)
            case .custom:
                break
            }
        }

        return PlannerSelectedResources(
            serviceIDs: Array(Set(serviceIDs)).sorted(),
            skillIDs: Array(Set(skillIDs)).sorted(),
            subtaskIDs: plan.blueprints.map(\.id),
            agentIDs: Array(Set(agentIDs)).sorted()
        )
    }

    private func planForNativeServiceExecution(
        envelope: RequestEnvelope,
        parsed: ParsedInput,
        intentKind: IntentKind
    ) async -> RequestPlan? {
        let services = await MainActor.run { ServiceManager.shared.services }
        guard let candidate = nativeServiceExecutionCandidate(for: envelope.originalText, services: services) else {
            return nil
        }

        var parameters: [String: String] = [
            "operation": candidate.operation
        ]
        if let endpoint = candidate.endpoint, !endpoint.isEmpty {
            parameters["endpoint"] = endpoint
        }
        if let method = candidate.method, !method.isEmpty {
            parameters["method"] = method
        }
        if let jsonBody = candidate.jsonBody, !jsonBody.isEmpty {
            parameters["json_body"] = jsonBody
        }

        let assignment = ExecutionAssignment(
            id: "native-service-\(candidate.service.id)-\(candidate.operation)",
            kind: .service,
            title: candidate.title,
            executorLabel: "Native MCP Executor",
            summary: "直接调用 \(candidate.service.name) 的原生 HTTP 能力。",
            targetID: candidate.service.id,
            returnsToMainConversation: true,
            requiresApproval: candidate.operation == "invoke" && (candidate.method ?? "GET") != "GET"
        )

        return RequestPlan(
            envelope: envelope,
            parsedInput: parsed,
            preparedInput: parsed.cleanText,
            notices: ["已切换到原生 MCP 执行链"],
            requestedAgentSwitch: nil,
            primaryAction: .executeNativeSkill(
                skillID: candidate.skillID,
                parameters: parameters,
                title: candidate.title
            ),
            confidence: .high,
            reason: candidate.reason,
            intentKind: intentKind,
            evidence: [
                PlannerEvidence(
                    timestamp: Date(),
                    source: .heuristic,
                    description: "识别到明确的 HTTP MCP 检查/调用请求",
                    confidence: 0.88
                )
            ],
            dispatchAssignments: [assignment],
            selectedResources: PlannerSelectedResources(
                serviceIDs: [candidate.service.id],
                skillIDs: [candidate.skillID]
            )
        )
    }

    private func nativeServiceExecutionCandidate(
        for text: String,
        services: [ServiceDefinition]
    ) -> NativeServiceExecutionCandidate? {
        let normalizedText = RequestPlanningHeuristics.normalized(text)
        guard !normalizedText.isEmpty else { return nil }

        guard let service = services.first(where: { service in
            service.category == .mcp &&
            service.type == .http &&
            serviceAliases(for: service).contains(where: { alias in
                let foldedAlias = foldedServiceIdentifier(alias)
                return !foldedAlias.isEmpty && foldedServiceIdentifier(normalizedText).contains(foldedAlias)
            })
        }) else {
            return nil
        }

        let containsPath = extractHTTPPath(from: text) != nil
        let containsJSONBody = extractJSONObjectString(from: text) != nil
        let healthMarkers = ["状态", "健康", "health", "status", "检查", "可用", "在线", "连通", "运行中", "在吗"]
        let invokeMarkers = ["调用", "请求", "invoke", "访问", "调一下", "发请求", "get ", "post ", "put ", "delete ", "patch "]

        let isHealthRequest = healthMarkers.contains(where: { normalizedText.contains($0) })
        let isInvokeRequest = containsPath || containsJSONBody || invokeMarkers.contains(where: { normalizedText.contains($0) })

        guard isHealthRequest || isInvokeRequest else {
            return nil
        }

        let operation = isInvokeRequest ? "invoke" : "health"
        let method = resolvedHTTPMethod(for: normalizedText, hasJSONBody: containsJSONBody)
        let endpoint = operation == "invoke" ? extractHTTPPath(from: text) : nil
        let jsonBody = extractJSONObjectString(from: text)
        let title = operation == "invoke"
            ? "原生调用 MCP「\(service.name)」"
            : "原生检查 MCP「\(service.name)」"
        let reason = operation == "invoke"
            ? "识别到明确的 MCP HTTP 调用请求，直接走原生执行链。"
            : "识别到明确的 MCP 健康/状态检查请求，直接走原生执行链。"

        return NativeServiceExecutionCandidate(
            service: service,
            skillID: "mcp.\(service.id)",
            operation: operation,
            endpoint: endpoint,
            method: method,
            jsonBody: jsonBody,
            title: title,
            reason: reason
        )
    }

    private func serviceAliases(for service: ServiceDefinition) -> [String] {
        var aliases: Set<String> = [
            service.id,
            service.name,
            service.name.lowercased(),
            service.id.replacingOccurrences(of: "-", with: ""),
            service.id.replacingOccurrences(of: "_", with: ""),
            service.name.replacingOccurrences(of: " ", with: "")
        ]

        if service.id.contains("xiaohongshu") || service.name.contains("小红书") {
            aliases.formUnion(["小红书", "小红书mcp", "xiaohongshu", "xhs", "热搜"])
        }
        if service.id.contains("github") || service.name.lowercased().contains("github") {
            aliases.formUnion(["github", "githubmcp", "仓库", "pull request"])
        }
        if service.id.contains("futu") || service.name.contains("富途") {
            aliases.formUnion(["富途", "futu", "行情", "交易"])
        }

        return Array(aliases)
    }

    private func foldedServiceIdentifier(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private func extractHTTPPath(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"/[A-Za-z0-9._~!$&'()*+,;=:@%-/]*"#),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              let range = Range(match.range, in: text) else {
            return nil
        }

        let path = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func extractJSONObjectString(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else {
            return nil
        }

        let json = String(text[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return json.isEmpty ? nil : json
    }

    private func resolvedHTTPMethod(for normalizedText: String, hasJSONBody: Bool) -> String {
        if normalizedText.contains("delete") || normalizedText.contains("删除") {
            return "DELETE"
        }
        if normalizedText.contains("put") || normalizedText.contains("更新") || normalizedText.contains("修改") {
            return "PUT"
        }
        if normalizedText.contains("patch") {
            return "PATCH"
        }
        if normalizedText.contains("post") || normalizedText.contains("创建") || normalizedText.contains("提交") || hasJSONBody {
            return "POST"
        }
        return "GET"
    }

    private func subtaskRequiresApproval(_ plan: SubtaskPlan) -> Bool {
        plan.signals.contains {
            $0.kind == .externalCommunication || $0.kind == .destructiveAction
        }
    }

    private func dispatchAssignments(for plan: SubtaskPlan) -> [ExecutionAssignment] {
        let requiresApproval = subtaskRequiresApproval(plan)

        return plan.blueprints.map { blueprint in
            ExecutionAssignment(
                id: blueprint.id,
                kind: .subtask,
                title: blueprint.title,
                executorLabel: executorLabel(for: blueprint.strategy),
                summary: blueprint.description,
                targetID: blueprint.id,
                returnsToMainConversation: true,
                requiresApproval: requiresApproval
            )
        }
    }

    private func committeeSignals(for plan: SubtaskPlan, originalText: String) -> [CommitteeSignal] {
        let normalized = RequestPlanningHeuristics.normalized(originalText)
        let requestedDelegation = normalized.contains("代聊") || normalized.contains("托管") || normalized.contains("monitor")

        return plan.signals.compactMap { signal in
            switch signal.kind {
            case .multiIntent:
                return nil
            case .crossDomain:
                return CommitteeSignal(
                    triggerReason: .crossToolConflict,
                    summary: signal.summary,
                    confidenceScore: max(plan.confidence, 0.66),
                    riskScore: max(0.72, signal.severity)
                )
            case .externalCommunication:
                return CommitteeSignal(
                    triggerReason: .highRisk,
                    summary: requestedDelegation
                        ? "当前子任务计划涉及对外沟通和托管行为，建议专家组先确认回复边界。"
                        : signal.summary,
                    confidenceScore: max(plan.confidence, 0.72),
                    riskScore: max(0.82, signal.severity)
                )
            case .destructiveAction:
                return CommitteeSignal(
                    triggerReason: .highRisk,
                    summary: signal.summary,
                    confidenceScore: max(plan.confidence, 0.7),
                    riskScore: max(0.84, signal.severity)
                )
            case .lowConfidence:
                return CommitteeSignal(
                    triggerReason: .lowConfidence,
                    summary: signal.summary,
                    confidenceScore: max(plan.confidence, 0.25),
                    riskScore: max(0.5, signal.severity * 0.7)
                )
            case .longHorizon:
                return CommitteeSignal(
                    triggerReason: .novelScenario,
                    summary: signal.summary,
                    confidenceScore: max(plan.confidence, 0.68),
                    riskScore: max(0.68, signal.severity)
                )
            }
        }
    }

    private func evidence(for plan: SubtaskPlan) -> [PlannerEvidence] {
        var evidence: [PlannerEvidence] = [
            PlannerEvidence(
                timestamp: Date(),
                source: .heuristic,
                description: plan.planningReason,
                confidence: max(plan.confidence, 0.65)
            )
        ]

        for item in plan.capabilityEvidence.prefix(3) {
            let keywordSummary = item.matchedKeywords.isEmpty
                ? "无显著关键词命中"
                : "关键词: \(item.matchedKeywords.joined(separator: " / "))"
            evidence.append(
                PlannerEvidence(
                    timestamp: Date(),
                    source: .contextMatch,
                    description: "匹配能力 \(item.capabilityName) (\(item.capabilityType.rawValue))，得分 \(String(format: "%.2f", item.score))，\(keywordSummary)",
                    confidence: item.score
                )
            )
        }

        for signal in plan.signals.prefix(3) {
            evidence.append(
                PlannerEvidence(
                    timestamp: Date(),
                    source: .heuristic,
                    description: "拆解信号：\(signal.summary)",
                    confidence: min(max(signal.severity, 0.45), 0.92)
                )
            )
        }

        evidence.append(
            PlannerEvidence(
                timestamp: Date(),
                source: .agentAnalysis,
                description: "子任务复杂度评分 \(String(format: "%.2f", plan.complexityScore))，共 \(plan.blueprints.count) 个执行单元。",
                confidence: max(plan.confidence, 0.6)
            )
        )

        return evidence
    }

    private func planForSubtaskDecomposition(
        envelope: RequestEnvelope,
        parsed: ParsedInput
    ) async -> RequestPlan? {
        let subtaskPlan = await MainActor.run {
            SubtaskPlanningService.shared.planTask(envelope.originalText)
        }

        guard subtaskPlan.shouldDecompose, subtaskPlan.blueprints.count > 1 else {
            return nil
        }

        let assignments = dispatchAssignments(for: subtaskPlan)
        let resources = selectedResources(for: subtaskPlan)
        let committeeSignals = committeeSignals(for: subtaskPlan, originalText: envelope.originalText)
        let notices = [
            "我准备把这个请求拆成 \(subtaskPlan.blueprints.count) 个子任务，并交给任务中心并行处理。"
        ]

        return RequestPlan(
            envelope: envelope,
            parsedInput: parsed,
            preparedInput: parsed.cleanText,
            notices: notices,
            requestedAgentSwitch: nil,
            primaryAction: .executeSubtaskPlan(
                plan: subtaskPlan,
                originalInput: envelope.originalText
            ),
            confidence: .medium,
            reason: "检测到多个显著意图或并行执行信号，先由 Planner 显式拆成子任务。",
            intentKind: .singleTask,
            missingSlots: [],
            workflowCandidate: nil,
            evidence: evidence(for: subtaskPlan),
            dispatchAssignments: assignments,
            selectedResources: resources,
            committeeSignals: committeeSignals
        )
    }

    private func hasInterruptiblePendingFlow(_ envelope: RequestEnvelope) -> Bool {
        if envelope.creationFlowActive ||
            envelope.activeWorkflowDesignContext != nil ||
            envelope.activeBrowserSession?.pendingAction != nil ||
            envelope.activeBrowserSession?.status == .blockedByAuth {
            return true
        }

        guard let lastMessage = envelope.lastMessage else {
            return false
        }

        return lastMessage.metadata?["pending_skill_evolution_id"] != nil ||
            lastMessage.metadata?["initial_setup_prompt"] == "true" ||
            lastMessage.metadata?["pending_workflow_design"] == "true" ||
            lastMessage.metadata?[pendingWorkflowClarificationKey] == "true" ||
            lastMessage.metadata?[pendingWorkflowDraftKey] == "true" ||
            lastMessage.metadata?[pendingWorkflowRunKey] == "true" ||
            lastMessage.metadata?[BrowserConversationMetadataKeys.pendingSessionID] != nil ||
            lastMessage.metadata?["pending_switch"] != nil ||
            lastMessage.metadata?["pending_skill"] != nil ||
            lastMessage.detectedSkillSuggestion != nil
    }

    private func workflowCandidate(from draft: WorkflowDraft) -> WorkflowCandidate {
        WorkflowCandidate(
            name: draft.name,
            description: draft.description,
            stepsPreview: draft.suggestedSteps.map(\.name),
            estimatedSteps: draft.suggestedSteps.count,
            needsConfirmation: true,
            requiredCapabilities: [],
            missingSlots: draft.missingSlots
        )
    }

    private func planForPendingWorkflowDraft(
        envelope: RequestEnvelope,
        parsed: ParsedInput
    ) async -> RequestPlan? {
        guard let lastMessage = envelope.lastMessage,
              let draftID = lastMessage.metadata?[workflowDraftIDKey],
              let draft = await MainActor.run(body: {
                  WorkflowDraftStore.shared.draft(id: draftID)
              }) else {
            return nil
        }

        let candidate = workflowCandidate(from: draft)

        if lastMessage.metadata?[pendingWorkflowClarificationKey] == "true" {
            let filledSlots = RequestPlanningHeuristics.fillPlanningSlots(
                from: envelope.originalText,
                expectedSlots: draft.missingSlots
            )
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .requestWorkflowClarification(
                    candidate: candidate,
                    missingSlots: filledSlots
                ),
                confidence: .high,
                reason: "检测到当前正在补充 workflow 草稿槽位，优先继续这条草稿流程。",
                intentKind: .workflow,
                missingSlots: draft.missingSlots,
                workflowCandidate: candidate,
                evidence: [
                    PlannerEvidence(
                        timestamp: Date(),
                        source: .contextMatch,
                        description: "上一条消息仍处于 workflow 草稿澄清状态",
                        confidence: 0.9
                    )
                ],
                metadata: [
                    workflowDraftIDKey: draftID,
                    workflowClarificationInputKey: envelope.originalText
                ]
            )
        }

        if lastMessage.metadata?[pendingWorkflowDraftKey] == "true" {
            if RequestPlanningHeuristics.shouldPublishWorkflowDraft(envelope.originalText) {
                return RequestPlan(
                    envelope: envelope,
                    parsedInput: parsed,
                    preparedInput: parsed.cleanText,
                    notices: [],
                    requestedAgentSwitch: nil,
                    primaryAction: .startWorkflowRun(definitionID: draftID, initialContext: [:]),
                    confidence: .high,
                    reason: "用户确认发布 workflow 草稿并立即启动。",
                    intentKind: .workflow,
                    missingSlots: [],
                    workflowCandidate: candidate,
                    evidence: [
                        PlannerEvidence(
                            timestamp: Date(),
                            source: .explicitIntent,
                            description: "用户明确确认当前 workflow 草稿",
                            confidence: 0.95
                        )
                    ],
                    metadata: [workflowDraftIDKey: draftID]
                )
            }

            if RequestPlanningHeuristics.shouldModifyWorkflowDraft(envelope.originalText) {
                return RequestPlan(
                    envelope: envelope,
                    parsedInput: parsed,
                    preparedInput: parsed.cleanText,
                    notices: [],
                    requestedAgentSwitch: nil,
                    primaryAction: .createWorkflowDraft(
                        candidate: candidate,
                        originalInput: envelope.originalText
                    ),
                    confidence: .medium,
                    reason: "用户要求修改已有 workflow 草稿。",
                    intentKind: .workflow,
                    missingSlots: draft.missingSlots,
                    workflowCandidate: candidate,
                    evidence: [
                        PlannerEvidence(
                            timestamp: Date(),
                            source: .explicitIntent,
                            description: "用户要求修改 workflow 草稿",
                            confidence: 0.85
                        )
                    ],
                    metadata: [
                        workflowDraftIDKey: draftID,
                        workflowModificationInputKey: envelope.originalText
                    ]
                )
            }
        }

        return nil
    }

    private func planForPendingWorkflowRun(
        envelope: RequestEnvelope,
        parsed: ParsedInput
    ) -> RequestPlan? {
        guard let lastMessage = envelope.lastMessage,
              lastMessage.metadata?[pendingWorkflowRunKey] == "true",
              let runID = lastMessage.metadata?[workflowRunIDKey] else {
            return nil
        }

        let stepID = lastMessage.metadata?[workflowStepIDKey]
        let isReplan = lastMessage.metadata?[pendingWorkflowReplanKey] == "true"
        let reason = isReplan
            ? "上一条消息要求继续重规划当前 workflow，优先把输入交回 workflow runtime。"
            : "上一条消息正在等待 workflow 审批或补充，优先继续该 workflow。"

        var metadata: [String: String] = [
            workflowRunIDKey: runID
        ]
        if let taskDefinitionID = lastMessage.metadata?[workflowTaskDefinitionIDKey] {
            metadata[workflowTaskDefinitionIDKey] = taskDefinitionID
        }
        if let stepID {
            metadata[workflowStepIDKey] = stepID
        }
        if isReplan {
            metadata[pendingWorkflowReplanKey] = "true"
        }

        return RequestPlan(
            envelope: envelope,
            parsedInput: parsed,
            preparedInput: parsed.cleanText,
            notices: [],
            requestedAgentSwitch: nil,
            primaryAction: .continueWorkflowRun(
                runID: runID,
                stepID: stepID,
                userResponse: envelope.originalText
            ),
            confidence: .high,
            reason: reason,
            intentKind: .workflow,
            missingSlots: [],
            workflowCandidate: nil,
            evidence: [
                PlannerEvidence(
                    timestamp: Date(),
                    source: .contextMatch,
                    description: isReplan ? "上一条消息在等待 workflow 重规划输入" : "上一条消息在等待 workflow 继续输入",
                    confidence: 0.9
                )
            ],
            selectedResources: PlannerSelectedResources(
                workflowRunID: runID
            ),
            metadata: metadata
        )
    }

    private func cancelPendingFlowPlan(
        envelope: RequestEnvelope,
        parsed: ParsedInput
    ) -> RequestPlan {
        RequestPlan(
            envelope: envelope,
            parsedInput: parsed,
            preparedInput: parsed.cleanText,
            notices: [],
            requestedAgentSwitch: nil,
            primaryAction: .cancelPendingFlow,
            confidence: .high,
            reason: "主会话取消命令优先级最高，先终止当前挂起流程。"
        )
    }

    private func planForActiveBrowserSession(
        envelope: RequestEnvelope,
        parsed: ParsedInput
    ) -> RequestPlan? {
        guard let activeBrowserSession = envelope.activeBrowserSession,
              RequestPlanningHeuristics.shouldContinueBrowserSession(
                with: envelope.originalText,
                session: activeBrowserSession,
                lastMessage: envelope.lastMessage
              ) else {
            return nil
        }

        let observation = envelope.activeBrowserObservation ??
            activeBrowserSession.latestObservation ??
            activeBrowserSession.latestSnapshot.map(BrowserObservation.init(snapshot:))
        let delta = envelope.activeBrowserDelta ?? activeBrowserSession.latestDelta
        let summary = RequestPlanningHeuristics.browserObservationSummary(
            session: activeBrowserSession,
            observation: observation,
            delta: delta
        )

        var evidence: [PlannerEvidence] = [
            PlannerEvidence(
                timestamp: Date(),
                source: .contextMatch,
                description: summary,
                confidence: 0.85
            )
        ]

        if delta?.hasMeaningfulChange == true {
            evidence.append(
                PlannerEvidence(
                    timestamp: Date(),
                    source: .contextMatch,
                    description: "活动网页会话刚发生了页面或认证状态变化",
                    confidence: 0.75
                )
            )
        }

        if let lastUserGoal = activeBrowserSession.lastUserGoal, !lastUserGoal.isEmpty {
            evidence.append(
                PlannerEvidence(
                    timestamp: Date(),
                    source: .userHistory,
                    description: "浏览器会话最近目标：\(lastUserGoal)",
                    confidence: 0.7
                )
            )
        }

        let suggestedSteps = envelope.activeBrowserPlannerState?.suggestedNextSteps ?? []
        let notices = suggestedSteps.isEmpty
            ? []
            : ["当前页面候选下一步：\(suggestedSteps.prefix(3).joined(separator: " / "))"]

        if let candidate = RequestPlanningHeuristics.browserWorkflowCandidate(
            from: envelope.originalText,
            observation: observation
        ) {
            let missingSlots = candidate.missingSlots.filter { !$0.isFilled }
            let reasonPrefix = "\(summary) 这条输入更像长期浏览器协同诉求，应先交给 planner 补齐方案。"
            let metadata = [
                BrowserConversationMetadataKeys.pendingSessionID: activeBrowserSession.id,
                BrowserConversationMetadataKeys.pageKind: observation?.pageKind.rawValue ?? "unknown",
                BrowserConversationMetadataKeys.pageURL: observation?.url ?? activeBrowserSession.currentURL
            ]
            let committeeSignals: [CommitteeSignal] = observation?.looksLikeChatSurface == true
                ? [
                    CommitteeSignal(
                        triggerReason: .highRisk,
                        summary: "当前浏览器会话已进入聊天/通信页面，用户请求托管或代聊，需要额外的风险与策略审查。",
                        confidenceScore: 0.68,
                        riskScore: 0.84
                    )
                ]
                : []
            let selectedResources = PlannerSelectedResources(
                browserSessionID: activeBrowserSession.id
            )

            if !missingSlots.isEmpty {
                return RequestPlan(
                    envelope: envelope,
                    parsedInput: parsed,
                    preparedInput: parsed.cleanText,
                    notices: notices,
                    requestedAgentSwitch: nil,
                    primaryAction: .requestWorkflowClarification(
                        candidate: candidate,
                        missingSlots: missingSlots
                    ),
                    confidence: .medium,
                    reason: reasonPrefix,
                    intentKind: .workflow,
                    missingSlots: missingSlots,
                    workflowCandidate: candidate,
                    evidence: evidence,
                    selectedResources: selectedResources,
                    committeeSignals: committeeSignals,
                    metadata: metadata
                )
            }

            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: notices,
                requestedAgentSwitch: nil,
                primaryAction: .createWorkflowDraft(
                    candidate: candidate,
                    originalInput: envelope.originalText
                ),
                confidence: .medium,
                reason: reasonPrefix,
                intentKind: .workflow,
                missingSlots: [],
                workflowCandidate: candidate,
                evidence: evidence,
                selectedResources: selectedResources,
                committeeSignals: committeeSignals,
                metadata: metadata
            )
        }

        return RequestPlan(
            envelope: envelope,
            parsedInput: parsed,
            preparedInput: parsed.cleanText,
            notices: notices,
            requestedAgentSwitch: nil,
            primaryAction: .continueBrowserSession(
                sessionID: activeBrowserSession.id,
                input: envelope.originalText
            ),
            confidence: .high,
            reason: "\(summary) 检测到当前仍在同一条网页协同会话中，优先继续浏览器上下文。",
            intentKind: .singleTask,
            missingSlots: [],
            workflowCandidate: nil,
            evidence: evidence,
            selectedResources: PlannerSelectedResources(
                browserSessionID: activeBrowserSession.id
            ),
            metadata: [
                BrowserConversationMetadataKeys.pendingSessionID: activeBrowserSession.id,
                BrowserConversationMetadataKeys.pageKind: observation?.pageKind.rawValue ?? "unknown",
                BrowserConversationMetadataKeys.pageURL: observation?.url ?? activeBrowserSession.currentURL
            ]
        )
    }

    func priorityLocalPlan(_ envelope: RequestEnvelope) async -> RequestPlan? {
        let normalized = RequestPlanningHeuristics.normalized(envelope.originalText)
        let parsed = intelligence.analyzeInput(envelope.originalText)

        if hasInterruptiblePendingFlow(envelope),
           RequestPlanningHeuristics.shouldCancelPendingFlow(envelope.originalText) {
            return cancelPendingFlowPlan(envelope: envelope, parsed: parsed)
        }

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

        if let workflowDraftPlan = await planForPendingWorkflowDraft(envelope: envelope, parsed: parsed) {
            return workflowDraftPlan
        }

        if let pendingWorkflowRunPlan = planForPendingWorkflowRun(envelope: envelope, parsed: parsed) {
            return pendingWorkflowRunPlan
        }

        if let activeBrowserPlan = planForActiveBrowserSession(envelope: envelope, parsed: parsed) {
            return activeBrowserPlan
        }

        if let url = RequestPlanningHeuristics.browserStartURL(from: envelope.originalText) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .startBrowserSession(url: url, originalInput: envelope.originalText),
                confidence: .high,
                reason: "识别到明确的打开网页请求，先建立浏览器会话。"
            )
        }

        if RequestPlanningHeuristics.shouldTreatAsResumeCommand(normalized) {
            // 使用 ContinueIntentAnalyzer 分析所有可继续处理的事项
            let taskSessions = await MainActor.run { CommandRunner.shared.taskSessions }
            let services = await MainActor.run { ServiceManager.shared.services }
            let runtimes = await MainActor.run { ServiceManager.shared.runtimeInfos }
            let messages = await MainActor.run { CommandRunner.shared.messages }
            let activeTasks = await MainActor.run { Set(ServiceTaskManager.shared.activeServiceTasks.keys) }
            
            let analysis = ContinueIntentAnalyzer.shared.analyze(
                taskSessions: taskSessions,
                services: services,
                serviceRuntimes: runtimes,
                messages: messages,
                activeServiceTasks: activeTasks
            )
            
            // 如果只有一个明确的选项，直接处理
            if analysis.hasClearSingleOption,
               let primaryOption = analysis.highestPriorityOption {
                switch primaryOption.action {
                case .resumeTask(let sessionID):
                    return RequestPlan(
                        envelope: envelope,
                        parsedInput: parsed,
                        preparedInput: parsed.cleanText,
                        notices: [],
                        requestedAgentSwitch: nil,
                        primaryAction: .resumeInterruptedTask(sessionID: sessionID),
                        confidence: .high,
                        reason: "找到明确的继续处理项: \(primaryOption.title)"
                    )
                case .startService(_, let serviceName):
                    return RequestPlan(
                        envelope: envelope,
                        parsedInput: parsed,
                        preparedInput: "启动服务 \(serviceName)",
                        notices: [],
                        requestedAgentSwitch: nil,
                        primaryAction: .routeMainConversation(input: "启动服务 \(serviceName)"),
                        confidence: .high,
                        reason: "找到待启动的服务: \(serviceName)"
                    )
                default:
                    break
                }
            }
            
            // 有多个选项或没有明确选项，通过主会话询问用户
            let userMessage = analysis.formatAsUserMessage()
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: userMessage,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .routeMainConversation(input: userMessage),
                confidence: .medium,
                reason: analysis.options.isEmpty ? "没有可继续处理的事项" : "有多个可继续处理的选项，需要用户选择"
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
        if let priorityPlan = await priorityLocalPlan(envelope) {
            return priorityPlan
        }

        let normalized = RequestPlanningHeuristics.normalized(envelope.originalText)
        let parsed = intelligence.analyzeInput(envelope.originalText)
        let respectCurrentAgentSelection = RequestPlanningHeuristics.shouldRespectCurrentAgentSelection(
            for: envelope.originalText,
            images: envelope.images,
            currentAgent: envelope.currentAgent
        )

        if hasInterruptiblePendingFlow(envelope),
           RequestPlanningHeuristics.shouldCancelPendingFlow(envelope.originalText) {
            return cancelPendingFlowPlan(envelope: envelope, parsed: parsed)
        }

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

        if let activeBrowserPlan = planForActiveBrowserSession(envelope: envelope, parsed: parsed) {
            return activeBrowserPlan
        }

        if let url = RequestPlanningHeuristics.browserStartURL(from: envelope.originalText) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: parsed.cleanText,
                notices: [],
                requestedAgentSwitch: nil,
                primaryAction: .startBrowserSession(url: url, originalInput: envelope.originalText),
                confidence: .high,
                reason: "识别到明确的打开网页请求，优先建立浏览器会话。"
            )
        }
        
        // MARK: - Workflow Intent Detection (新增)
        let intentKind = RequestPlanningHeuristics.intentKind(from: envelope.originalText)
        if intentKind == .workflow || intentKind == .service {
            if let candidate = RequestPlanningHeuristics.workflowCandidate(from: envelope.originalText) {
                let missingSlots = candidate.missingSlots.filter { !$0.isFilled }
                
                if !missingSlots.isEmpty {
                    // 缺槽位，请求澄清
                    return RequestPlan(
                        envelope: envelope,
                        parsedInput: parsed,
                        preparedInput: parsed.cleanText,
                        notices: ["检测到 workflow 意图，但需要补充 \(missingSlots.count) 个信息"],
                        requestedAgentSwitch: nil,
                        primaryAction: .requestWorkflowClarification(
                            candidate: candidate,
                            missingSlots: missingSlots
                        ),
                        confidence: .medium,
                        reason: "识别到 workflow 意图，但缺少必要信息槽位。",
                        intentKind: intentKind,
                        missingSlots: missingSlots,
                        workflowCandidate: candidate,
                        evidence: [
                            PlannerEvidence(
                                timestamp: Date(),
                                source: .heuristic,
                                description: "关键词匹配触发 workflow 检测",
                                confidence: 0.7
                            )
                        ]
                    )
                } else {
                    // 槽位齐全，创建 draft
                    return RequestPlan(
                        envelope: envelope,
                        parsedInput: parsed,
                        preparedInput: parsed.cleanText,
                        notices: ["已生成 workflow 草稿，请确认"],
                        requestedAgentSwitch: nil,
                        primaryAction: .createWorkflowDraft(
                            candidate: candidate,
                            originalInput: envelope.originalText
                        ),
                        confidence: .high,
                        reason: "识别到 workflow 意图，信息完整，创建草稿待确认。",
                        intentKind: intentKind,
                        missingSlots: [],
                        workflowCandidate: candidate,
                        evidence: [
                            PlannerEvidence(
                                timestamp: Date(),
                                source: .heuristic,
                                description: "完整 workflow 意图识别",
                                confidence: 0.8
                            )
                        ]
                    )
                }
            }
        }

        if intentKind == .service,
           let nativeServicePlan = await planForNativeServiceExecution(
            envelope: envelope,
            parsed: parsed,
            intentKind: intentKind
           ) {
            return nativeServicePlan
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

        let preparedInput = parsed.cleanText
        let requestedAgentSwitch = RequestPlanningHeuristics.plannedAgentSwitch(for: parsed, images: envelope.images)

        if let nativeMacSkillName = await MacSystemAgent.shared.suggestedSkillName(for: envelope.originalText) {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: requestedAgentSwitch,
                primaryAction: .executeLocalToolSkill(name: nativeMacSkillName, input: envelope.originalText),
                confidence: .medium,
                reason: "识别为本机系统操作请求，优先走本地可验证执行链。"
            )
        }

        if let skillCommand = parsed.skillCommand {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
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
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: requestedAgentSwitch,
                primaryAction: .handleDetectedSkill(
                    skill: detectedSkill,
                    input: parsed.cleanText,
                    executionInput: preparedInput
                ),
                confidence: .medium,
                reason: "自然语言意图更接近内置 Skill，先进入 Skill 建议/独立处理链。"
            )
        }

        if !respectCurrentAgentSelection, let suggestedAgent = parsed.suggestedAgent {
            return RequestPlan(
                envelope: envelope,
                parsedInput: parsed,
                preparedInput: preparedInput,
                notices: [],
                requestedAgentSwitch: requestedAgentSwitch,
                primaryAction: .handleAgentSuggestion(suggestedAgent, input: parsed.cleanText),
                confidence: .medium,
                reason: "当前请求更适合切换或补齐特定能力 Agent。"
            )
        }

        if let subtaskPlan = await planForSubtaskDecomposition(envelope: envelope, parsed: parsed) {
            return subtaskPlan
        }

        return RequestPlan(
            envelope: envelope,
            parsedInput: parsed,
            preparedInput: preparedInput,
            notices: [],
            requestedAgentSwitch: requestedAgentSwitch,
            primaryAction: .routeMainConversation(input: preparedInput),
            confidence: .medium,
            reason: "未命中特殊分支，进入主对话路由链。"
        )
    }
}
