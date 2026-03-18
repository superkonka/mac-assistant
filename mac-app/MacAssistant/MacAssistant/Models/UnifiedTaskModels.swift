//
//  UnifiedTaskModels.swift
//  MacAssistant
//
//  统一任务管理模型 - 整合异常恢复、子任务、ToDoList
//

import Foundation

/// 统一任务类型
enum UnifiedTaskType: String, Codable, Equatable, CaseIterable {
    case exceptionRecovery = "exception_recovery"  // 异常恢复任务
    case smartSubtask = "smart_subtask"           // 智能子任务
    case todo = "todo"                            // 待办任务
    case background = "background"                // 后台任务
    
    var displayName: String {
        switch self {
        case .exceptionRecovery: return "异常恢复"
        case .smartSubtask: return "智能子任务"
        case .todo: return "待办"
        case .background: return "后台任务"
        }
    }
    
    var icon: String {
        switch self {
        case .exceptionRecovery: return "arrow.counterclockwise.circle"
        case .smartSubtask: return "brain"
        case .todo: return "checklist"
        case .background: return "clock.arrow.circlepath"
        }
    }
}

/// 统一任务状态（五态模型）
enum UnifiedTaskStatus: String, Codable, Equatable, CaseIterable {
    case pending = "pending"       // 待执行
    case running = "running"       // 执行中
    case paused = "paused"         // 已暂停
    case completed = "completed"   // 已完成
    case failed = "failed"         // 失败
    
    var displayName: String {
        switch self {
        case .pending: return "待执行"
        case .running: return "执行中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }
    
    var color: String {
        switch self {
        case .pending: return "secondary"
        case .running: return "blue"
        case .paused: return "orange"
        case .completed: return "green"
        case .failed: return "red"
        }
    }
    
    var isActive: Bool {
        self == .pending || self == .running || self == .paused
    }
    
    var canResume: Bool {
        self == .pending || self == .paused || self == .failed
    }
}

/// 统一任务模型
struct UnifiedTask: Identifiable, Codable, Equatable {
    let id: String
    var type: UnifiedTaskType
    var title: String
    var description: String
    var status: UnifiedTaskStatus
    
    // 执行相关
    var assignedAgentID: String?
    var assignedAgentName: String?
    var strategy: TaskExecutionStrategy
    
    // 内容相关
    var inputContext: String          // 原始请求/输入
    var result: String?               // 执行结果
    var errorMessage: String?         // 错误信息
    
    // 对话历史（异常恢复和子任务使用）
    var messages: [TaskMessage]
    
    // 日志（后台任务使用）
    var logs: [TaskLogEntry]
    
    // 异常恢复专用字段
    var canResume: Bool
    var gatewaySessionKey: String?    // OpenClaw会话Key
    var originalRequest: String?      // 原始请求（异常恢复用）
    
    // 时间相关
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var scheduledTime: Date?          // 计划执行时间
    
    // 统计
    var executionTime: TimeInterval?
    var retryCount: Int
    var maxRetries: Int
    
    // 父子任务关系
    var parentTaskID: String?
    var subtaskIDs: [String]
    
    // UI状态（不持久化）
    var isExpanded: Bool
    var isSelected: Bool
    
    init(
        id: String? = nil,
        type: UnifiedTaskType,
        title: String,
        description: String = "",
        status: UnifiedTaskStatus = .pending,
        assignedAgentID: String? = nil,
        assignedAgentName: String? = nil,
        strategy: TaskExecutionStrategy = .auto,
        inputContext: String = "",
        result: String? = nil,
        errorMessage: String? = nil,
        messages: [TaskMessage] = [],
        logs: [TaskLogEntry] = [],
        canResume: Bool = true,
        gatewaySessionKey: String? = nil,
        originalRequest: String? = nil,
        scheduledTime: Date? = nil,
        parentTaskID: String? = nil,
        maxRetries: Int = 3
    ) {
        self.id = id ?? UUID().uuidString
        self.type = type
        self.title = title
        self.description = description
        self.status = status
        self.assignedAgentID = assignedAgentID
        self.assignedAgentName = assignedAgentName
        self.strategy = strategy
        self.inputContext = inputContext
        self.result = result
        self.errorMessage = errorMessage
        self.messages = messages
        self.logs = logs
        self.canResume = canResume
        self.gatewaySessionKey = gatewaySessionKey
        self.originalRequest = originalRequest
        self.createdAt = Date()
        self.updatedAt = Date()
        self.scheduledTime = scheduledTime
        self.parentTaskID = parentTaskID
        self.subtaskIDs = []
        self.retryCount = 0
        self.maxRetries = maxRetries
        self.isExpanded = false
        self.isSelected = false
    }
    
    // MARK: - 便捷初始化
    
    /// 创建异常恢复任务
    static func exceptionRecovery(
        title: String,
        originalRequest: String,
        errorMessage: String,
        gatewaySessionKey: String
    ) -> UnifiedTask {
        UnifiedTask(
            type: .exceptionRecovery,
            title: title,
            description: "请求处理中断，点击继续处理重试",
            status: .pending,
            strategy: .exceptionRecovery,
            inputContext: originalRequest,
            errorMessage: errorMessage,
            canResume: true,
            gatewaySessionKey: gatewaySessionKey,
            originalRequest: originalRequest
        )
    }
    
    /// 创建智能子任务
    static func smartSubtask(
        title: String,
        description: String,
        inputContext: String,
        strategy: TaskExecutionStrategy
    ) -> UnifiedTask {
        UnifiedTask(
            type: .smartSubtask,
            title: title,
            description: description,
            status: .pending,
            strategy: strategy,
            inputContext: inputContext
        )
    }
    
    /// 创建待办任务
    static func todo(
        title: String,
        description: String = "",
        scheduledTime: Date? = nil
    ) -> UnifiedTask {
        UnifiedTask(
            type: .todo,
            title: title,
            description: description,
            status: .pending,
            strategy: .manual,
            scheduledTime: scheduledTime
        )
    }
    
    // MARK: - 状态变更
    
    mutating func start() {
        status = .running
        startedAt = Date()
        updatedAt = Date()
    }
    
    mutating func complete(result: String) {
        status = .completed
        self.result = result
        completedAt = Date()
        updatedAt = Date()
        if let start = startedAt {
            executionTime = Date().timeIntervalSince(start)
        }
    }
    
    mutating func fail(error: String) {
        status = .failed
        errorMessage = error
        updatedAt = Date()
        retryCount += 1
    }
    
    mutating func pause() {
        status = .paused
        updatedAt = Date()
    }
    
    mutating func resume() {
        status = .pending
        updatedAt = Date()
    }
    
    mutating func addMessage(_ message: TaskMessage) {
        messages.append(message)
        updatedAt = Date()
    }
    
    mutating func addLog(_ entry: TaskLogEntry) {
        logs.append(entry)
        updatedAt = Date()
    }
}

/// 任务执行策略类型
enum TaskExecutionStrategyType: String, Codable, Equatable, CaseIterable {
    case auto = "auto"
    case useBuiltin = "useBuiltin"
    case useSkill = "useSkill"
    case useAgent = "useAgent"
    case useOpenClaw = "useOpenClaw"
    case exceptionRecovery = "exceptionRecovery"
    case manual = "manual"
    
    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .useBuiltin: return "本地服务"
        case .useSkill: return "Skill"
        case .useAgent: return "Agent"
        case .useOpenClaw: return "OpenClaw"
        case .exceptionRecovery: return "异常恢复"
        case .manual: return "手动"
        }
    }
}

