//
//  TaskModels.swift
//  MacAssistant
//
//  任务管理模型 - 完整的ToDoList任务系统
//

import Foundation

/// 任务状态（扩展自SubtaskStatus）
enum TaskStatus: String, Codable, Equatable, CaseIterable {
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
    
    var icon: String {
        switch self {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
    
    var color: String {
        switch self {
        case .pending: return "gray"
        case .running: return "blue"
        case .paused: return "orange"
        case .completed: return "green"
        case .failed: return "red"
        }
    }
}

/// 任务日志条目
struct TaskLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let message: String
    let source: String?  // CLI输出来源
    
    enum LogLevel: String, Codable {
        case info = "info"
        case warning = "warning"
        case error = "error"
        case output = "output"  // CLI标准输出
    }
}

/// 任务消息（用于任务Agent对话）
struct TaskMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: TaskMessageRole
    let content: String
    let timestamp: Date
    let agentID: String?
    let agentName: String?
    
    enum TaskMessageRole: String, Codable {
        case user = "user"
        case assistant = "assistant"
        case system = "system"
        case cli = "cli"  // CLI输出
    }
}

/// 完整任务模型（扩展Subtask）
struct TaskItem: Identifiable, Codable, Equatable {
    let id: String
    let type: SubtaskType
    var title: String
    var description: String
    let parentTaskID: String?
    var status: TaskStatus
    let strategy: SubtaskStrategy
    var assignedAgentID: String?  // 选定的LLM/Agent
    var assignedAgentName: String?
    let inputContext: String
    var result: String?
    var executionTime: TimeInterval?
    var scheduledTime: Date?  // 计划执行时间
    var isPaused: Bool
    let createdAt: Date
    var updatedAt: Date
    
    // 任务对话历史
    var messages: [TaskMessage]
    
    // 任务日志
    var logs: [TaskLogEntry]
    
    // 日志文件路径
    var logFilePath: String?
    
    init(
        id: String? = nil,
        type: SubtaskType = .custom,
        title: String,
        description: String = "",
        parentTaskID: String? = nil,
        status: TaskStatus = .pending,
        strategy: SubtaskStrategy = .custom,
        assignedAgentID: String? = nil,
        assignedAgentName: String? = nil,
        inputContext: String = "",
        result: String? = nil,
        executionTime: TimeInterval? = nil,
        scheduledTime: Date? = nil,
        isPaused: Bool = false,
        messages: [TaskMessage] = [],
        logs: [TaskLogEntry] = []
    ) {
        self.id = id ?? UUID().uuidString
        self.type = type
        self.title = title
        self.description = description
        self.parentTaskID = parentTaskID
        self.status = status
        self.strategy = strategy
        self.assignedAgentID = assignedAgentID
        self.assignedAgentName = assignedAgentName
        self.inputContext = inputContext
        self.result = result
        self.executionTime = executionTime
        self.scheduledTime = scheduledTime
        self.isPaused = isPaused
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messages = messages
        self.logs = logs
        self.logFilePath = nil
    }
    
    mutating func updateStatus(_ newStatus: TaskStatus) {
        self.status = newStatus
        self.updatedAt = Date()
    }
    
    mutating func addMessage(_ message: TaskMessage) {
        self.messages.append(message)
        self.updatedAt = Date()
    }
    
    mutating func addLog(_ entry: TaskLogEntry) {
        self.logs.append(entry)
        self.updatedAt = Date()
    }
    
    mutating func assignAgent(id: String, name: String) {
        self.assignedAgentID = id
        self.assignedAgentName = name
        self.updatedAt = Date()
    }
    
    mutating func togglePause() {
        self.isPaused.toggle()
        self.status = isPaused ? .paused : .pending
        self.updatedAt = Date()
    }
    
    /// 检查任务是否可以清空（只有已完成任务可以清空）
    var canBeCleared: Bool {
        status == .completed || status == .failed
    }
    
    /// 检查任务是否可以暂停/销毁（待执行或执行中）
    var canBePausedOrDestroyed: Bool {
        status == .pending || status == .running
    }
}

// MARK: - 从Subtask转换
extension TaskItem {
    init(from subtask: Subtask) {
        self.id = subtask.id
        self.type = subtask.type
        self.title = subtask.title
        self.description = subtask.description
        self.parentTaskID = subtask.parentTaskID
        self.status = TaskStatus(rawValue: subtask.status.rawValue) ?? .pending
        self.strategy = subtask.strategy
        self.assignedAgentID = subtask.assignedAgentID
        self.assignedAgentName = nil
        self.inputContext = subtask.inputContext
        self.result = subtask.result
        self.executionTime = subtask.executionTime
        self.scheduledTime = nil
        self.isPaused = false
        self.createdAt = subtask.createdAt
        self.updatedAt = subtask.updatedAt
        self.messages = []
        self.logs = []
        self.logFilePath = nil
    }
}
