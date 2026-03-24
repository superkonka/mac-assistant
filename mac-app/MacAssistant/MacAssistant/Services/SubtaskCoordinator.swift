//
//  SubtaskCoordinator.swift
//  MacAssistant
//
//  子任务协调器 - 基于向量意图匹配的智能任务分解
//

import Foundation
import Combine

/// 内置服务类型
enum BuiltinServiceType: String, Codable, Equatable {
    case diskManager
    case localCLI
}

/// 子任务策略
enum SubtaskStrategy: Codable, Equatable {
    case useBuiltin(BuiltinServiceType)
    case useSkill(String)
    case useAgent(String)
    case useOpenClaw(String)
    case custom
    
    enum CodingKeys: String, CodingKey {
        case type, value
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .useBuiltin(let service):
            try container.encode("builtin", forKey: .type)
            try container.encode(String(describing: service), forKey: .value)
        case .useSkill(let name):
            try container.encode("skill", forKey: .type)
            try container.encode(name, forKey: .value)
        case .useAgent(let id):
            try container.encode("agent", forKey: .type)
            try container.encode(id, forKey: .value)
        case .useOpenClaw(let name):
            try container.encode("openclaw", forKey: .type)
            try container.encode(name, forKey: .value)
        case .custom:
            try container.encode("custom", forKey: .type)
            try container.encode("", forKey: .value)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let value = try container.decode(String.self, forKey: .value)
        
        switch type {
        case "builtin":
            // 从值恢复类型
            let serviceType: BuiltinServiceType = value == "diskManager" ? .diskManager : .localCLI
            self = .useBuiltin(serviceType)
        case "skill":
            self = .useSkill(value)
        case "agent":
            self = .useAgent(value)
        case "openclaw":
            self = .useOpenClaw(value)
        default:
            self = .custom
        }
    }
}

/// 子任务类型
enum SubtaskType: String, Codable, Equatable {
    case diskAnalysis = "disk_analysis"
    case diskCleanup = "disk_cleanup"
    case fileOperation = "file_operation"
    case codeAnalysis = "code_analysis"
    case codeGeneration = "code_generation"
    case codeReview = "code_review"
    case securityScan = "security_scan"
    case deployment = "deployment"
    case custom = "custom"
}

/// 子任务
struct Subtask: Identifiable, Codable, Equatable {
    let id: String
    let type: SubtaskType
    let title: String
    let description: String
    let parentTaskID: String?
    var status: SubtaskStatus
    let strategy: SubtaskStrategy
    let assignedAgentID: String?
    let inputContext: String
    var result: String?
    var executionTime: TimeInterval?
    let createdAt: Date
    var updatedAt: Date
    
    init(
        id: String? = nil,
        type: SubtaskType,
        title: String,
        description: String,
        parentTaskID: String? = nil,
        status: SubtaskStatus = .pending,
        strategy: SubtaskStrategy,
        assignedAgentID: String? = nil,
        inputContext: String,
        result: String? = nil,
        executionTime: TimeInterval? = nil
    ) {
        self.id = id ?? UUID().uuidString
        self.type = type
        self.title = title
        self.description = description
        self.parentTaskID = parentTaskID
        self.status = status
        self.strategy = strategy
        self.assignedAgentID = assignedAgentID
        self.inputContext = inputContext
        self.result = result
        self.executionTime = executionTime
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    func update(status: SubtaskStatus? = nil, result: String? = nil, executionTime: TimeInterval? = nil) -> Subtask {
        var new = self
        if let status = status {
            new.status = status
        }
        if let result = result {
            new.result = result
        }
        if let executionTime = executionTime {
            new.executionTime = executionTime
        }
        new.updatedAt = Date()
        return new
    }
}

/// 子任务状态
enum SubtaskStatus: String, Codable, Equatable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}

/// 任务分解结果
struct TaskDecomposition {
    let parentTaskID: String
    let subtasks: [Subtask]
    let confidence: Double
    let matchedCapabilities: [CapabilityVector]
}