/// 任务执行策略
struct TaskExecutionStrategy: Codable, Equatable {
    let type: TaskExecutionStrategyType
    let targetID: String?  // 用于useSkill, useAgent, useOpenClaw
    
    static let auto = TaskExecutionStrategy(type: .auto, targetID: nil)
    static let useBuiltin = TaskExecutionStrategy(type: .useBuiltin, targetID: nil)
    static let exceptionRecovery = TaskExecutionStrategy(type: .exceptionRecovery, targetID: nil)
    static let manual = TaskExecutionStrategy(type: .manual, targetID: nil)
    
    static func useSkill(_ id: String) -> TaskExecutionStrategy {
        TaskExecutionStrategy(type: .useSkill, targetID: id)
    }
    
    static func useAgent(_ id: String) -> TaskExecutionStrategy {
        TaskExecutionStrategy(type: .useAgent, targetID: id)
    }
    
    static func useOpenClaw(_ id: String) -> TaskExecutionStrategy {
        TaskExecutionStrategy(type: .useOpenClaw, targetID: id)
    }
    
    var displayName: String {
        type.displayName
    }
}

/// 任务筛选器
enum TaskFilter: String, CaseIterable {
    case all = "全部"
    case pending = "待执行"
    case running = "执行中"
    case completed = "已完成"
    case exception = "异常恢复"
    
    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .pending: return "hourglass"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle"
        case .exception: return "arrow.counterclockwise"
        }
    }
}

/// 任务统计
struct TaskStatistics: Codable, Equatable {
    var total: Int
    var pending: Int
    var running: Int
    var paused: Int
    var completed: Int
    var failed: Int
    
    var completionRate: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
    
    var failureRate: Double {
        guard total > 0 else { return 0 }
        return Double(failed) / Double(total)
    }
}
