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
    private let taskManager = TaskManager.shared
    private var cancellables: Set<AnyCancellable> = []

    init(runner: CommandRunner = .shared) {
        self.runner = runner

        bindRunner()
        bindTaskManager()
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
        // 将 TaskManager 的任务转换为 AgentTaskSession 并合并
        let taskManagerSessions = convertTaskManagerTasksToSessions()
        let mergedSessions = runner.taskSessions + taskManagerSessions
        
        stores = ConversationStores(
            messages: runner.messages,
            taskSessions: mergedSessions,
            tracesByID: runner.messageExecutionTraces,
            currentTrace: runner.currentExecutionTrace,
            isProcessing: runner.isProcessing,
            lastScreenshotPath: runner.lastScreenshotPath
        )
    }
    
    private func bindTaskManager() {
        // 监听 TaskManager 的变化
        taskManager.$pendingTasks
            .sink { [weak self] _ in self?.refreshStores() }
            .store(in: &cancellables)
        
        taskManager.$runningTasks
            .sink { [weak self] _ in self?.refreshStores() }
            .store(in: &cancellables)
        
        taskManager.$completedTasks
            .sink { [weak self] _ in self?.refreshStores() }
            .store(in: &cancellables)
    }
    
    /// 将 TaskManager 的任务转换为 AgentTaskSession
    private func convertTaskManagerTasksToSessions() -> [AgentTaskSession] {
        var sessions: [AgentTaskSession] = []
        
        // 转换待执行任务
        for task in taskManager.pendingTasks {
            sessions.append(convertTaskItemToSession(task))
        }
        
        // 转换执行中任务
        for task in taskManager.runningTasks {
            sessions.append(convertTaskItemToSession(task))
        }
        
        // 转换已完成任务（只显示最近5个）
        let recentCompleted = taskManager.completedTasks.suffix(5)
        for task in recentCompleted {
            sessions.append(convertTaskItemToSession(task))
        }
        
        return sessions
    }
    
    /// 将单个 TaskItem 转换为 AgentTaskSession
    private func convertTaskItemToSession(_ task: TaskItem) -> AgentTaskSession {
        // 映射状态
        let sessionStatus: TaskSessionStatus
        switch task.status {
        case .pending:
            sessionStatus = .queued
        case .running:
            sessionStatus = .running
        case .paused:
            sessionStatus = .waitingUser
        case .completed:
            sessionStatus = .completed
        case .failed:
            sessionStatus = .failed
        }
        
        // 转换消息
        let sessionMessages = task.messages.map { msg in
            TaskSessionMessage(
                id: UUID(),
                role: msg.role == .user ? .user : (msg.role == .assistant ? .assistant : .system),
                content: msg.content,
                timestamp: msg.timestamp,
                agentName: msg.agentName
            )
        }
        
        return AgentTaskSession(
            id: "taskmanager-\(task.id)",
            title: task.title,
            originalRequest: task.inputContext,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            status: sessionStatus,
            statusSummary: task.description,
            mainAgentName: task.assignedAgentName,
            intentName: task.type.rawValue.replacingOccurrences(of: "_", with: " "),
            messages: sessionMessages,
            resultSummary: task.result,
            errorMessage: task.status == .failed ? "任务执行失败" : nil,
            canResume: task.status == .pending || task.status == .paused
        )
    }
}
