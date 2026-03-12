//
//  ChatModels.swift
//  MacAssistant
//
//  聊天相关的数据模型
//

import Foundation

enum SkillDetectionPreference: String, Codable, CaseIterable, Identifiable {
    case askEveryTime = "ask_every_time"
    case autoRun = "auto_run"
    case neverSuggest = "never_suggest"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .askEveryTime:
            return "每次都问"
        case .autoRun:
            return "自动执行"
        case .neverSuggest:
            return "不再建议"
        }
    }

    var subtitle: String {
        switch self {
        case .askEveryTime:
            return "检测到意图后先弹卡片确认，再决定是否独立处理。"
        case .autoRun:
            return "检测到意图后直接拆成独立任务，不打断主会话。"
        case .neverSuggest:
            return "不再主动推荐这个 Skill，只有手动命令时才执行。"
        }
    }
}

enum DetectedSkillSuggestionAction {
    case runOnce
    case dismissOnce
    case alwaysAutoRun
    case neverSuggest
}

struct DetectedSkillSuggestion: Equatable {
    let messageID: UUID
    let skill: AISkill
    let input: String
    let executionInput: String
    let sourceLabel: String
}

// MARK: - Message Role

enum MessageRole: String, Codable, Equatable {
    case user
    case assistant
    case system
}

enum TaskSessionStatus: String, Codable, Equatable {
    case queued
    case running
    case partial
    case waitingUser
    case completed
    case failed

    var displayName: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "执行中"
        case .partial: return "部分恢复"
        case .waitingUser: return "等待继续"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }

    var symbolName: String {
        switch self {
        case .queued: return "clock"
        case .running: return "hourglass"
        case .partial: return "arrow.trianglehead.clockwise"
        case .waitingUser: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var tintName: String {
        switch self {
        case .queued: return "gray"
        case .running: return "blue"
        case .partial: return "teal"
        case .waitingUser: return "yellow"
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
    var delegateAgentID: String?
    var delegateAgentName: String?
    var intentName: String
    var isExpanded: Bool
    var messages: [TaskSessionMessage]
    var resultSummary: String?
    var errorMessage: String?
    var linkedMainMessageID: UUID?
    var inputImages: [String]?
    var gatewaySessionKey: String?
    var gatewayRunID: String?
    var gatewayConversationSessionID: String?
    var requestStartedAt: Date?
    var latestAssistantText: String?
    var canResume: Bool
    var lastReconciledAt: Date?

    init(
        id: String = "task-\(UUID().uuidString.prefix(8))",
        title: String,
        originalRequest: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: TaskSessionStatus = .queued,
        statusSummary: String,
        mainAgentName: String? = nil,
        delegateAgentID: String? = nil,
        delegateAgentName: String? = nil,
        intentName: String,
        isExpanded: Bool = true,
        messages: [TaskSessionMessage] = [],
        resultSummary: String? = nil,
        errorMessage: String? = nil,
        linkedMainMessageID: UUID? = nil,
        inputImages: [String]? = nil,
        gatewaySessionKey: String? = nil,
        gatewayRunID: String? = nil,
        gatewayConversationSessionID: String? = nil,
        requestStartedAt: Date? = nil,
        latestAssistantText: String? = nil,
        canResume: Bool = false,
        lastReconciledAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.originalRequest = originalRequest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.statusSummary = statusSummary
        self.mainAgentName = mainAgentName
        self.delegateAgentID = delegateAgentID
        self.delegateAgentName = delegateAgentName
        self.intentName = intentName
        self.isExpanded = isExpanded
        self.messages = messages
        self.resultSummary = resultSummary
        self.errorMessage = errorMessage
        self.linkedMainMessageID = linkedMainMessageID
        self.inputImages = inputImages
        self.gatewaySessionKey = gatewaySessionKey
        self.gatewayRunID = gatewayRunID
        self.gatewayConversationSessionID = gatewayConversationSessionID
        self.requestStartedAt = requestStartedAt
        self.latestAssistantText = latestAssistantText
        self.canResume = canResume
        self.lastReconciledAt = lastReconciledAt
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

extension ChatMessage {
    static let detectedSkillKey = "detected_skill"
    static let detectedSkillInputKey = "detected_skill_input"
    static let detectedSkillExecutionInputKey = "detected_skill_execution_input"
    static let detectedSkillSourceKey = "detected_skill_source"

    var detectedSkillSuggestion: DetectedSkillSuggestion? {
        guard let metadata,
              let rawSkill = metadata[Self.detectedSkillKey],
              let skill = AISkill(rawValue: rawSkill),
              let input = metadata[Self.detectedSkillInputKey],
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return DetectedSkillSuggestion(
            messageID: id,
            skill: skill,
            input: input,
            executionInput: metadata[Self.detectedSkillExecutionInputKey] ?? input,
            sourceLabel: metadata[Self.detectedSkillSourceKey] ?? "自然意图"
        )
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
