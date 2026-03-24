//
//  TaskModels.swift
//  MacAssistant
//
//  共享任务消息与日志模型
//

import Foundation

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

/// 任务消息（统一任务与迁移兼容共用）
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
