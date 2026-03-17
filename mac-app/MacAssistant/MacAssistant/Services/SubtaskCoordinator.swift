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

@MainActor
final class SubtaskCoordinator: ObservableObject {
    static let shared = SubtaskCoordinator()
    
    @Published private(set) var activeSubtasks: [Subtask] = []
    @Published private(set) var completedSubtasks: [Subtask] = []
    @Published private(set) var isProcessing = false
    
    private let intentMatcher = IntentMatcher.shared
    private let embeddingService = VectorEmbeddingService.shared
    private let taskManager = TaskManager.shared
    
    private init() {}
    
    // MARK: - 核心方法
    
    /// 智能任务分解 - 基于向量意图匹配
    func decomposeTask(_ request: String) -> TaskDecomposition {
        isProcessing = true
        defer { isProcessing = false }
        
        LogInfo("SubtaskCoordinator: 分解任务 '\(request)'")
        
        // 1. 多意图检测
        let matches = intentMatcher.matchIntent(request, threshold: 0.3)
        
        // 2. 判断是否需要拆解
        let shouldDecompose = determineIfNeedsDecomposition(matches, request: request)
        
        let parentID = UUID().uuidString
        
        let subtasks: [Subtask]
        if shouldDecompose && matches.count > 1 {
            // 多意图 - 创建多个子任务
            subtasks = matches.enumerated().map { index, match in
                createSubtask(from: match, index: index, parentID: parentID, context: request)
            }
        } else if let bestMatch = matches.first {
            // 单一强意图 - 单个子任务
            subtasks = [createSubtask(from: bestMatch, index: 0, parentID: parentID, context: request)]
        } else {
            // 无匹配 - 通用子任务
            subtasks = [createGenericSubtask(parentID: parentID, context: request)]
        }
        
        // 3. 保存并返回
        addSubtasks(subtasks)
        
        let avgScore = matches.isEmpty ? 0 : matches.map { $0.score }.reduce(0, +) / Double(matches.count)
        
        LogInfo("SubtaskCoordinator: 生成 \(subtasks.count) 个子任务，平均置信度 \(String(format: "%.2f", avgScore))")
        
        return TaskDecomposition(
            parentTaskID: parentID,
            subtasks: subtasks,
            confidence: avgScore,
            matchedCapabilities: matches.map { $0.capability }
        )
    }
    
    /// 从意图匹配结果创建子任务
    func createSubtasksFromIntents(_ matches: [IntentMatch], request: String) -> [Subtask] {
        let parentID = UUID().uuidString
        return matches.enumerated().map { index, match in
            createSubtask(from: match, index: index, parentID: parentID, context: request)
        }
    }
    
    // MARK: - 子任务生命周期
    
    func addSubtasks(_ subtasks: [Subtask]) {
        activeSubtasks.append(contentsOf: subtasks)
        
        // 同时创建TaskItem并添加到TaskManager
        for subtask in subtasks {
            let taskItem = TaskItem(from: subtask)
            taskManager.addTask(taskItem)
        }
    }
    
    func updateSubtask(id: String, status: SubtaskStatus? = nil, result: String? = nil) {
        if let index = activeSubtasks.firstIndex(where: { $0.id == id }) {
            let oldStatus = activeSubtasks[index].status
            let updated = activeSubtasks[index].update(status: status, result: result)
            activeSubtasks[index] = updated
            
            // 如果状态发生变化，发送通知
            if let newStatus = status, oldStatus != newStatus {
                notifySubtaskStatusChange(subtask: updated, oldStatus: oldStatus)
                
                // 同步更新TaskManager中的任务状态
                syncTaskStatus(subtask: updated)
            }
            
            // 如果完成，移动到已完成列表
            if status == .completed || status == .failed {
                completedSubtasks.append(updated)
                activeSubtasks.remove(at: index)
            }
        }
    }
    
    /// 同步子任务状态到TaskManager
    private func syncTaskStatus(subtask: Subtask) {
        switch subtask.status {
        case .completed:
            if let runningTask = taskManager.runningTasks.first(where: { $0.id == subtask.id }) {
                taskManager.completeTask(subtask.id, result: subtask.result ?? "任务完成")
            }
        case .failed:
            if let runningTask = taskManager.runningTasks.first(where: { $0.id == subtask.id }) {
                taskManager.failTask(subtask.id, error: subtask.result ?? "执行失败")
            }
        case .running:
            if let pendingTask = taskManager.pendingTasks.first(where: { $0.id == subtask.id }) {
                taskManager.startTask(subtask.id)
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
        completedSubtasks.removeAll()
    }
    
    // MARK: - 私有方法
    
    private func determineIfNeedsDecomposition(_ matches: [IntentMatch], request: String) -> Bool {
        // 1. 多个显著意图（分数都较高）
        let significantMatches = matches.filter { $0.score > 0.5 }
        if significantMatches.count > 1 {
            return true
        }
        
        // 2. 低置信度单一意图
        if let first = matches.first, first.score < 0.6 {
            return true
        }
        
        // 3. 复杂请求特征
        let complexityIndicators = ["然后", "再", "接着", "第一步", "第二步", "同时", "并且", "另外", "还需要"]
        if complexityIndicators.contains(where: request.contains) {
            return true
        }
        
        // 4. 请求长度
        if request.count > 100 {
            return true
        }
        
        return false
    }
    
    private func createSubtask(from match: IntentMatch, index: Int, parentID: String, context: String) -> Subtask {
        let capability = match.capability
        
        // 根据能力类型确定子任务类型和策略
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
        
        return Subtask(
            type: type,
            title: "\(index + 1). \(capability.name)",
            description: "\(capability.description) (匹配度: \(String(format: "%.0f", match.score * 100))%)",
            parentTaskID: parentID,
            strategy: strategy,
            assignedAgentID: agentID,
            inputContext: context
        )
    }
    
    private func createGenericSubtask(parentID: String, context: String) -> Subtask {
        return Subtask(
            type: .custom,
            title: "处理请求",
            description: "通用处理",
            parentTaskID: parentID,
            strategy: .custom,
            inputContext: context
        )
    }
}