struct SubtaskBlueprint: Identifiable, Equatable {
    let id: String
    let type: SubtaskType
    let title: String
    let description: String
    let strategy: SubtaskStrategy
    let assignedAgentID: String?
    let inputContext: String

    init(
        id: String = UUID().uuidString,
        type: SubtaskType,
        title: String,
        description: String,
        strategy: SubtaskStrategy,
        assignedAgentID: String? = nil,
        inputContext: String
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.description = description
        self.strategy = strategy
        self.assignedAgentID = assignedAgentID
        self.inputContext = inputContext
    }
}

enum SubtaskPlanningSignalKind: String, Codable, Equatable {
    case multiIntent
    case crossDomain
    case lowConfidence
    case externalCommunication
    case destructiveAction
    case longHorizon
}

struct SubtaskPlanningSignal: Codable, Equatable {
    let kind: SubtaskPlanningSignalKind
    let summary: String
    let severity: Double
}

struct SubtaskCapabilityEvidence: Identifiable, Codable, Equatable {
    let id: String
    let capabilityID: String
    let capabilityName: String
    let capabilityType: CapabilityVector.CapabilityType
    let score: Double
    let matchedKeywords: [String]

    init(match: IntentMatch) {
        self.id = match.capability.id
        self.capabilityID = match.capability.id
        self.capabilityName = match.capability.name
        self.capabilityType = match.capability.type
        self.score = match.score
        self.matchedKeywords = match.matchedKeywords
    }
}

struct SubtaskPlan: Equatable {
    let parentTaskID: String
    let blueprints: [SubtaskBlueprint]
    let confidence: Double
    let matchedCapabilities: [CapabilityVector]
    let shouldDecompose: Bool
    let planningReason: String
    let complexityScore: Double
    let capabilityEvidence: [SubtaskCapabilityEvidence]
    let signals: [SubtaskPlanningSignal]
}

@MainActor
final class SubtaskPlanningService {
    static let shared = SubtaskPlanningService()

    private let intentMatcher = IntentMatcher.shared

    private init() {}

    func planTask(_ request: String) -> SubtaskPlan {
        LogInfo("SubtaskPlanningService: 规划子任务 '\(request)'")

        let matches = intentMatcher.matchIntent(request, threshold: 0.3)
        let shouldDecompose = determineIfNeedsDecomposition(matches, request: request)
        let parentID = UUID().uuidString
        let capabilityEvidence = matches.map(SubtaskCapabilityEvidence.init(match:))
        let avgScore = matches.isEmpty ? 0 : matches.map { $0.score }.reduce(0, +) / Double(matches.count)
        let complexityScore = calculateComplexityScore(matches: matches, request: request, shouldDecompose: shouldDecompose)
        let signals = buildSignals(
            matches: matches,
            request: request,
            shouldDecompose: shouldDecompose,
            confidence: avgScore,
            complexityScore: complexityScore
        )

        let blueprints: [SubtaskBlueprint]
        let planningReason: String

        if shouldDecompose && matches.count > 1 {
            blueprints = matches.enumerated().map { index, match in
                createBlueprint(from: match, index: index, context: request)
            }
            planningReason = "检测到多个显著意图，拆成并行子任务。"
        } else if let bestMatch = matches.first {
            blueprints = [createBlueprint(from: bestMatch, index: 0, context: request)]
            planningReason = shouldDecompose
                ? "当前请求复杂度较高，但主意图较集中，先生成一个聚焦子任务。"
                : "主意图明确，生成单个子任务执行。"
        } else {
            blueprints = [createGenericBlueprint(context: request)]
            planningReason = "未命中明确能力，退回通用子任务。"
        }

        return SubtaskPlan(
            parentTaskID: parentID,
            blueprints: blueprints,
            confidence: avgScore,
            matchedCapabilities: matches.map { $0.capability },
            shouldDecompose: shouldDecompose,
            planningReason: planningReason,
            complexityScore: complexityScore,
            capabilityEvidence: capabilityEvidence,
            signals: signals
        )
    }

