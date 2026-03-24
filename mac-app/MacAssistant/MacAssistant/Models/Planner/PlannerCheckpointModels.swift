//
//  PlannerCheckpointModels.swift
//  MacAssistant
//
//  Planner 决策检查点模型
//

import Foundation

/// Planner 决策检查点
struct PlannerCheckpoint: Identifiable, Codable, Equatable {
    let id: String
    let timestamp: Date
    let plannerType: PlannerType
    let workflowRunID: String?
    
    // 决策记录
    let previousDecision: String?
    let newDecision: String
    let reason: String
    let confidence: Double
    
    // 触发信息
    let trigger: WakeUpTrigger
    let contextSummary: String
    
    // 模型信息
    let modelUsed: String
    let tokensConsumed: Int
    let latencyMs: Int
    
    enum PlannerType: String, Codable {
        case intake          // 初始意图分析
        case runtime         // 运行时规划
        case reflection      // 反思规划
        case committee       // 专家委员会
    }
    
    enum WakeUpTrigger: String, Codable {
        // 事件驱动
        case browserPageChanged
        case newMessageReceived
        case taskFailed
        case serviceStatusChanged
        case userAction
        
        // 周期巡检
        case periodicLightCheck
        
        // 重度会诊
        case lowConfidence
        case highRiskAction
        case longBlocked
        case highValueOpportunity
        
        // 手动
        case manual
    }
    
    init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        plannerType: PlannerType,
        workflowRunID: String? = nil,
        previousDecision: String? = nil,
        newDecision: String,
        reason: String,
        confidence: Double,
        trigger: WakeUpTrigger,
        contextSummary: String,
        modelUsed: String,
        tokensConsumed: Int = 0,
        latencyMs: Int = 0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.plannerType = plannerType
        self.workflowRunID = workflowRunID
        self.previousDecision = previousDecision
        self.newDecision = newDecision
        self.reason = reason
        self.confidence = confidence
        self.trigger = trigger
        self.contextSummary = contextSummary
        self.modelUsed = modelUsed
        self.tokensConsumed = tokensConsumed
        self.latencyMs = latencyMs
    }
}

/// Reflection 决策结果
enum ReflectionDecision {
    case noop                              // 无需操作
    case remind(String, Priority)          // 提醒用户
    case replan(String)                    // 重新规划
    case resume(String)                    // 恢复执行
    case escalate(String)                  // 升级处理
    
    var actionDescription: String {
        switch self {
        case .noop:
            return "无需操作"
        case .remind(let reason, let priority):
            return "提醒用户(\(priority)): \(reason)"
        case .replan(let reason):
            return "重新规划: \(reason)"
        case .resume(let reason):
            return "恢复执行: \(reason)"
        case .escalate(let reason):
            return "升级处理: \(reason)"
        }
    }
    
    var requiresUserNotification: Bool {
        switch self {
        case .noop:
            return false
        case .remind(_, let priority):
            return priority == .high || priority == .critical
        case .replan, .resume, .escalate:
            return true
        }
    }
}

/// Planner 检查点存储
@MainActor
final class PlannerCheckpointStore {
    static let shared = PlannerCheckpointStore()
    
    private var checkpoints: [PlannerCheckpoint] = []
    private let maxCheckpoints = 1000
    
    private init() {}
    
    func record(_ checkpoint: PlannerCheckpoint) {
        checkpoints.append(checkpoint)
        
        // 限制存储数量
        if checkpoints.count > maxCheckpoints {
            checkpoints.removeFirst(checkpoints.count - maxCheckpoints)
        }
        
        LogInfo("[PlannerCheckpointStore] 记录检查点: \(checkpoint.plannerType.rawValue) -> \(checkpoint.newDecision)")
    }
    
    func checkpoints(for workflowRunID: String) -> [PlannerCheckpoint] {
        checkpoints.filter { $0.workflowRunID == workflowRunID }
    }
    
    func checkpoints(for plannerType: PlannerCheckpoint.PlannerType) -> [PlannerCheckpoint] {
        checkpoints.filter { $0.plannerType == plannerType }
    }
    
    func recentCheckpoints(limit: Int = 50) -> [PlannerCheckpoint] {
        Array(checkpoints.suffix(limit).reversed())
    }
    
    func statistics() -> (total: Int, byType: [String: Int]) {
        let byType = Dictionary(grouping: checkpoints) { $0.plannerType.rawValue }
            .mapValues { $0.count }
        return (total: checkpoints.count, byType: byType)
    }
    
    func clearOldCheckpoints(olderThan days: Int = 7) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        checkpoints.removeAll { $0.timestamp < cutoffDate }
    }
}
