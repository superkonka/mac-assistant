//
//  ConversationController.swift
//  MacAssistant
//

import Foundation
import Combine

@MainActor
final class ConversationController: ObservableObject {
    static let shared = ConversationController()

    @Published private(set) var stores: ConversationStores = .empty

    private let agentStore = AgentStore.shared
    private let orchestrator = AgentOrchestrator.shared
    private let creationSkill = AgentCreationSkill.shared
    private let conversationControl = ConversationControlStore.shared
    private let contextAssembler: ContextAssembler
    private let planner: RequestPlanner
    private let runtime: ConversationRuntime
    private var cancellables: Set<AnyCancellable> = []

    init(
        contextAssembler: ContextAssembler = .shared,
        planner: RequestPlanner = .shared,
        runtime: ConversationRuntime? = nil
    ) {
        self.contextAssembler = contextAssembler
        self.planner = planner
        self.runtime = runtime ?? .shared

        bindRuntime()
        stores = self.runtime.stores
    }

    func processInput(_ rawText: String, explicitImages: [String] = []) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        print("[DEBUG] [ConversationController] 收到输入: \(text)")

        let request = contextAssembler.assemble(
            ConversationAssemblyInput(
                text: text,
                explicitImages: explicitImages,
                lastScreenshotPath: stores.lastScreenshotPath,
                sessionTopology: conversationControl.currentTopology(),
                currentAgent: orchestrator.currentAgent,
                needsInitialSetup: agentStore.needsInitialSetup,
                lastMessage: stores.messages.last,
                creationFlowActive: creationSkill.isInCreationFlow,
                messages: stores.messages,
                taskSessions: stores.taskSessions,
                activeBrowserSessionID: stores.activeBrowserSessionID,
                browserSessions: stores.browserSessions
            )
        )

        // 异步处理请求，使用非隔离的 Task 避免死锁
        let envelope = request.envelope
        Task.detached(priority: .userInitiated) { [envelope] in
            let plan = await RequestPlanner.shared.plan(envelope)
            await ConversationRuntime.shared.executePreparedRequest(request, plan: plan)
        }
    }

    func handleScreenshot() {
        runtime.handleScreenshot()
    }

    func appendMessage(_ message: ChatMessage) {
        runtime.appendMessage(message)
    }

    func showInitialSetupGuidance(for action: String? = nil) {
        runtime.showInitialSetupGuidance(for: action)
    }

    func dismissTaskSessionFromTabs(_ id: String) {
        runtime.dismissTaskSessionFromTabs(id)
    }

    func resumeTaskSession(_ id: String) {
        runtime.resumeTaskSession(id)
    }

    func taskSession(for id: String?) -> AgentTaskSession? {
        runtime.taskSession(for: id)
    }

    func executionTrace(forMessageID messageID: UUID) -> ExecutionTrace? {
        runtime.executionTrace(forMessageID: messageID)
    }

    @MainActor
    func handleDetectedSkillSuggestionAction(
        messageID: UUID,
        action: DetectedSkillSuggestionAction,
        images: [String] = []
    ) async {
        await runtime.handleDetectedSkillSuggestionAction(
            messageID: messageID,
            action: action,
            images: images
        )
    }

    // MARK: - 统一执行结果处理
    
    /// 处理执行结果并显示在主会话
    func handleExecutionResult(_ result: ExecutionResult, displayInChat: Bool = true) {
        // 1. 更新状态存储
        if let serviceId = result.serviceId {
            // 服务操作结果
            updateServiceState(from: result)
        }
        
        // 2. 添加到主会话显示
        if displayInChat {
            displayResultInChat(result)
        }
        
        // 3. 发送通知
        NotificationCenter.default.post(
            name: .executionResultReceived,
            object: result
        )
    }
    
    /// 在主会话中显示执行结果
    private func displayResultInChat(_ result: ExecutionResult) {
        let content: String
        
        switch result.source {
        case .service:
            // 服务操作显示系统消息
            content = result.message
            
        case .task:
            if result.isProgress {
                // 进度更新：更新最后一条消息或添加新消息
                content = "⏳ \(result.message)"
            } else {
                content = result.success ? "✅ \(result.message)" : "❌ \(result.message)"
            }
            
        case .skill:
            content = "🔧 \(result.message)"
            
        case .agent:
            // Agent 回复通过正常对话流程处理
            return
            
        case .system:
            content = "ℹ️ \(result.message)"
        }
        
        let message = ChatMessage(
            id: UUID(),
            role: .system,
            content: content,
            timestamp: result.timestamp
        )
        
        appendMessage(message)
    }
    
    /// 从执行结果更新服务状态
    private func updateServiceState(from result: ExecutionResult) {
        guard let serviceId = result.serviceId else { return }
        
        // 更新 ServiceStateStore
        if let stateStr = result.metadata["final_state"],
           let state = ServiceRuntimeState(rawValue: stateStr) {
            
            ServiceStateStore.shared.updateState(
                id: serviceId,
                state: state,
                adapter: result.metadata["adapter"],
                metadata: result.metadata
            )
        }
    }
    
    /// 流式更新最后一条消息（用于进度显示）
    func updateStreamingMessage(_ content: String) {
        // 实现流式消息更新逻辑
        // 这里简化处理：直接追加新消息
        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date()
        )
        appendMessage(message)
    }
    
    private func bindRuntime() {
        runtime.$stores
            .sink { [weak self] stores in
                self?.stores = stores
            }
            .store(in: &cancellables)
    }
}

// MARK: - 通知扩展

extension Notification.Name {
    static let executionResultReceived = Notification.Name("executionResultReceived")
}