    func createBlueprints(from matches: [IntentMatch], request: String, parentTaskID: String? = nil) -> SubtaskPlan {
        let resolvedParentID = parentTaskID ?? UUID().uuidString
        let blueprints = matches.enumerated().map { index, match in
            createBlueprint(from: match, index: index, context: request)
        }
        let avgScore = matches.isEmpty ? 0 : matches.map { $0.score }.reduce(0, +) / Double(matches.count)
        let shouldDecompose = matches.count > 1
        let complexityScore = calculateComplexityScore(matches: matches, request: request, shouldDecompose: shouldDecompose)
        let capabilityEvidence = matches.map(SubtaskCapabilityEvidence.init(match:))
        let signals = buildSignals(
            matches: matches,
            request: request,
            shouldDecompose: shouldDecompose,
            confidence: avgScore,
            complexityScore: complexityScore
        )

        return SubtaskPlan(
            parentTaskID: resolvedParentID,
            blueprints: blueprints.isEmpty ? [createGenericBlueprint(context: request)] : blueprints,
            confidence: avgScore,
            matchedCapabilities: matches.map { $0.capability },
            shouldDecompose: shouldDecompose,
            planningReason: matches.isEmpty ? "未命中意图，使用通用子任务。" : "根据给定意图匹配创建子任务蓝图。",
            complexityScore: complexityScore,
            capabilityEvidence: capabilityEvidence,
            signals: signals
        )
    }

    private func determineIfNeedsDecomposition(_ matches: [IntentMatch], request: String) -> Bool {
        let significantMatches = matches.filter { $0.score > 0.5 }
        if significantMatches.count > 1 {
            return true
        }

        if let first = matches.first, first.score < 0.6 {
            return true
        }

        let complexityIndicators = ["然后", "再", "接着", "第一步", "第二步", "同时", "并且", "另外", "还需要"]
        if complexityIndicators.contains(where: request.contains) {
            return true
        }

        if request.count > 100 {
            return true
        }

        return false
    }

    private func calculateComplexityScore(
        matches: [IntentMatch],
        request: String,
        shouldDecompose: Bool
    ) -> Double {
        var score = shouldDecompose ? 0.55 : 0.25

        let significantMatches = matches.filter { $0.score > 0.5 }
        score += min(Double(significantMatches.count) * 0.12, 0.24)

        let capabilityTypes = Set(matches.map { $0.capability.type.rawValue })
        if capabilityTypes.count > 1 {
            score += 0.12
        }

        let sequentialMarkers = ["然后", "再", "接着", "第一步", "第二步", "同时", "并且", "另外", "还需要"]
        if sequentialMarkers.contains(where: request.contains) {
            score += 0.08
        }

        if request.count > 100 {
            score += 0.1
        } else if request.count > 60 {
            score += 0.05
        }

        return min(score, 1.0)
    }

