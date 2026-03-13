//
//  ConversationRuntime.swift
//  MacAssistant
//

import Foundation
import Combine

@MainActor
final class ConversationRuntime: ObservableObject {
    static let shared = ConversationRuntime()

    @Published private(set) var stores: ConversationStores = .empty

    private let runner: CommandRunner
    private var cancellables: Set<AnyCancellable> = []

    init(runner: CommandRunner = .shared) {
        self.runner = runner

        bindRunner()
        refreshStores()
    }

    func executePreparedRequest(
        _ request: AssembledConversationContext,
        plan: RequestPlan
    ) async {
        await runner.processPreparedRequest(request, plan: plan)
    }

    func handleScreenshot() {
        runner.handleScreenshot()
    }

    func appendMessage(_ message: ChatMessage) {
        runner.messages.append(message)
    }

    func showInitialSetupGuidance(for action: String? = nil) {
        runner.showInitialSetupGuidance(for: action)
    }

    func dismissTaskSessionFromTabs(_ id: String) {
        runner.dismissTaskSessionFromTabs(id)
    }

    func resumeTaskSession(_ id: String) {
        runner.resumeTaskSession(id)
    }

    func taskSession(for id: String?) -> AgentTaskSession? {
        guard let id else { return nil }
        return stores.taskSessionsForDisplay.first { $0.id == id }
    }

    func executionTrace(forMessageID messageID: UUID) -> ExecutionTrace? {
        stores.executionTrace(forMessageID: messageID)
    }

    func handleDetectedSkillSuggestionAction(
        messageID: UUID,
        action: DetectedSkillSuggestionAction,
        images: [String] = []
    ) async {
        await runner.handleDetectedSkillSuggestionAction(
            messageID: messageID,
            action: action,
            images: images
        )
    }

    private func bindRunner() {
        runner.$messages
            .sink { [weak self] _ in self?.refreshStores() }
            .store(in: &cancellables)

        runner.$taskSessions
            .sink { [weak self] _ in self?.refreshStores() }
            .store(in: &cancellables)

        runner.$messageExecutionTraces
            .sink { [weak self] _ in self?.refreshStores() }
            .store(in: &cancellables)

        runner.$currentExecutionTrace
            .sink { [weak self] _ in self?.refreshStores() }
            .store(in: &cancellables)

        runner.$isProcessing
            .sink { [weak self] _ in self?.refreshStores() }
            .store(in: &cancellables)

        runner.$lastScreenshotPath
            .sink { [weak self] _ in self?.refreshStores() }
            .store(in: &cancellables)
    }

    private func refreshStores() {
        stores = ConversationStores(
            messages: runner.messages,
            taskSessions: runner.taskSessions,
            tracesByID: runner.messageExecutionTraces,
            currentTrace: runner.currentExecutionTrace,
            isProcessing: runner.isProcessing,
            lastScreenshotPath: runner.lastScreenshotPath
        )
    }
}
