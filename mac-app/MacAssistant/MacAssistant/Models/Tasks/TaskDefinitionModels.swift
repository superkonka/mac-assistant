//
//  TaskDefinitionModels.swift
//  MacAssistant
//
//  新任务系统定义模型
//

import Foundation

enum TaskDefinitionKind: String, Codable, Equatable, CaseIterable {
    case exceptionRecovery = "exception_recovery"
    case smartSubtask = "smart_subtask"
    case todo = "todo"
    case background = "background"
    case workflow = "workflow"      // 新增

    var unifiedTaskType: UnifiedTaskType {
        switch self {
        case .exceptionRecovery: return .exceptionRecovery
        case .smartSubtask: return .smartSubtask
        case .todo: return .todo
        case .background: return .background
        case .workflow: return .workflow
        }
    }
}

enum TaskDefinitionSource: String, Codable, Equatable, CaseIterable {
    case chat = "chat"
    case recovery = "recovery"
    case manual = "manual"
    case system = "system"
}

enum DefinitionState: String, Codable, Equatable, CaseIterable {
    case enabled = "enabled"
    case paused = "paused"
    case archived = "archived"
}

struct TaskDefinition: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var description: String
    var kind: TaskDefinitionKind
    var source: TaskDefinitionSource
    var state: DefinitionState
    var assignedAgentID: String?
    var assignedAgentName: String?
    var strategy: TaskExecutionStrategy
    var inputContext: String
    var messages: [TaskMessage]
    var logs: [TaskLogEntry]
    var canResume: Bool
    var gatewaySessionKey: String?
    var originalRequest: String?
    var trigger: TaskTrigger
    var policy: TaskPolicy
    var createdAt: Date
    var updatedAt: Date
    var lastRunAt: Date?
    var nextRunAt: Date?
    var parentTaskID: String?
    
    // MARK: - Workflow 扩展（新增）
    var workflowSpec: WorkflowSpec?     // Workflow 专用配置

    init(
        id: String? = nil,
        title: String,
        description: String = "",
        kind: TaskDefinitionKind,
        source: TaskDefinitionSource,
        state: DefinitionState = .enabled,
        assignedAgentID: String? = nil,
        assignedAgentName: String? = nil,
        strategy: TaskExecutionStrategy = .auto,
        inputContext: String = "",
        messages: [TaskMessage] = [],
        logs: [TaskLogEntry] = [],
        canResume: Bool = true,
        gatewaySessionKey: String? = nil,
        originalRequest: String? = nil,
        trigger: TaskTrigger = .manual,
        policy: TaskPolicy = .default,
        parentTaskID: String? = nil,
        workflowSpec: WorkflowSpec? = nil
    ) {
        let now = Date()

        self.id = id ?? UUID().uuidString
        self.title = title
        self.description = description
        self.kind = kind
        self.source = source
        self.state = state
        self.assignedAgentID = assignedAgentID
        self.assignedAgentName = assignedAgentName
        self.strategy = strategy
        self.inputContext = inputContext
        self.messages = messages
        self.logs = logs
        self.canResume = canResume
        self.gatewaySessionKey = gatewaySessionKey
        self.originalRequest = originalRequest
        self.trigger = trigger
        self.policy = policy
        self.createdAt = now
        self.updatedAt = now
        self.lastRunAt = nil
        self.nextRunAt = trigger.nextRunDate(from: now)
        self.parentTaskID = parentTaskID
        self.workflowSpec = workflowSpec
    }

    mutating func refreshSchedule(from referenceDate: Date = Date()) {
        nextRunAt = trigger.nextRunDate(from: referenceDate)
        updatedAt = Date()
    }

    mutating func markRunFinished(at date: Date = Date()) {
        lastRunAt = date
        updatedAt = date
    }

    mutating func pauseDefinition() {
        state = .paused
        updatedAt = Date()
    }

    mutating func resumeDefinition() {
        state = .enabled
        updatedAt = Date()
    }
}