    private func buildSignals(
        matches: [IntentMatch],
        request: String,
        shouldDecompose: Bool,
        confidence: Double,
        complexityScore: Double
    ) -> [SubtaskPlanningSignal] {
        guard !matches.isEmpty else {
            return confidence == 0 ? [
                SubtaskPlanningSignal(
                    kind: .lowConfidence,
                    summary: "未命中明确能力，当前拆解只能回退到通用子任务。",
                    severity: 0.72
                )
            ] : []
        }

        var signals: [SubtaskPlanningSignal] = []
        let normalized = RequestPlanningHeuristics.normalized(request)
        let capabilityTypes = Set(matches.map { $0.capability.type.rawValue })
        let significantMatches = matches.filter { $0.score > 0.5 }

        if shouldDecompose && significantMatches.count > 1 {
            signals.append(
                SubtaskPlanningSignal(
                    kind: .multiIntent,
                    summary: "检测到多个显著意图，需要拆成独立执行单元。",
                    severity: min(0.55 + Double(significantMatches.count) * 0.08, 0.92)
                )
            )
        }

        if capabilityTypes.count > 1 {
            signals.append(
                SubtaskPlanningSignal(
                    kind: .crossDomain,
                    summary: "当前拆解跨越多个执行域，需要 Planner 协调资源边界。",
                    severity: min(0.6 + Double(capabilityTypes.count - 1) * 0.08, 0.9)
                )
            )
        }

        let communicationMarkers = ["发送", "回复", "通知", "消息", "send", "reply", "message", "notify"]
        if communicationMarkers.contains(where: { normalized.contains($0) }) {
            signals.append(
                SubtaskPlanningSignal(
                    kind: .externalCommunication,
                    summary: "请求包含外部沟通动作，建议在发送前保留审批或确认边界。",
                    severity: 0.82
                )
            )
        }

        let destructiveMarkers = ["删除", "移除", "清理", "重启", "停止", "delete", "remove", "cleanup", "restart", "stop"]
        let destructiveCapabilityIDs = ["disk_manager_cleanup", "file_operations"]
        if destructiveMarkers.contains(where: { normalized.contains($0) }) ||
            matches.contains(where: { destructiveCapabilityIDs.contains($0.capability.id) }) {
            signals.append(
                SubtaskPlanningSignal(
                    kind: .destructiveAction,
                    summary: "请求包含潜在破坏性动作，执行前应确认范围和回滚策略。",
                    severity: 0.88
                )
            )
        }

        if confidence > 0, confidence < 0.45 {
            signals.append(
                SubtaskPlanningSignal(
                    kind: .lowConfidence,
                    summary: "意图匹配整体置信度偏低，拆解结果需要专家组复核。",
                    severity: 1.0 - confidence
                )
            )
        }

        if complexityScore > 0.72 || matches.count >= 4 || request.count > 120 {
            signals.append(
                SubtaskPlanningSignal(
                    kind: .longHorizon,
                    summary: "请求跨度较长或步骤较多，适合交给 Planner 持续监控和重规划。",
                    severity: complexityScore
                )
            )
        }

        return signals
    }

    private func createBlueprint(from match: IntentMatch, index: Int, context: String) -> SubtaskBlueprint {
        let capability = match.capability

        let (type, strategy, agentID): (SubtaskType, SubtaskStrategy, String?) = {
            switch capability.type {
            case .builtin:
                if capability.id.contains("disk") && capability.id.contains("analyze") {
                    return (.diskAnalysis, .useBuiltin(.diskManager), nil)
                } else if capability.id.contains("cleanup") {
                    return (.diskCleanup, .useBuiltin(.localCLI), nil)
                } else if capability.id.contains("resource") {
                    return (.diskAnalysis, .useBuiltin(.localCLI), nil)
                } else if capability.id.contains("file") {
                    return (.fileOperation, .useBuiltin(.localCLI), nil)
                } else {
                    return (.custom, .useBuiltin(.localCLI), nil)
                }

            case .skill:
                let skillName = capability.id.replacingOccurrences(of: "skill_", with: "")
                let type: SubtaskType = skillName.contains("code") ? .codeAnalysis :
                    skillName.contains("security") ? .securityScan :
                    skillName.contains("deploy") ? .deployment : .custom
                return (type, .useSkill(skillName), nil)

            case .agent:
                let agentID = capability.id.replacingOccurrences(of: "agent_", with: "")
                return (.codeAnalysis, .useAgent(agentID), agentID)

            case .openClawSkill:
                let skillName = capability.id.replacingOccurrences(of: "openclaw_", with: "")
                return (.securityScan, .useOpenClaw(skillName), nil)
            }
        }()

        return SubtaskBlueprint(
            type: type,
            title: "\(index + 1). \(capability.name)",
            description: "\(capability.description) (匹配度: \(String(format: "%.0f", match.score * 100))%)",
            strategy: strategy,
            assignedAgentID: agentID,
            inputContext: context
        )
    }

