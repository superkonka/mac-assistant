//
//  PlannerCommitteeService.swift
//  MacAssistant
//
//  Planner Committee - 多 LLM 会诊系统
//  用于高风险场景的集体决策
//

import Foundation

// MARK: - Committee Models

/// 委员会成员（LLM 实例）
struct CommitteeMember: Identifiable, Equatable {
    let id: String
    let name: String
    let provider: LLMProvider
    let model: String
    let specialization: Specialization
    let weight: Double  // 投票权重
    
    enum Specialization: String, CaseIterable {
        case general        // 通用规划
        case security       // 安全专家
        case automation     // 自动化专家
        case communication  // 通信专家
        case system         // 系统专家
        case browser        // 浏览器专家
    }
}

/// LLM Provider
enum LLMProvider: String, Equatable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case local = "local"
    case kimi = "kimi"
    case deepseek = "deepseek"
}

/// 委员会决策请求
struct CommitteeDecisionRequest {
    let query: String
    let context: CommitteeContext
    let urgency: UrgencyLevel
    let triggerReason: CommitteeTriggerReason
    
    struct CommitteeContext {
        let intentKind: IntentKind
        let workflowState: WorkflowRunState?
        let recentActions: [ActionRecord]
        let userPreferences: UserPreferences
        let availableSkills: [SkillManifest]
        let riskAssessment: RiskAssessment
        let plannerEvidence: [PlannerEvidence]
        let dispatchAssignments: [ExecutionAssignment]
        let selectedResources: PlannerSelectedResources
        let committeeSignals: [CommitteeSignal]
    }
    
    struct ActionRecord: Codable {
        let timestamp: Date
        let action: String
        let result: ActionResult
        let skillUsed: String
        
        enum ActionResult: String, Codable {
            case success
            case failure
            case partial
            case unknown
        }
    }
    
    struct UserPreferences: Codable {
        let autoApproveLowRisk: Bool
        let requireApprovalFor: [String]
        let preferredNotificationStyle: NotificationStyle
        
        enum NotificationStyle: String, Codable {
            case silent
            case banner
            case alert
        }
    }
    
    struct RiskAssessment {
        let level: RiskLevel
        let factors: [RiskFactor]
        let score: Double  // 0-1
        
        struct RiskFactor: Codable {
            let type: String
            let severity: Double
            let description: String
        }
    }
}

enum UrgencyLevel: String, Codable {
    case low      // 可以等待
    case medium   // 尽快处理
    case high     // 立即处理
    case critical // 紧急，不等待委员会
}

enum RiskLevel: String, Codable {
    case low      // 低风险
    case medium   // 中等风险
    case high     // 高风险
    case critical // 极高风险
}

enum CommitteeTriggerReason: String, Codable {
    case lowConfidence        // 单个 LLM 置信度低
    case highRisk             // 高影响风险
    case crossToolConflict    // 跨工具冲突
    case multipleFailures     // 连续失败
    case explicitDelegate     // 用户明确请求
    case policyViolation      // 可能违反策略
    case novelScenario        // 全新场景
    case userEscalation       // 用户升级
}

// MARK: - Committee Response

/// 单个委员的意见
struct MemberOpinion: Codable {
    let memberID: String
    let memberName: String
    let specialization: String
    
    let decision: CommitteeDecision
    let confidence: Double  // 0-1
    let reasoning: String
    let suggestedActions: [SuggestedAction]
    let concerns: [Concern]
    let alternatives: [Alternative]
    
    struct SuggestedAction: Codable {
        let type: ActionType
        let description: String
        let priority: ActionPriority
        let estimatedOutcome: String
        
        enum ActionPriority: String, Codable {
            case urgent, high, medium, low
        }
    }
    
    struct Concern: Codable {
        let severity: Severity
        let category: String
        let description: String
        let mitigation: String?
        
        enum Severity: String, Codable {
            case low, medium, high, critical
        }
    }
    
    struct Alternative: Codable {
        let description: String
        let pros: [String]
        let cons: [String]
    }
}

/// 委员会集体决策
enum CommitteeDecision: String, Codable {
    case proceed        // 继续执行
    case pause          // 暂停等待用户
    case escalate       // 升级到用户
    case replan         // 重新规划
    case abort          // 中止执行
    case requestMoreInfo // 请求更多信息
    case delegateToUser // 委托给用户
}

