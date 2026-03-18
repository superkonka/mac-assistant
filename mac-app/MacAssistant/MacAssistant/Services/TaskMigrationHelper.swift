//
//  TaskMigrationHelper.swift
//  MacAssistant
//
//  任务系统迁移工具 - 帮助从旧系统迁移到统一任务系统
//

import Foundation

/// 任务系统迁移助手
@MainActor
final class TaskMigrationHelper {
    
    /// 将旧版AgentTaskSession转换为UnifiedTask
    static func migrateAgentTaskSession(_ session: AgentTaskSession) -> UnifiedTask {
        // 映射状态
        let status: UnifiedTaskStatus
        switch session.status {
        case .queued, .waitingUser:
            status = .pending
        case .running:
            status = .running
        case .partial:
            status = .paused  // partial状态映射为paused
        case .completed:
            status = .completed
        case .failed:
            status = .failed
        }
        
        // 转换消息类型
        let taskMessages: [TaskMessage] = session.messages.map { msg in
            let role: TaskMessage.TaskMessageRole
            switch msg.role {
            case .user:
                role = .user
            case .assistant:
                role = .assistant
            case .system:
                role = .system
            }
            return TaskMessage(
                id: msg.id,
                role: role,
                content: msg.content,
                timestamp: msg.timestamp,
                agentID: nil,
                agentName: msg.agentName
            )
        }
        
        // 转换为UnifiedTask
        return UnifiedTask(
            id: session.id,
            type: .exceptionRecovery,
            title: session.title,
            description: "请求处理中断，点击继续处理重试",
            status: status,
            strategy: .exceptionRecovery,
            inputContext: session.originalRequest,
            result: session.resultSummary,
            errorMessage: session.errorMessage,
            messages: taskMessages,
            canResume: session.canResume,
            gatewaySessionKey: session.gatewaySessionKey,
            originalRequest: session.originalRequest
        )
    }
    
    /// 将旧版Subtask转换为UnifiedTask
    static func migrateSubtask(_ subtask: Subtask) -> UnifiedTask {
        // 映射状态
        let status: UnifiedTaskStatus
        switch subtask.status {
        case .pending:
            status = .pending
        case .running:
            status = .running
        case .completed:
            status = .completed
        case .failed, .cancelled:
            status = .failed
        }
        
        // 映射策略
        let strategy: TaskExecutionStrategy = .auto
        
        return UnifiedTask(
            id: subtask.id,
            type: .smartSubtask,
            title: subtask.title,
            description: subtask.description,
            status: status,
            strategy: strategy,
            inputContext: subtask.inputContext,
            result: subtask.result
        )
    }
    
    /// 将旧版TaskItem转换为UnifiedTask
    static func migrateTaskItem(_ taskItem: TaskItem) -> UnifiedTask {
        // 映射状态
        let status: UnifiedTaskStatus
        switch taskItem.status {
        case .pending:
            status = .pending
        case .running:
            status = .running
        case .paused:
            status = .paused
        case .completed:
            status = .completed
        case .failed:
            status = .failed
        }
        
        // 映射策略
        let strategy: TaskExecutionStrategy
        if let agentID = taskItem.assignedAgentID {
            strategy = .useAgent(agentID)
        } else {
            strategy = .auto
        }
        
        var task = UnifiedTask(
            id: taskItem.id,
            type: .todo,
            title: taskItem.title,
            description: taskItem.description,
            status: status,
            assignedAgentID: taskItem.assignedAgentID,
            assignedAgentName: taskItem.assignedAgentName,
            strategy: strategy,
            inputContext: taskItem.inputContext,
            result: taskItem.result,
            scheduledTime: taskItem.scheduledTime,
            parentTaskID: taskItem.parentTaskID
        )
        
        // 复制其他字段
        task.messages = taskItem.messages
        task.logs = taskItem.logs
        task.executionTime = taskItem.executionTime
        task.createdAt = taskItem.createdAt
        task.updatedAt = taskItem.updatedAt
        
        return task
    }
    
    /// 批量迁移任务（用于应用启动时）
    static func migrateAllTasks(
        agentSessions: [AgentTaskSession] = [],
        subtasks: [Subtask] = [],
        taskItems: [TaskItem] = []
    ) -> [UnifiedTask] {
        var unifiedTasks: [UnifiedTask] = []
        
        // 迁移异常恢复任务
        for session in agentSessions {
            unifiedTasks.append(migrateAgentTaskSession(session))
        }
        
        // 迁移子任务
        for subtask in subtasks {
            unifiedTasks.append(migrateSubtask(subtask))
        }
        
        // 迁移待办任务
        for taskItem in taskItems {
            unifiedTasks.append(migrateTaskItem(taskItem))
        }
        
        return unifiedTasks
    }
}

// MARK: - 扩展方法

extension UnifiedTaskManager {
    /// 从旧版AgentTaskSession导入
    func importAgentTaskSession(_ session: AgentTaskSession) {
        let task = TaskMigrationHelper.migrateAgentTaskSession(session)
        
        // 检查是否已存在
        if tasks.contains(where: { $0.id == task.id }) {
            updateTask(id: task.id) { existing in
                existing.status = task.status
                existing.result = task.result ?? existing.result
                existing.errorMessage = task.errorMessage ?? existing.errorMessage
                existing.messages = task.messages.isEmpty ? existing.messages : task.messages
            }
        } else {
            addTask(task)
        }
    }
    
    /// 从旧版Subtask导入
    func importSubtask(_ subtask: Subtask) {
        let task = TaskMigrationHelper.migrateSubtask(subtask)
        addTask(task)
    }
    
    /// 从旧版TaskItem导入
    func importTaskItem(_ taskItem: TaskItem) {
        let task = TaskMigrationHelper.migrateTaskItem(taskItem)
        addTask(task)
    }
}
