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
                taskSessions: stores.taskSessions
            )
        )

        Task {
            let plan = await planner.plan(request.envelope)
            await runtime.executePreparedRequest(request, plan: plan)
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

    private func bindRuntime() {
        runtime.$stores
            .sink { [weak self] stores in
                self?.stores = stores
            }
            .store(in: &cancellables)
    }
}
