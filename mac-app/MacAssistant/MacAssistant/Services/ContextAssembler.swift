//
//  ContextAssembler.swift
//  MacAssistant
//

import Foundation

struct ConversationAssemblyInput {
    let text: String
    let explicitImages: [String]
    let lastScreenshotPath: String?
    let sessionTopology: ConversationSessionTopology
    let currentAgent: Agent?
    let needsInitialSetup: Bool
    let lastMessage: ChatMessage?
    let creationFlowActive: Bool
    let messages: [ChatMessage]
    let taskSessions: [AgentTaskSession]
}

final class ContextAssembler {
    static let shared = ContextAssembler()

    private let workflowOriginalInputKey = "workflow_original_input"
    private let workflowTaskSessionIDKey = "workflow_task_session_id"

    init() {}

    func assemble(_ input: ConversationAssemblyInput) -> AssembledConversationContext {
        let images = resolveImagesForRequest(
            text: input.text,
            explicitImages: input.explicitImages,
            messages: input.messages,
            lastScreenshotPath: input.lastScreenshotPath
        )

        let envelope = RequestEnvelope(
            originalText: input.text,
            images: images,
            sessionTopology: input.sessionTopology,
            currentAgent: input.currentAgent,
            needsInitialSetup: input.needsInitialSetup,
            lastMessage: input.lastMessage,
            creationFlowActive: input.creationFlowActive,
            resumableTaskSessionID: latestResumableTaskSessionID(in: input.taskSessions),
            activeWorkflowDesignContext: activeWorkflowDesignContext(
                messages: input.messages,
                taskSessions: input.taskSessions
            )
        )

        return AssembledConversationContext(
            text: input.text,
            images: images,
            envelope: envelope
        )
    }

    func isImageAnalysisRequest(text: String, images: [String]) -> Bool {
        if !images.isEmpty {
            return true
        }

        let normalized = text.lowercased()
        return ["图片", "图像", "截图", "看图", "分析图", "分析图片", "分析截图", "这张图"]
            .contains { normalized.contains($0) }
    }

    private func resolveImagesForRequest(
        text: String,
        explicitImages: [String],
        messages: [ChatMessage],
        lastScreenshotPath: String?
    ) -> [String] {
        if !explicitImages.isEmpty {
            return explicitImages
        }

        guard isImageAnalysisRequest(text: text, images: explicitImages) else {
            return []
        }

        if let recentImagePath = latestReusableImagePath(
            messages: messages,
            lastScreenshotPath: lastScreenshotPath
        ) {
            return [recentImagePath]
        }

        return []
    }

    private func latestReusableImagePath(
        messages: [ChatMessage],
        lastScreenshotPath: String?
    ) -> String? {
        let fileManager = FileManager.default

        if let lastScreenshotPath,
           fileManager.fileExists(atPath: lastScreenshotPath) {
            return lastScreenshotPath
        }

        for message in messages.reversed() {
            guard let imagePath = message.images?.last else { continue }
            if fileManager.fileExists(atPath: imagePath) {
                return imagePath
            }
        }

        return nil
    }

    private func latestResumableTaskSessionID(in sessions: [AgentTaskSession]) -> String? {
        sessions
            .reversed()
            .first(where: { $0.canResume || $0.status == .partial || $0.status == .waitingUser })?
            .id
    }

    private func activeWorkflowDesignContext(
        messages: [ChatMessage],
        taskSessions: [AgentTaskSession]
    ) -> WorkflowDesignContinuationContext? {
        if let lastMessage = messages.last,
           let sessionID = lastMessage.metadata?[workflowTaskSessionIDKey] ?? lastMessage.linkedTaskSessionID,
           let session = taskSessions.first(where: { $0.id == sessionID && $0.intentName == "业务工作流设计" }) {
            let originalInput = lastMessage.metadata?[workflowOriginalInputKey] ?? session.originalRequest
            return WorkflowDesignContinuationContext(sessionID: sessionID, originalInput: originalInput)
        }

        let cutoff = Date().addingTimeInterval(-15 * 60)
        let likelyWorkflowFollowUp = messages.last.map { lastMessage in
            let normalized = lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return lastMessage.role != .user &&
                (normalized.contains("工作流") || normalized.contains("方案") || normalized.contains("设计"))
        } ?? false

        if likelyWorkflowFollowUp,
           let session = taskSessions.reversed().first(where: {
               $0.intentName == "业务工作流设计" &&
               $0.updatedAt >= cutoff &&
               $0.status != .failed
           }) {
            return WorkflowDesignContinuationContext(
                sessionID: session.id,
                originalInput: session.originalRequest
            )
        }

        return nil
    }
}
