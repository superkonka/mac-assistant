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
    private let unifiedTaskManager = UnifiedTaskManager.shared
    private let browserSessionStore = BrowserSessionStore.shared
    private let unifiedSessionPrefix = "unified-task-"
    private var dismissedUnifiedSessionDates: [String: Date] = [:]
    private var cancellables: Set<AnyCancellable> = []
    
    // 节流控制
    private var lastRefreshTime: Date = .distantPast
    private var pendingRefresh = false
    private let refreshInterval: TimeInterval = 0.1  // 最小刷新间隔

    init(runner: CommandRunner = .shared) {
        self.runner = runner
        _ = LegacyTaskMigrationService.shared

        bindRunner()
        bindUnifiedTaskManager()
        bindBrowserSessions()
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
        if isUnifiedTaskSession(id) {
            guard let session = stores.taskSessions.first(where: { $0.id == id }),
                  session.status == .completed else {
                return
            }

            dismissedUnifiedSessionDates[id] = Date()
            refreshStores()
            return
        }

        runner.dismissTaskSessionFromTabs(id)
    }

    func resumeTaskSession(_ id: String) {
        if let taskID = unifiedTaskID(from: id) {
            unifiedTaskManager.focusTask(id: taskID)
            Task {
                await unifiedTaskManager.continueTask(id: taskID)
            }
            return
        }

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

    private func bindUnifiedTaskManager() {
        unifiedTaskManager.$tasks
            .sink { [weak self] _ in self?.refreshStores() }
            .store(in: &cancellables)
    }

    private func bindBrowserSessions() {
        browserSessionStore.$sessions
            .sink { [weak self] _ in self?.refreshStores() }
            .store(in: &cancellables)

        browserSessionStore.$activeSessionID
            .sink { [weak self] _ in self?.refreshStores() }
            .store(in: &cancellables)
    }

    private func refreshStores() {
        // 节流检查
        let now = Date()
        let timeSinceLastRefresh = now.timeIntervalSince(lastRefreshTime)
        
        if timeSinceLastRefresh < refreshInterval {
            // 如果距离上次刷新时间太短，标记有挂起的刷新
            if !pendingRefresh {
                pendingRefresh = true
                // 延迟执行刷新
                DispatchQueue.main.asyncAfter(deadline: .now() + refreshInterval - timeSinceLastRefresh) { [weak self] in
                    self?.pendingRefresh = false
                    self?.refreshStores()
                }
            }
            return
        }
        
        lastRefreshTime = now
        pendingRefresh = false
        
        let unifiedSessions = convertUnifiedTasksToSessions()
        let unifiedGatewaySessionKeys = Set(unifiedSessions.compactMap(\.gatewaySessionKey))
        let runnerSessions = filteredRunnerSessions(
            excludingGatewaySessionKeys: unifiedGatewaySessionKeys
        )
        let mergedSessions = runnerSessions + unifiedSessions
        
        let newStores = ConversationStores(
            messages: runner.messages,
            taskSessions: mergedSessions,
            tracesByID: runner.messageExecutionTraces,
            currentTrace: runner.currentExecutionTrace,
            isProcessing: runner.isProcessing,
            lastScreenshotPath: runner.lastScreenshotPath,
            activeBrowserSessionID: browserSessionStore.activeSessionID,
            browserSessions: browserSessionStore.sessions
        )
        
        // 只在数据真正变化时更新，避免触发不必要的 SwiftUI 重绘
        if stores != newStores {
            stores = newStores
        }
    }
    private func filteredRunnerSessions(excludingGatewaySessionKeys gatewaySessionKeys: Set<String>) -> [AgentTaskSession] {
        runner.taskSessions.filter { session in
            guard let gatewaySessionKey = session.gatewaySessionKey else {
                return true
            }

            return !gatewaySessionKeys.contains(gatewaySessionKey)
        }
    }

    private func convertUnifiedTasksToSessions() -> [AgentTaskSession] {
        let activeTasks = unifiedTaskManager.tasks.filter { $0.status != .completed }
        let recentCompletedTasks = unifiedTaskManager.tasks
            .filter { $0.status == .completed }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(5)

        let visibleTasks = uniqueTasks(activeTasks + Array(recentCompletedTasks))
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.updatedAt > rhs.updatedAt
            }

        return visibleTasks.map(convertUnifiedTaskToSession)
    }

    private func convertUnifiedTaskToSession(_ task: UnifiedTask) -> AgentTaskSession {
        let sessionID = unifiedSessionID(for: task.id)

        return AgentTaskSession(
            id: sessionID,
            title: task.title,
            originalRequest: task.originalRequest ?? task.inputContext,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            status: taskSessionStatus(for: task),
            statusSummary: taskSessionSummary(for: task),
            mainAgentName: task.assignedAgentName,
            intentName: task.type.displayName,
            isExpanded: true,
            messages: taskSessionMessages(for: task),
            resultSummary: task.result,
            errorMessage: task.errorMessage,
            gatewaySessionKey: task.gatewaySessionKey,
            requestStartedAt: task.startedAt,
            latestAssistantText: latestAssistantText(for: task),
            canResume: canResume(task),
            lastReconciledAt: task.updatedAt,
            dismissedAt: dismissedUnifiedSessionDates[sessionID]
        )
    }

    private func taskSessionStatus(for task: UnifiedTask) -> TaskSessionStatus {
        switch task.status {
        case .pending:
            return task.type == .exceptionRecovery ? .waitingUser : .queued
        case .running:
            return .running
        case .paused:
            return .waitingUser
        case .completed:
            return .completed
        case .failed:
            return .failed
        }
    }

    private func taskSessionSummary(for task: UnifiedTask) -> String {
        if task.status == .failed, let errorMessage = task.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }

        if task.status == .completed, let result = task.result, !result.isEmpty {
            return String(result.prefix(120))
        }

        if let scheduledTime = task.scheduledTime, task.status == .pending {
            return "计划执行于 \(scheduledTime.formatted(date: .abbreviated, time: .shortened))"
        }

        if !task.description.isEmpty {
            return task.description
        }

        if let latestLog = task.logs.last, !latestLog.message.isEmpty {
            return latestLog.message
        }

        if !task.inputContext.isEmpty {
            return String(task.inputContext.prefix(120))
        }

        return task.type.displayName
    }

    private func taskSessionMessages(for task: UnifiedTask) -> [TaskSessionMessage] {
        let mappedMessages = task.messages.map { message in
            TaskSessionMessage(
                id: message.id,
                role: messageRole(for: message.role),
                content: message.content,
                timestamp: message.timestamp,
                agentName: message.agentName
            )
        }

        guard !mappedMessages.isEmpty else {
            return task.logs.suffix(6).map { log in
                TaskSessionMessage(
                    role: .system,
                    content: log.message,
                    timestamp: log.timestamp,
                    agentName: log.source
                )
            }
        }

        return mappedMessages
    }

    private func latestAssistantText(for task: UnifiedTask) -> String? {
        task.messages.last(where: { $0.role == .assistant })?.content
    }

    private func canResume(_ task: UnifiedTask) -> Bool {
        task.status != .running
    }

    private func messageRole(for role: TaskMessage.TaskMessageRole) -> MessageRole {
        switch role {
        case .user:
            return .user
        case .assistant:
            return .assistant
        case .system, .cli:
            return .system
        }
    }

    private func uniqueTasks(_ tasks: [UnifiedTask]) -> [UnifiedTask] {
        var seen = Set<String>()
        return tasks.filter { task in
            seen.insert(task.id).inserted
        }
    }

    private func unifiedSessionID(for taskID: String) -> String {
        "\(unifiedSessionPrefix)\(taskID)"
    }

    private func unifiedTaskID(from sessionID: String) -> String? {
        guard sessionID.hasPrefix(unifiedSessionPrefix) else { return nil }
        return String(sessionID.dropFirst(unifiedSessionPrefix.count))
    }

    private func isUnifiedTaskSession(_ sessionID: String) -> Bool {
        unifiedTaskID(from: sessionID) != nil
    }
}