enum ActionType: String, Codable {
    case continueWorkflow
    case pauseWorkflow
    case cancelWorkflow
    case requestApproval
    case modifyPlan
    case addSafetyCheck
    case notifyUser
    case callForHelp
}

// MARK: - Committee Service

/// Planner Committee Service - 多 LLM 会诊
@MainActor
final class PlannerCommitteeService: ObservableObject {
    static let shared = PlannerCommitteeService()
    
    // MARK: - Properties
    
    @Published private(set) var isActive = false
    @Published private(set) var currentSession: CommitteeSession?
    
    private var members: [CommitteeMember] = []
    private var opinionCache: [String: [MemberOpinion]] = [:]  // requestID -> opinions
    private let consensusThreshold = 0.7  // 共识阈值
    
    // MARK: - Initialization
    
    private init() {
        setupDefaultMembers()
    }
    
    private func setupDefaultMembers() {
        members = [
            CommitteeMember(
                id: "member-general",
                name: "General Planner",
                provider: .kimi,
                model: "kimi-k2.5",
                specialization: .general,
                weight: 1.0
            ),
            CommitteeMember(
                id: "member-security",
                name: "Security Guardian",
                provider: .anthropic,
                model: "claude-3-5-sonnet",
                specialization: .security,
                weight: 1.2  // 安全专家权重更高
            ),
            CommitteeMember(
                id: "member-automation",
                name: "Automation Expert",
                provider: .openAI,
                model: "gpt-4o",
                specialization: .automation,
                weight: 1.0
            ),
            CommitteeMember(
                id: "member-system",
                name: "System Architect",
                provider: .kimi,
                model: "kimi-k2.5",
                specialization: .system,
                weight: 1.0
            ),
            CommitteeMember(
                id: "member-communication",
                name: "Communication Expert",
                provider: .anthropic,
                model: "claude-3-5-sonnet",
                specialization: .communication,
                weight: 1.0
            ),
            CommitteeMember(
                id: "member-browser",
                name: "Browser Specialist",
                provider: .openAI,
                model: "gpt-4o",
                specialization: .browser,
                weight: 1.0
            )
        ]
    }
    
    // MARK: - Public API
    
    /// 检查是否应该触发委员会
    func shouldTriggerCommittee(for request: RequestPlan) -> (shouldTrigger: Bool, reason: CommitteeTriggerReason?) {
        if let explicitSignal = request.committeeSignals.max(by: { $0.riskScore < $1.riskScore }) {
            return (true, explicitSignal.triggerReason)
        }

        // 1. 置信度检查
        if request.confidenceScore < 0.55 {
            return (true, .lowConfidence)
        }
        
        // 2. 高风险检查
        if request.riskScore > 0.72 {
            return (true, .highRisk)
        }
        
        // 3. 显式委托请求
        if request.envelope.originalText.lowercased().contains("committee") ||
           request.envelope.originalText.lowercased().contains("会诊") ||
           request.envelope.originalText.lowercased().contains("集体决策") {
            return (true, .explicitDelegate)
        }
        
        // 4. 多工具冲突检查
        let uniqueTools = Set(request.effectiveDispatchAssignments.map(\.executorLabel))
        if uniqueTools.count > 2 && hasConflictingTools(Array(uniqueTools)) {
            return (true, .crossToolConflict)
        }
        
        // 5. 检查历史失败
        if let workflowState = workflowState(from: request),
           hasRecentFailures(workflowState) {
            return (true, .multipleFailures)
        }

        if request.intentKind == .workflow && request.effectiveDispatchAssignments.count > 1 {
            return (true, .novelScenario)
        }
        
        return (false, nil)
    }
    
