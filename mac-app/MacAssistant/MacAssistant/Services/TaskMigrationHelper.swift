//
//  TaskMigrationHelper.swift
//  MacAssistant
//
//  任务系统迁移工具 - 帮助从旧系统迁移到统一任务系统
//

import Foundation

enum LegacyTaskStatus: String, Codable {
    case pending
    case running
    case paused
    case completed
    case failed
}

struct LegacyTaskRecord: Codable {
    let id: String
    let type: SubtaskType
    let title: String
    let description: String
    let parentTaskID: String?
    let status: LegacyTaskStatus
    let strategy: SubtaskStrategy
    let assignedAgentID: String?
    let assignedAgentName: String?
    let inputContext: String
    let result: String?
    let executionTime: TimeInterval?
    let scheduledTime: Date?
    let isPaused: Bool
    let createdAt: Date
    let updatedAt: Date
    let messages: [TaskMessage]
    let logs: [TaskLogEntry]
    let logFilePath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case description
        case parentTaskID
        case status
        case strategy
        case assignedAgentID
        case assignedAgentName
        case inputContext
        case result
        case executionTime
        case scheduledTime
        case isPaused
        case createdAt
        case updatedAt
        case messages
        case logs
        case logFilePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = (try? container.decode(SubtaskType.self, forKey: .type)) ?? .custom
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        parentTaskID = try container.decodeIfPresent(String.self, forKey: .parentTaskID)
        status = (try? container.decode(LegacyTaskStatus.self, forKey: .status)) ?? .pending
        strategy = (try? container.decode(SubtaskStrategy.self, forKey: .strategy)) ?? .custom
        assignedAgentID = try container.decodeIfPresent(String.self, forKey: .assignedAgentID)
        assignedAgentName = try container.decodeIfPresent(String.self, forKey: .assignedAgentName)
        inputContext = (try? container.decode(String.self, forKey: .inputContext)) ?? ""
        result = try container.decodeIfPresent(String.self, forKey: .result)
        executionTime = try container.decodeIfPresent(TimeInterval.self, forKey: .executionTime)
        scheduledTime = try container.decodeIfPresent(Date.self, forKey: .scheduledTime)
        isPaused = (try? container.decode(Bool.self, forKey: .isPaused)) ?? false
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? createdAt
        messages = (try? container.decode([TaskMessage].self, forKey: .messages)) ?? []
        logs = (try? container.decode([TaskLogEntry].self, forKey: .logs)) ?? []
        logFilePath = try container.decodeIfPresent(String.self, forKey: .logFilePath)
    }
}

/// 任务系统迁移助手
@MainActor
final class TaskMigrationHelper {
    static func decodeLegacyTaskRecords(from data: Data) throws -> [LegacyTaskRecord] {
        let allTasks = try JSONDecoder().decode([String: [LegacyTaskRecord]].self, from: data)
        return (allTasks["pending"] ?? [])
            + (allTasks["running"] ?? [])
            + (allTasks["completed"] ?? [])
    }
    
    /// 将旧版任务持久化记录转换为 UnifiedTask
    static func migrateLegacyTaskRecord(_ taskItem: LegacyTaskRecord) -> UnifiedTask {
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
}
