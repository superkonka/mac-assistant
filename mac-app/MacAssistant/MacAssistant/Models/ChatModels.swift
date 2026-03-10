//
//  ChatModels.swift
//  MacAssistant
//
//  聊天相关的数据模型
//

import Foundation

// MARK: - Message Role

enum MessageRole: String, Codable, Equatable {
    case user
    case assistant
    case system
}

enum TaskSessionStatus: String, Codable, Equatable {
    case queued
    case running
    case completed
    case failed

    var displayName: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "执行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }

    var symbolName: String {
        switch self {
        case .queued: return "clock"
        case .running: return "hourglass"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var tintName: String {
        switch self {
        case .queued: return "gray"
        case .running: return "blue"
        case .completed: return "green"
        case .failed: return "orange"
        }
    }
}

struct TaskSessionMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date
    var agentName: String?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        agentName: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.agentName = agentName
    }
}

struct AgentTaskSession: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let originalRequest: String
    let createdAt: Date
    var updatedAt: Date
    var status: TaskSessionStatus
    var statusSummary: String
    var mainAgentName: String?
    var delegateAgentName: String?
    var intentName: String
    var isExpanded: Bool
    var messages: [TaskSessionMessage]
    var resultSummary: String?
    var errorMessage: String?
    var linkedMainMessageID: UUID?

    init(
        id: String = "task-\(UUID().uuidString.prefix(8))",
        title: String,
        originalRequest: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: TaskSessionStatus = .queued,
        statusSummary: String,
        mainAgentName: String? = nil,
        delegateAgentName: String? = nil,
        intentName: String,
        isExpanded: Bool = true,
        messages: [TaskSessionMessage] = [],
        resultSummary: String? = nil,
        errorMessage: String? = nil,
        linkedMainMessageID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.originalRequest = originalRequest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.statusSummary = statusSummary
        self.mainAgentName = mainAgentName
        self.delegateAgentName = delegateAgentName
        self.intentName = intentName
        self.isExpanded = isExpanded
        self.messages = messages
        self.resultSummary = resultSummary
        self.errorMessage = errorMessage
        self.linkedMainMessageID = linkedMainMessageID
    }
}

// MARK: - Chat Message

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date
    var images: [String]?
    var agentId: String?
    var agentName: String?
    var linkedTaskSessionID: String?
    var metadata: [String: String]?
    
    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        images: [String]? = nil,
        agentId: String? = nil,
        agentName: String? = nil,
        linkedTaskSessionID: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.images = images
        self.agentId = agentId
        self.agentName = agentName
        self.linkedTaskSessionID = linkedTaskSessionID
        self.metadata = metadata
    }
}

// MARK: - API Models

struct APIResponse: Codable {
    let role: String?
    let content: String?
    let error: String?
}

struct HealthResponse: Codable {
    let status: String
    let openclaw: Bool
    let kimi: Bool
    let connections: Int
}

struct CommandRequest: Codable {
    let command: String
    let context: String?
    let use_openclaw: Bool
    let use_kimi: Bool
}

struct SystemAction: Codable {
    let action: String
    let params: [String: String]?
}

// MARK: - Skill Context

/// 技能执行上下文（用于 UI 层）
struct SkillContext {
    let input: String?
    let images: [String]?
    let currentAgent: Agent?
    let runner: CommandRunner
    
    init(
        input: String? = nil,
        images: [String]? = nil,
        currentAgent: Agent? = nil,
        runner: CommandRunner
    ) {
        self.input = input
        self.images = images
        self.currentAgent = currentAgent
        self.runner = runner
    }
}