    /// 召集委员会进行决策
    func conveneCommittee(
        request: CommitteeDecisionRequest,
        timeout: TimeInterval = 30.0
    ) async throws -> CommitteeConclusion {
        LogInfo("[PlannerCommittee] 召集委员会决策，原因: \(request.triggerReason.rawValue)")
        
        isActive = true
        defer { isActive = false }
        
        // 紧急情况快速通道
        if request.urgency == .critical {
            LogWarning("[PlannerCommittee] 紧急情况，跳过委员会直接决策")
            return CommitteeConclusion(
                decision: .escalate,
                consensusLevel: .emergency,
                summary: "紧急情况，立即升级到用户",
                recommendedAction: .escalateToUser(immediately: true, reason: "Critical urgency"),
                memberOpinions: [],
                dissentNotes: [],
                executionPlan: nil
            )
        }
        
        // 创建会话
        let sessionID = UUID().uuidString
        let session = CommitteeSession(
            id: sessionID,
            startedAt: Date(),
            request: request,
            status: .gatheringOpinions
        )
        currentSession = session
        
        // 并行收集所有委员意见
        var opinions: [MemberOpinion] = []
        
        let activeMembers = participatingMembers(for: request)

        await withTaskGroup(of: MemberOpinion?.self) { group in
            for member in activeMembers {
                group.addTask {
                    do {
                        return try await self.gatherOpinion(from: member, request: request)
                    } catch {
                        LogError("[PlannerCommittee] \(member.name) 提供意见失败: \(error)")
                        return nil
                    }
                }
            }
            
            for await opinion in group {
                if let opinion = opinion {
                    opinions.append(opinion)
                }
            }
        }
        
        // 保存意见
        opinionCache[sessionID] = opinions
        
        // 聚合决策
        let conclusion = aggregateOpinions(opinions, request: request)
        
        LogInfo("[PlannerCommittee] 委员会决策: \(conclusion.decision.rawValue), 共识度: \(conclusion.consensusLevel.rawValue)")
        
        return conclusion
    }
    
    /// 获取历史委员会决策记录
    func getDecisionHistory(limit: Int = 10) -> [CommitteeDecisionRecord] {
        // 从存储中读取历史记录
        return CommitteeDecisionStore.shared.loadRecent(limit: limit)
    }
    
    // MARK: - Private Methods
    
    private func gatherOpinion(from member: CommitteeMember, request: CommitteeDecisionRequest) async throws -> MemberOpinion {
        // 构建提示词
        let prompt = buildCommitteePrompt(for: member, request: request)
        
        // 调用 LLM
        let response = try await callLLM(provider: member.provider, model: member.model, prompt: prompt)
        
        // 解析响应
        return try parseOpinionResponse(response, member: member)
    }
    
    private func buildCommitteePrompt(for member: CommitteeMember, request: CommitteeDecisionRequest) -> String {
        var prompt = """
        你是 MacAssistant Planner Committee 的委员，你的角色是：\(member.name)
        专长领域：\(member.specialization.rawValue)
        
        当前需要决策的问题：
        \(request.query)
        
        触发委员会的原因：\(request.triggerReason.rawValue)
        当前 Planner 意图类型：\(request.context.intentKind.rawValue)
        
        """
        
        // 添加上下文
        if let workflowState = request.context.workflowState {
            prompt += """
            
            当前工作流状态：
            - 活跃步骤: \(workflowState.activeStepID ?? "无")
            - 阻塞原因: \(String(describing: workflowState.blockingReason))
            """
        }
        
        prompt += """
        
        风险评估：
        - 风险等级: \(request.context.riskAssessment.level.rawValue)
        - 风险分数: \(String(format: "%.2f", request.context.riskAssessment.score))
        """

        if !request.context.dispatchAssignments.isEmpty {
            let assignments = request.context.dispatchAssignments.map {
                "- [\($0.kind.rawValue)] \($0.title) -> \($0.executorLabel)"
            }.joined(separator: "\n")
            prompt += """
            
            当前 Planner 拟定的执行分配：
            \(assignments)
            """
        }

        if !request.context.plannerEvidence.isEmpty {
            let evidence = request.context.plannerEvidence.prefix(5).map {
                "- [\($0.source.rawValue)] \($0.description) (置信度 \(String(format: "%.2f", $0.confidence)))"
            }.joined(separator: "\n")
            prompt += """
            
            当前 Planner 证据：
            \(evidence)
            """
        }

        if !request.context.committeeSignals.isEmpty {
            let signals = request.context.committeeSignals.map {
                "- [\($0.triggerReason.rawValue)] \($0.summary) (风险 \(String(format: "%.2f", $0.riskScore)))"
            }.joined(separator: "\n")
            prompt += """
            
            当前触发委员会的信号：
            \(signals)
            """
        }

        let selectedResources = summarizedResources(from: request.context.selectedResources)
        if !selectedResources.isEmpty {
            prompt += """
            
            当前 Planner 已选资源：
            \(selectedResources)
            """
        }

        prompt += """
        
        请提供你的专业意见，包括：
        1. 推荐决策 (proceed/pause/escalate/replan/abort/requestMoreInfo/delegateToUser)
        2. 置信度 (0-1)
        3. 推理过程
        4. 建议的具体行动
        5. 任何顾虑或风险
        6. 备选方案
        
        请以结构化 JSON 格式回复。
        """
        
        return prompt
    }
    
