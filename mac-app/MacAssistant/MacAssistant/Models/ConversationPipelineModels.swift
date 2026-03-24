//
//  ConversationPipelineModels.swift
//  MacAssistant
//

import Foundation

struct AssembledConversationContext {
    let text: String
    let images: [String]
    let envelope: RequestEnvelope
}

struct ConversationStores: Equatable {
    var messages: [ChatMessage]
    var taskSessions: [AgentTaskSession]
    var tracesByID: [UUID: ExecutionTrace]
    var currentTrace: ExecutionTrace?
    var isProcessing: Bool
    var lastScreenshotPath: String?
    var activeBrowserSessionID: String?
    var browserSessions: [BrowserSession]

    static let empty = ConversationStores(
        messages: [],
        taskSessions: [],
        tracesByID: [:],
        currentTrace: nil,
        isProcessing: false,
        lastScreenshotPath: nil,
        activeBrowserSessionID: nil,
        browserSessions: []
    )

    var visibleMessages: [ChatMessage] {
        messages.filter { $0.linkedTaskSessionID == nil }
    }

    var taskSessionsForDisplay: [AgentTaskSession] {
        taskSessions
            .filter { !$0.isHiddenFromTabs }
            .sorted {
                if $0.updatedAt == $1.updatedAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.updatedAt > $1.updatedAt
            }
    }

    var taskSessionIDs: [String] {
        taskSessionsForDisplay.map(\.id)
    }

    var activeBrowserSession: BrowserSession? {
        guard let activeBrowserSessionID else { return nil }
        return browserSessions.first { $0.id == activeBrowserSessionID }
    }

    func executionTrace(forMessageID messageID: UUID) -> ExecutionTrace? {
        tracesByID.values
            .filter { trace in
                if let assistantMessageID = trace.assistantMessageID {
                    return assistantMessageID == messageID
                }
                return trace.anchorMessageID == messageID
            }
            .sorted { lhs, rhs in
                if lhs.state.isActive != rhs.state.isActive {
                    return lhs.state.isActive && !rhs.state.isActive
                }
                return lhs.startedAt > rhs.startedAt
            }
            .first
    }
}