    private func createGenericBlueprint(context: String) -> SubtaskBlueprint {
        SubtaskBlueprint(
            type: .custom,
            title: "处理请求",
            description: "通用处理",
            strategy: .custom,
            inputContext: context
        )
    }
}

@MainActor
final class SubtaskCoordinator: ObservableObject {
    static let shared = SubtaskCoordinator()
    
    // 三态任务列表
    @Published private(set) var pendingSubtasks: [Subtask] = []
    @Published private(set) var runningSubtasks: [Subtask] = []
    @Published private(set) var completedSubtasks: [Subtask] = []
    
    // 向后兼容
    var activeSubtasks: [Subtask] { pendingSubtasks + runningSubtasks }
    
    @Published private(set) var isProcessing = false
    
    private let unifiedTaskManager = UnifiedTaskManager.shared
    private var linkedUnifiedTaskIDs: [String: String] = [:]
    
    private init() {}
    
    // MARK: - 核心方法
    
    /// 兼容入口：任务拆解规划已经迁到 SubtaskPlanningService
    func decomposeTask(_ request: String) -> TaskDecomposition {
        LogWarning("SubtaskCoordinator.decomposeTask 已退化为兼容入口，请优先使用 SubtaskPlanningService + enqueuePlan")
        let plan = SubtaskPlanningService.shared.planTask(request)
        return enqueuePlan(plan)
    }
    
    /// 从意图匹配结果创建子任务
    func createSubtasksFromIntents(_ matches: [IntentMatch], request: String) -> [Subtask] {
        let plan = SubtaskPlanningService.shared.createBlueprints(from: matches, request: request)
        return enqueuePlan(plan).subtasks
    }

    func enqueuePlan(_ plan: SubtaskPlan) -> TaskDecomposition {
        isProcessing = true
        defer { isProcessing = false }

        let subtasks = plan.blueprints.map { blueprint in
            createSubtask(from: blueprint, parentID: plan.parentTaskID)
        }

        addSubtasks(subtasks)

        LogInfo(
            "SubtaskCoordinator: 接收规划结果，生成 \(subtasks.count) 个子任务，平均置信度 \(String(format: "%.2f", plan.confidence))，原因: \(plan.planningReason)"
        )

        return TaskDecomposition(
            parentTaskID: plan.parentTaskID,
            subtasks: subtasks,
            confidence: plan.confidence,
            matchedCapabilities: plan.matchedCapabilities
        )
    }
    
    // MARK: - 子任务生命周期
    
    func addSubtasks(_ subtasks: [Subtask]) {
        for subtask in subtasks {
            switch subtask.status {
            case .pending:
                pendingSubtasks.append(subtask)
            case .running:
                runningSubtasks.append(subtask)
            case .completed, .failed:
                completedSubtasks.append(subtask)
            case .cancelled:
                break
            }
        }

        // 同步到统一任务系统，保留映射关系用于后续状态更新
        for subtask in subtasks {
            let unifiedTask = unifiedTaskManager.createSmartSubtask(
                title: subtask.title,
                description: subtask.description,
                inputContext: subtask.inputContext,
                strategy: strategy(from: subtask.strategy),
                parentTaskID: subtask.parentTaskID
            )
            linkedUnifiedTaskIDs[subtask.id] = unifiedTask.id
        }
    }
    
    func updateSubtask(id: String, status: SubtaskStatus? = nil, result: String? = nil) {
        // 在pending中查找
        if let index = pendingSubtasks.firstIndex(where: { $0.id == id }) {
            let oldStatus = pendingSubtasks[index].status
            let updated = pendingSubtasks[index].update(status: status, result: result)
            
            // 如果状态发生变化，发送通知
            if let newStatus = status, oldStatus != newStatus {
                notifySubtaskStatusChange(subtask: updated, oldStatus: oldStatus)
                syncTaskStatus(subtask: updated)
                
                // 状态变更时移动任务
                moveTask(updated, from: &pendingSubtasks, toStatus: newStatus)
            } else {
                pendingSubtasks[index] = updated
            }
            return
        }
        
        // 在running中查找
        if let index = runningSubtasks.firstIndex(where: { $0.id == id }) {
            let oldStatus = runningSubtasks[index].status
            let updated = runningSubtasks[index].update(status: status, result: result)
            
            if let newStatus = status, oldStatus != newStatus {
                notifySubtaskStatusChange(subtask: updated, oldStatus: oldStatus)
                syncTaskStatus(subtask: updated)
                
                moveTask(updated, from: &runningSubtasks, toStatus: newStatus)
            } else {
                runningSubtasks[index] = updated
            }
            return
        }
    }
    