    private func callLLM(provider: LLMProvider, model: String, prompt: String) async throws -> String {
        // 实际实现会调用对应的 LLM API
        // 这里使用模拟响应
        return simulateLLMResponse(provider: provider, prompt: prompt)
    }
    
    private func simulateLLMResponse(provider: LLMProvider, prompt: String) -> String {
        // 模拟 LLM 响应
        return """
        {
            "decision": "proceed",
            "confidence": 0.85,
            "reasoning": "经过分析，当前操作风险可控，建议继续执行",
            "suggestedActions": [
                {
                    "type": "continueWorkflow",
                    "description": "继续执行当前工作流",
                    "priority": "high",
                    "estimatedOutcome": "预期成功完成任务"
                }
            ],
            "concerns": [],
            "alternatives": []
        }
        """
    }
    
    private func parseOpinionResponse(_ response: String, member: CommitteeMember) throws -> MemberOpinion {
        // 解析 JSON 响应
        guard let data = response.data(using: .utf8) else {
            throw CommitteeError.parseFailed("Invalid response encoding")
        }
        
        let decoder = JSONDecoder()
        let parsed = try decoder.decode(OpinionJSON.self, from: data)
        
        return MemberOpinion(
            memberID: member.id,
            memberName: member.name,
            specialization: member.specialization.rawValue,
            decision: CommitteeDecision(rawValue: parsed.decision) ?? .escalate,
            confidence: parsed.confidence,
            reasoning: parsed.reasoning,
            suggestedActions: parsed.suggestedActions,
            concerns: parsed.concerns,
            alternatives: parsed.alternatives
        )
    }
    
    private func aggregateOpinions(_ opinions: [MemberOpinion], request: CommitteeDecisionRequest) -> CommitteeConclusion {
        // 按决策分组
        let grouped = Dictionary(grouping: opinions) { $0.decision }
        
        // 计算加权投票
        var weightedVotes: [CommitteeDecision: Double] = [:]
        for (decision, ops) in grouped {
            weightedVotes[decision] = ops.reduce(0.0) { sum, op in
                let member = members.first { $0.id == op.memberID }
                let weight = member?.weight ?? 1.0
                return sum + (op.confidence * weight)
            }
        }
        
        // 找出获胜决策
        let winner = weightedVotes.max { $0.value < $1.value }
        let winningDecision = winner?.key ?? .escalate
        let totalWeight = weightedVotes.values.reduce(0, +)
        let consensusRatio = (winner?.value ?? 0) / totalWeight
        
        // 确定共识等级
        let consensusLevel: ConsensusLevel
        if consensusRatio >= 0.9 {
            consensusLevel = .unanimous
        } else if consensusRatio >= 0.7 {
            consensusLevel = .strong
        } else if consensusRatio >= 0.5 {
            consensusLevel = .weak
        } else {
            consensusLevel = .split
        }
        
        // 收集反对意见
        let dissentNotes = opinions
            .filter { $0.decision != winningDecision }
            .map { "\($0.memberName) 建议 \($0.decision.rawValue): \($0.reasoning)" }
        
        // 生成总结
        let summary = generateSummary(opinions: opinions, winner: winningDecision)
        
        // 生成执行计划
        let executionPlan = generateExecutionPlan(
            decision: winningDecision,
            opinions: opinions,
            request: request
        )
        
        return CommitteeConclusion(
            decision: winningDecision,
            consensusLevel: consensusLevel,
            summary: summary,
            recommendedAction: mapToAction(winningDecision, opinions: opinions),
            memberOpinions: opinions,
            dissentNotes: dissentNotes,
            executionPlan: executionPlan
        )
    }
    
    private func generateSummary(opinions: [MemberOpinion], winner: CommitteeDecision) -> String {
        let supporting = opinions.filter { $0.decision == winner }
        let avgConfidence = supporting.reduce(0.0) { $0 + $1.confidence } / Double(max(supporting.count, 1))
        
        return "委员会建议 \(winner.rawValue)（\(supporting.count)/\(opinions.count) 支持，平均置信度 \(String(format: "%.0f", avgConfidence * 100))%）"
    }
    
