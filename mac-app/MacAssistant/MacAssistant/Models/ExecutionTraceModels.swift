//
//  ExecutionTraceModels.swift
//  MacAssistant
//

import Foundation

enum ExecutionTraceState: String, Equatable {
    case routing
    case running
    case fallback
    case synthesizing
    case completed
    case failed

    var displayName: String {
        switch self {
        case .routing:
            return "路由中"
        case .running:
            return "处理中"
        case .fallback:
            return "已回退"
        case .synthesizing:
            return "整合中"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        }
    }

    var symbolName: String {
        switch self {
        case .routing:
            return "arrow.triangle.branch"
        case .running:
            return "ellipsis"
        case .fallback:
            return "arrow.uturn.left.circle"
        case .synthesizing:
            return "square.stack.3d.down.right"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    var isActive: Bool {
        switch self {
        case .routing, .running, .fallback, .synthesizing:
            return true
        case .completed, .failed:
            return false
        }
    }
}

struct ExecutionTrace: Identifiable, Equatable {
    let id: UUID
    let anchorMessageID: UUID
    var assistantMessageID: UUID?
    var runtimeName: String
    var agentName: String
    var intentName: String
    var transitionLabel: String?
    var summary: String
    var state: ExecutionTraceState
    let startedAt: Date
    var finishedAt: Date?
    /// 关联的日志会话ID
    let sessionID: String
    
    // MARK: - 实时进度字段（CLI式详细展示）
    /// 当前步骤（如"建立连接"、"发送请求"、"接收响应"）
    var currentStep: String?
    /// 步骤详情/说明
    var stepDetails: String?
    /// 部分输出内容（流式接收到的文本）
    var partialOutput: String?
    /// 最后更新时间
    var lastUpdatedAt: Date
    /// 进度百分比（0-100）
    var progressPercent: Int?
    /// 已发送 token 数（如果可用）
    var sentTokens: Int?
    /// 已接收 token 数（如果可用）
    var receivedTokens: Int?
    /// 当前正在调用的工具/技能
    var currentTool: String?
    /// 执行日志（时间戳+消息）
    var executionLog: [TraceLogEntry]

    init(
        id: UUID = UUID(),
        anchorMessageID: UUID,
        assistantMessageID: UUID? = nil,
        runtimeName: String = "OpenClaw",
        agentName: String,
        intentName: String,
        transitionLabel: String? = nil,
        summary: String,
        state: ExecutionTraceState,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        sessionID: String? = nil,
        currentStep: String? = nil,
        stepDetails: String? = nil,
        partialOutput: String? = nil,
        progressPercent: Int? = nil,
        executionLog: [TraceLogEntry] = []
    ) {
        self.id = id
        self.anchorMessageID = anchorMessageID
        self.assistantMessageID = assistantMessageID
        self.runtimeName = runtimeName
        self.agentName = agentName
        self.intentName = intentName
        self.transitionLabel = transitionLabel
        self.summary = summary
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.sessionID = sessionID ?? id.uuidString
        self.currentStep = currentStep
        self.stepDetails = stepDetails
        self.partialOutput = partialOutput
        self.lastUpdatedAt = Date()
        self.progressPercent = progressPercent
        self.sentTokens = nil
        self.receivedTokens = nil
        self.currentTool = nil
        self.executionLog = executionLog
    }
}

/// Trace 执行日志条目
struct TraceLogEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let message: String
    
    enum LogLevel: String, Codable {
        case info = "info"
        case success = "success"
        case warning = "warning"
        case error = "error"
    }
    
    init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel = .info, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}