    /// 移动任务到对应状态列表
    private func moveTask(_ task: Subtask, from sourceList: inout [Subtask], toStatus: SubtaskStatus) {
        // 从源列表移除
        sourceList.removeAll { $0.id == task.id }
        
        // 添加到目标列表
        switch toStatus {
        case .pending:
            pendingSubtasks.append(task)
        case .running:
            runningSubtasks.append(task)
        case .completed, .failed:
            completedSubtasks.append(task)
        case .cancelled:
            break
        }
    }
    
    /// 同步子任务状态到TaskManager
    private func syncTaskStatus(subtask: Subtask) {
        guard let unifiedTaskID = linkedUnifiedTaskIDs[subtask.id] else { return }

        switch subtask.status {
        case .completed:
            unifiedTaskManager.completeTask(id: unifiedTaskID, result: subtask.result ?? "任务完成")
        case .failed:
            unifiedTaskManager.failTask(id: unifiedTaskID, error: subtask.result ?? "执行失败")
        case .running:
            Task { @MainActor in
                await unifiedTaskManager.startTask(id: unifiedTaskID)
            }
        case .pending:
            Task { @MainActor in
                await unifiedTaskManager.retryTask(id: unifiedTaskID)
            }
        default:
            break
        }
    }
    
    /// 通知子任务状态变化
    private func notifySubtaskStatusChange(subtask: Subtask, oldStatus: SubtaskStatus) {
        // 只通知重要的状态变化
        switch subtask.status {
        case .completed, .failed:
            LogInfo("[SubtaskCoordinator] 子任务 \(subtask.status.rawValue): \(subtask.title)")
            
            // 发送通知到主对话
            NotificationCenter.default.post(
                name: NSNotification.Name("SubtaskStatusChanged"),
                object: subtask.id,
                userInfo: [
                    "title": subtask.title,
                    "status": subtask.status.rawValue,
                    "description": subtask.description,
                    "result": subtask.result ?? "",
                    "parentTaskID": subtask.parentTaskID ?? ""
                ]
            )
        default:
            break
        }
    }
    
    func clearCompletedSubtasks() {
        let completedIDs = Set(completedSubtasks.map(\.id))
        completedSubtasks.removeAll()
        linkedUnifiedTaskIDs = linkedUnifiedTaskIDs.filter { !completedIDs.contains($0.key) }
    }

    func unifiedTaskID(forSubtaskID subtaskID: String) -> String? {
        linkedUnifiedTaskIDs[subtaskID]
    }
    
    // MARK: - 私有方法

    private func createSubtask(from blueprint: SubtaskBlueprint, parentID: String) -> Subtask {
        Subtask(
            id: blueprint.id,
            type: blueprint.type,
            title: blueprint.title,
            description: blueprint.description,
            parentTaskID: parentID,
            strategy: blueprint.strategy,
            assignedAgentID: blueprint.assignedAgentID,
            inputContext: blueprint.inputContext
        )
    }

    private func strategy(from strategy: SubtaskStrategy) -> TaskExecutionStrategy {
        switch strategy {
        case .useBuiltin:
            return .useBuiltin
        case .useSkill(let skillID):
            return .useSkill(skillID)
        case .useAgent(let agentID):
            return .useAgent(agentID)
        case .useOpenClaw(let agentID):
            return .useOpenClaw(agentID)
        case .custom:
            return .auto
        }
    }
}