    private func generateExecutionPlan(
        decision: CommitteeDecision,
        opinions: [MemberOpinion],
        request: CommitteeDecisionRequest
    ) -> CommitteeExecutionPlan? {
        guard decision == .proceed || decision == .replan else {
            return nil
        }
        
        // 合并所有建议的行动
        var allActions: [MemberOpinion.SuggestedAction] = []
        for opinion in opinions {
            allActions.append(contentsOf: opinion.suggestedActions)
        }
        
        // 按优先级排序
        let sortedActions = allActions.sorted {
            priorityOrder($0.priority) < priorityOrder($1.priority)
        }
        
        return CommitteeExecutionPlan(
            immediateActions: sortedActions.prefix(3).map { $0.description },
            safetyChecks: opinions.flatMap { $0.concerns }.map { $0.mitigation }.compactMap { $0 },
            fallbackPlan: "如执行失败，将触发用户确认",
            estimatedDuration: estimateDuration(sortedActions)
        )
    }
    
    private func mapToAction(_ decision: CommitteeDecision, opinions: [MemberOpinion]) -> RecommendedAction {
        switch decision {
        case .proceed:
            return .proceedWithCaution(safetyChecks: opinions.flatMap { $0.concerns.map { $0.description } })
        case .pause:
            return .pauseAndNotify(reason: "委员会建议暂停")
        case .escalate:
            return .escalateToUser(immediately: true, reason: "需要用户决策")
        case .replan:
            return .replanWithConstraints(constraints: ["基于委员会反馈调整"])
        case .abort:
            return .abortGracefully(reason: "委员会建议中止")
        case .requestMoreInfo:
            return .requestClarification(questions: ["需要更多信息才能继续"])
        case .delegateToUser:
            return .escalateToUser(immediately: false, reason: "建议委托给用户")
        }
    }
    
    private func priorityOrder(_ priority: MemberOpinion.SuggestedAction.ActionPriority) -> Int {
        switch priority {
        case .urgent: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        }
    }
    
    private func estimateDuration(_ actions: [MemberOpinion.SuggestedAction]) -> TimeInterval {
        // 估算执行时间
        return TimeInterval(actions.count * 30)  // 每个动作 30 秒
    }
    
    private func hasConflictingTools(_ tools: [String]) -> Bool {
        // 检查工具冲突
        let conflictPairs: [[String]] = [
            ["system.delete", "system.create"],
            ["browser.navigate", "browser.close"],
            ["whatsapp.send", "email.send"]
        ]
        
        for pair in conflictPairs {
            if tools.contains(pair[0]) && tools.contains(pair[1]) {
                return true
            }
        }
        return false
    }
    
    private func hasRecentFailures(_ state: WorkflowRunState) -> Bool {
        let recentCheckpoints = state.checkpoints.suffix(5)
        let failures = recentCheckpoints.filter { checkpoint in
            if case .stepFailed = checkpoint.kind {
                return true
            }
            return false
        }
        return failures.count >= 2
    }

    private func workflowState(from request: RequestPlan) -> WorkflowRunState? {
        let runID: String?

        switch request.primaryAction {
        case .continueWorkflowRun(let candidateRunID, _, _):
            runID = candidateRunID
        case .reflectWorkflowRun(let candidateRunID, _):
            runID = candidateRunID
        case .remindUserAboutWorkflow(let candidateRunID, _, _):
            runID = candidateRunID
        default:
            runID = request.selectedResources.workflowRunID ?? request.metadata["workflow_run_id"]
        }

        guard let runID else {
            return nil
        }
        return WorkflowRunCoordinator.shared.runState(runID: runID)
    }

    private func participatingMembers(for request: CommitteeDecisionRequest) -> [CommitteeMember] {
        var selected: [CommitteeMember] = []

        func appendMember(_ specialization: CommitteeMember.Specialization) {
            if let member = members.first(where: { $0.specialization == specialization }),
               !selected.contains(where: { $0.id == member.id }) {
                selected.append(member)
            }
        }

        appendMember(.general)
        appendMember(.security)
        appendMember(.automation)
        appendMember(.system)

        if request.context.dispatchAssignments.contains(where: { $0.kind == .browser }) {
            appendMember(.browser)
        }

        if request.context.committeeSignals.contains(where: {
            $0.triggerReason == .highRisk &&
            ($0.summary.contains("沟通") || $0.summary.contains("回复") || $0.summary.contains("发送"))
        }) ||
            request.query.localizedCaseInsensitiveContains("发送") ||
            request.query.localizedCaseInsensitiveContains("回复") ||
            request.query.localizedCaseInsensitiveContains("message") ||
            request.query.localizedCaseInsensitiveContains("reply") {
            appendMember(.communication)
        }

        return selected
    }

