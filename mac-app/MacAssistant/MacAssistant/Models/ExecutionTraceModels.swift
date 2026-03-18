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
        sessionID: String? = nil
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
        // 如果没有提供sessionID，使用trace.id作为默认
        self.sessionID = sessionID ?? id.uuidString
    }
}