    private func summarizedResources(from resources: PlannerSelectedResources) -> String {
        var lines: [String] = []

        if let workflowRunID = resources.workflowRunID {
            lines.append("- workflow run: \(workflowRunID)")
        }
        if let browserSessionID = resources.browserSessionID {
            lines.append("- browser session: \(browserSessionID)")
        }
        if !resources.serviceIDs.isEmpty {
            lines.append("- services: \(resources.serviceIDs.joined(separator: ", "))")
        }
        if !resources.skillIDs.isEmpty {
            lines.append("- skills: \(resources.skillIDs.joined(separator: ", "))")
        }
        if !resources.agentIDs.isEmpty {
            lines.append("- agents: \(resources.agentIDs.joined(separator: ", "))")
        }
        if !resources.subtaskIDs.isEmpty {
            lines.append("- subtasks: \(resources.subtaskIDs.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Supporting Types

struct CommitteeSession: Identifiable {
    let id: String
    let startedAt: Date
    let request: CommitteeDecisionRequest
    var status: Status
    var endedAt: Date?
    var conclusion: CommitteeConclusion?
    
    enum Status {
        case gatheringOpinions
        case aggregating
        case completed
        case failed(Error)
    }
}

struct CommitteeConclusion {
    let decision: CommitteeDecision
    let consensusLevel: ConsensusLevel
    let summary: String
    let recommendedAction: RecommendedAction
    let memberOpinions: [MemberOpinion]
    let dissentNotes: [String]
    let executionPlan: CommitteeExecutionPlan?
    
    var requiresUserConfirmation: Bool {
        consensusLevel == .split || consensusLevel == .weak || decision == .escalate
    }
}

enum ConsensusLevel: String {
    case unanimous  // 全体一致
    case strong     // 强共识 (>=70%)
    case weak       // 弱共识 (>=50%)
    case split      // 分歧 (<50%)
    case emergency  // 紧急情况
}

enum RecommendedAction {
    case proceedWithCaution(safetyChecks: [String])
    case pauseAndNotify(reason: String)
    case escalateToUser(immediately: Bool, reason: String)
    case replanWithConstraints(constraints: [String])
    case abortGracefully(reason: String)
    case requestClarification(questions: [String])
}

struct CommitteeExecutionPlan {
    let immediateActions: [String]
    let safetyChecks: [String]
    let fallbackPlan: String
    let estimatedDuration: TimeInterval
}

// MARK: - Storage

final class CommitteeDecisionStore {
    static let shared = CommitteeDecisionStore()
    
    private let storageKey = "plannerCommittee.decisions"
    
    func save(_ record: CommitteeDecisionRecord) {
        var records = loadAll()
        records.insert(record, at: 0)
        
        // 只保留最近 100 条
        if records.count > 100 {
            records = Array(records.prefix(100))
        }
        
        // 保存到 UserDefaults
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    func loadRecent(limit: Int) -> [CommitteeDecisionRecord] {
        return Array(loadAll().prefix(limit))
    }
    
    private func loadAll() -> [CommitteeDecisionRecord] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return []
        }
        return (try? JSONDecoder().decode([CommitteeDecisionRecord].self, from: data)) ?? []
    }
}

struct CommitteeDecisionRecord: Codable {
    let id: String
    let timestamp: Date
    let triggerReason: String
    let decision: String
    let consensusLevel: String
    let summary: String
    let memberCount: Int
}

// MARK: - JSON Parsing

private struct OpinionJSON: Codable {
    let decision: String
    let confidence: Double
    let reasoning: String
    let suggestedActions: [MemberOpinion.SuggestedAction]
    let concerns: [MemberOpinion.Concern]
    let alternatives: [MemberOpinion.Alternative]
}

enum CommitteeError: Error {
    case parseFailed(String)
    case llmCallFailed(String)
    case insufficientOpinions
    case timeout
}
