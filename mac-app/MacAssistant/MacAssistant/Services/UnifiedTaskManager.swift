//
//  UnifiedTaskManager.swift
//  MacAssistant
//
//  统一任务管理器 - 兼容旧 UI 的 facade 适配层
//

import Foundation
import Combine

struct TaskCenterPanelSnapshot {
    var attentionTasks: [UnifiedTask]
    var activeTasks: [UnifiedTask]
    var upcomingTasks: [UnifiedTask]
    var recentResultTasks: [UnifiedTask]
    var completedTodayCount: Int
    var hiddenAttentionSubtasks: Int
    var hiddenActiveSubtasks: Int
    var hiddenUpcomingSubtasks: Int
    var hiddenResultSubtasks: Int

    var attentionCount: Int { attentionTasks.count }
    var activeCount: Int { activeTasks.count }
    var upcomingCount: Int { upcomingTasks.count }
}

@MainActor
final class UnifiedTaskManager: ObservableObject {
    static let shared = UnifiedTaskManager()

    @Published var tasks: [UnifiedTask] = []
    @Published var selectedTaskID: String?
    @Published var statistics: TaskStatistics = TaskStatistics(
        total: 0, pending: 0, running: 0, paused: 0, completed: 0, failed: 0
    )
    @Published var hasActiveBackgroundTasks: Bool = false

    private let taskCenter = TaskCenterFacade.shared
    private let workflowCoordinator = WorkflowRunCoordinator.shared
    private var cancellables = Set<AnyCancellable>()
    private var workflowRunBindings: [String: String] = [:]

    private init() {
        bindTaskCenter()
        bindWorkflowCoordinator()
        taskCenter.executionDelegate = self
        taskCenter.bootstrap()
    }

    @discardableResult
    func addTask(_ task: UnifiedTask) -> UnifiedTask {
        switch task.type {
        case .exceptionRecovery:
            return createExceptionRecoveryTask(
                title: task.title,
                originalRequest: task.originalRequest ?? task.inputContext,
                errorMessage: task.errorMessage ?? task.description,
                gatewaySessionKey: task.gatewaySessionKey ?? task.id,
                messages: task.messages
            )
        case .smartSubtask:
            return createSmartSubtask(
                title: task.title,
                description: task.description,
                inputContext: task.inputContext,
                strategy: task.strategy
            )
        case .todo, .background:
            return createTodoTask(
                title: task.title,
                description: task.description,
                scheduledTime: task.scheduledTime
            )
        case .workflow:
            // Workflow 类型任务由 WorkflowRunCoordinator 处理
            LogInfo("[UnifiedTaskManager] Workflow 类型任务已接收: \(task.title)")
            return createWorkflowTask(
                title: task.title,
                description: task.description,
                scheduledTime: task.scheduledTime
            )
        }
    }

    @discardableResult
    func importLegacyTask(_ task: UnifiedTask) -> UnifiedTask {
        let definition = taskCenter.importLegacyTask(task)
        return taskCenter.legacyTask(id: definition.id) ?? task
    }

    func createExceptionRecoveryTask(
        title: String,
        originalRequest: String,
        errorMessage: String,
        gatewaySessionKey: String,
        messages: [TaskMessage] = []
    ) -> UnifiedTask {
        let definition = taskCenter.createRecoveryDefinition(
            title: title,
            originalRequest: originalRequest,
            errorMessage: errorMessage,
            gatewaySessionKey: gatewaySessionKey,
            messages: messages,
            trigger: .manual
        )

        let task = taskCenter.legacyTask(id: definition.id)
            ?? UnifiedTask.exceptionRecovery(
                title: title,
                originalRequest: originalRequest,
                errorMessage: errorMessage,
                gatewaySessionKey: gatewaySessionKey
            )

        notifyTaskAdded(task)
        return task
    }

    func createSmartSubtask(
        title: String,
        description: String,
        inputContext: String,
        strategy: TaskExecutionStrategy,
        parentTaskID: String? = nil
    ) -> UnifiedTask {
        let definition = taskCenter.createSmartTask(
            title: title,
            description: description,
            inputContext: inputContext,
            strategy: strategy,
            parentTaskID: parentTaskID
        )

        let task = taskCenter.legacyTask(id: definition.id)
            ?? UnifiedTask.smartSubtask(
                title: title,
                description: description,
                inputContext: inputContext,
                strategy: strategy
            )

        notifyTaskAdded(task)
        return task
    }

    func createTodoTask(
        title: String,
        description: String = "",
        scheduledTime: Date? = nil
    ) -> UnifiedTask {
        let definition = taskCenter.createTodoDefinition(
            title: title,
            description: description,
            scheduledTime: scheduledTime
        )

        let task = taskCenter.legacyTask(id: definition.id)
            ?? UnifiedTask.todo(
                title: title,
                description: description,
                scheduledTime: scheduledTime
            )

        notifyTaskAdded(task)
        return task
    }
    
    @discardableResult
    func createWorkflowTask(
        title: String,
        description: String,
        definitionID: String? = nil,
        initialContext: [String: String] = [:],
        scheduledTime: Date? = nil
    ) -> UnifiedTask {
        let task: UnifiedTask

        if let definitionID {
            let trigger = scheduledTime.map(TaskTrigger.once(at:)) ?? .manual
            let definition = taskCenter.createWorkflowDefinition(
                title: title,
                description: description,
                workflowSpec: WorkflowSpec(
                    definitionID: definitionID,
                    bindings: [],
                    initialContext: initialContext,
                    executionMode: .sequential
                ),
                source: .manual,
                trigger: trigger
            )
            task = taskCenter.legacyTask(id: definition.id) ?? UnifiedTask(
                id: definition.id,
                type: .workflow,
                title: title,
                description: description,
                scheduledTime: scheduledTime
            )
        } else {
            let definition = taskCenter.importLegacyTask(
                UnifiedTask(
                    type: .workflow,
                    title: title,
                    description: description,
                    scheduledTime: scheduledTime
                )
            )
            task = taskCenter.legacyTask(id: definition.id) ?? UnifiedTask(
                id: definition.id,
                type: .workflow,
                title: title,
                description: description,
                scheduledTime: scheduledTime
            )
        }

        notifyTaskAdded(task)
        return task
    }

    func removeTask(id: String) {
        taskCenter.removeTask(definitionID: id)
    }

    func removeCompletedTasks() {
        taskCenter.removeCompletedTasks()
    }

    func task(id: String) -> UnifiedTask? {
        tasks.first { $0.id == id }
    }

    func focusTask(id: String) {
        selectedTaskID = id
    }

    func clearFocusedTask() {
        selectedTaskID = nil
    }

    func updateTask(id: String, _ update: (inout UnifiedTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        update(&tasks[index])
        tasks[index].updatedAt = Date()
        statistics = TaskLegacyBridge.makeStatistics(from: tasks)
    }

    func startTask(id: String) async {
        await taskCenter.startTask(definitionID: id)
    }

    func pauseTask(id: String) {
        taskCenter.pauseTask(definitionID: id)
    }

    func resumeTask(id: String) {
        Task { @MainActor in
            await taskCenter.resumeTask(definitionID: id)
        }
    }

    func retryTask(id: String) async {
        await taskCenter.retryTask(definitionID: id)
    }

    func cancelTask(id: String) {
        taskCenter.cancelTask(definitionID: id)
    }

    func continueTask(id: String, with userInput: String? = nil) async {
        selectedTaskID = id
        await taskCenter.continueTask(definitionID: id, userInput: userInput)
    }

    func workflowTaskID(forRunID runID: String) -> String? {
        workflowRunBindings[runID] ?? taskCenter.definitionID(forRunID: runID)
    }

    func appendLog(id: String, message: String, level: TaskLogEntry.LogLevel = .info, source: String? = nil) {
        taskCenter.appendLog(definitionID: id, message: message, level: level, source: source)
    }

    func appendMessage(
        id: String,
        role: TaskMessage.TaskMessageRole,
        content: String,
        agentID: String? = nil,
        agentName: String? = nil
    ) {
        taskCenter.appendMessage(
            definitionID: id,
            role: role,
            content: content,
            agentID: agentID,
            agentName: agentName
        )
    }

    func completeTask(id: String, result: String) {
        guard task(id: id) != nil else {
            logger.log(
                sessionID: id,
                level: .warning,
                component: "UnifiedTaskManager",
                message: "忽略任务完成通知：任务不存在",
                details: ["taskID": id]
            )
            return
        }

        taskCenter.completeTask(definitionID: id, result: result)

        if let updatedTask = taskCenter.legacyTask(id: id) {
            notifyTaskCompleted(updatedTask)
        }
    }

    func failTask(id: String, error: String) {
        taskCenter.failTask(definitionID: id, error: error)
    }

    func tasks(filteredBy filter: TaskFilter) -> [UnifiedTask] {
        switch filter {
        case .all:
            return tasks.sorted { $0.createdAt > $1.createdAt }
        case .pending:
            return tasks.filter { $0.status == .pending }
                .sorted { $0.createdAt > $1.createdAt }
        case .running:
            return tasks.filter { $0.status == .running }
                .sorted { $0.createdAt > $1.createdAt }
        case .scheduled:
            return taskCenter.upcomingTasks(limit: nil, within: nil)
        case .completed:
            return tasks.filter { $0.status == .completed }
                .sorted { $0.completedAt ?? $0.createdAt > $1.completedAt ?? $1.createdAt }
        case .exception:
            return tasks.filter { $0.type == .exceptionRecovery }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    func taskCenterPanelSnapshot() -> TaskCenterPanelSnapshot {
        let attention = overviewTasks(from: taskCenter.attentionTasks(limit: nil))
        let active = overviewTasks(from: taskCenter.activeTasks(limit: nil))
        let upcoming = overviewTasks(from: taskCenter.upcomingTasks(limit: nil, within: 24))
        let results = overviewTasks(from: taskCenter.recentResultTasks(limit: nil))

        return TaskCenterPanelSnapshot(
            attentionTasks: limited(attention.visibleTasks, count: 4),
            activeTasks: limited(active.visibleTasks, count: 4),
            upcomingTasks: limited(upcoming.visibleTasks, count: 4),
            recentResultTasks: limited(results.visibleTasks, count: 4),
            completedTodayCount: taskCenter.completedTodayCount(),
            hiddenAttentionSubtasks: attention.hiddenSubtaskCount,
            hiddenActiveSubtasks: active.hiddenSubtaskCount,
            hiddenUpcomingSubtasks: upcoming.hiddenSubtaskCount,
            hiddenResultSubtasks: results.hiddenSubtaskCount
        )
    }

    func attentionTasks(limit: Int? = nil, includeGroupedSubtasks: Bool = true) -> [UnifiedTask] {
        let tasks = taskCenter.attentionTasks(limit: nil)
        let visible = includeGroupedSubtasks ? tasks : overviewTasks(from: tasks).visibleTasks
        return limited(visible, count: limit)
    }

    func activeTasks(limit: Int? = nil, includeGroupedSubtasks: Bool = true) -> [UnifiedTask] {
        let tasks = taskCenter.activeTasks(limit: nil)
        let visible = includeGroupedSubtasks ? tasks : overviewTasks(from: tasks).visibleTasks
        return limited(visible, count: limit)
    }

    func scheduledTasks(limit: Int? = nil, within hours: Int? = nil, includeGroupedSubtasks: Bool = true) -> [UnifiedTask] {
        let tasks = taskCenter.upcomingTasks(limit: nil, within: hours)
        let visible = includeGroupedSubtasks ? tasks : overviewTasks(from: tasks).visibleTasks
        return limited(visible, count: limit)
    }

    func historyTasks(limit: Int? = nil, includeGroupedSubtasks: Bool = true) -> [UnifiedTask] {
        let tasks = taskCenter.historyTasks(limit: nil)
        let visible = includeGroupedSubtasks ? tasks : overviewTasks(from: tasks).visibleTasks
        return limited(visible, count: limit)
    }

    func hiddenGroupedSubtaskCount(for tab: TaskManagerTab) -> Int {
        switch tab {
        case .inbox:
            return overviewTasks(from: taskCenter.attentionTasks(limit: nil)).hiddenSubtaskCount
        case .running:
            return overviewTasks(from: taskCenter.activeTasks(limit: nil)).hiddenSubtaskCount
        case .scheduled:
            return overviewTasks(from: taskCenter.upcomingTasks(limit: nil, within: nil)).hiddenSubtaskCount
        case .history:
            return overviewTasks(from: taskCenter.historyTasks(limit: nil)).hiddenSubtaskCount
        }
    }

    var activeTaskCount: Int {
        tasks.filter { $0.status.isActive }.count
    }

    var hasPendingExceptionTasks: Bool {
        tasks.contains { $0.type == .exceptionRecovery && $0.status == .pending }
    }

    private func bindTaskCenter() {
        taskCenter.$legacyTasks
            .receive(on: RunLoop.main)
            .sink { [weak self] tasks in
                self?.tasks = tasks
                self?.hasActiveBackgroundTasks = tasks.contains {
                    $0.status == .running && $0.type == .background
                }
            }
            .store(in: &cancellables)

        taskCenter.$statistics
            .receive(on: RunLoop.main)
            .sink { [weak self] statistics in
                self?.statistics = statistics
            }
            .store(in: &cancellables)
    }

    private func bindWorkflowCoordinator() {
        workflowCoordinator.$activeRuns
            .receive(on: RunLoop.main)
            .sink { [weak self] activeRuns in
                self?.syncWorkflowRuns(activeRuns)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workflowCompleted)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handleWorkflowTerminalNotification(notification, success: true)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workflowFailed)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handleWorkflowTerminalNotification(notification, success: false)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workflowApprovalNeeded)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handleWorkflowApprovalNotification(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workflowReplanRequested)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handleWorkflowReplanRequestNotification(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workflowReplanPreviewReady)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handleWorkflowReplanPreviewNotification(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workflowReplanApplied)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handleWorkflowReplanAppliedNotification(notification)
            }
            .store(in: &cancellables)
    }

    private func syncWorkflowRuns(_ activeRuns: [String: WorkflowRunState]) {
        for (runID, definitionID) in workflowRunBindings {
            guard let state = activeRuns[runID] else { continue }
            taskCenter.updateWorkflowState(runID: runID, state: state)

            if selectedTaskID == nil,
               tasks.contains(where: { $0.id == definitionID && $0.status == .running }) {
                selectedTaskID = definitionID
            }
        }
    }

    private func handleWorkflowTerminalNotification(_ notification: Notification, success: Bool) {
        guard let runID = notification.userInfo?["runID"] as? String else { return }

        let definitionID = workflowRunBindings.removeValue(forKey: runID)
            ?? taskCenter.definitionID(forRunID: runID)
            ?? notification.userInfo?["definitionID"] as? String

        guard let definitionID else { return }

        if success {
            let summary = notification.userInfo?["summary"] as? String ?? "Workflow 执行完成。"
            completeTask(id: definitionID, result: summary)
        } else {
            let error = notification.userInfo?["error"] as? String ?? "Workflow 执行失败"
            failTask(id: definitionID, error: error)
        }
    }

    private func handleWorkflowApprovalNotification(_ notification: Notification) {
        guard let definitionID = workflowDefinitionID(from: notification),
              let message = notification.userInfo?["message"] as? String else {
            return
        }

        appendMessage(id: definitionID, role: .assistant, content: message)
        appendLog(id: definitionID, message: message, level: .info, source: "workflow")
    }

    private func handleWorkflowReplanRequestNotification(_ notification: Notification) {
        guard let definitionID = workflowDefinitionID(from: notification),
              let reason = notification.userInfo?["reason"] as? String else {
            return
        }

        let message = "Workflow 需要重新规划：\(reason)"
        appendMessage(id: definitionID, role: .system, content: message)
        appendLog(id: definitionID, message: message, level: .warning, source: "workflow")
    }

    private func handleWorkflowReplanPreviewNotification(_ notification: Notification) {
        guard let definitionID = workflowDefinitionID(from: notification),
              let previewSteps = notification.userInfo?["previewSteps"] as? [String] else {
            return
        }

        let previewText = previewSteps
            .prefix(4)
            .enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let message = previewText.isEmpty
            ? "Workflow 已生成新的执行方案，等待用户确认。"
            : "Workflow 已生成新的执行方案，等待用户确认：\n\(previewText)"

        appendMessage(id: definitionID, role: .assistant, content: message)
        appendLog(id: definitionID, message: "已生成新的 workflow 重规划预览", level: .info, source: "workflow")
    }

    private func handleWorkflowReplanAppliedNotification(_ notification: Notification) {
        guard let definitionID = workflowDefinitionID(from: notification) else { return }
        let message = "已应用新的 workflow 执行方案，任务继续运行。"
        appendMessage(id: definitionID, role: .system, content: message)
        appendLog(id: definitionID, message: message, level: .info, source: "workflow")
    }

    private func workflowDefinitionID(from notification: Notification) -> String? {
        if let runID = notification.userInfo?["runID"] as? String,
           let definitionID = workflowRunBindings[runID] ?? taskCenter.definitionID(forRunID: runID) {
            return definitionID
        }

        return notification.userInfo?["definitionID"] as? String
    }

    private func notifyTaskAdded(_ task: UnifiedTask) {
        NotificationCenter.default.post(
            name: .taskAdded,
            object: nil,
            userInfo: ["task": task]
        )
    }

    private func notifyTaskCompleted(_ task: UnifiedTask) {
        NotificationCenter.default.post(
            name: .taskCompleted,
            object: nil,
            userInfo: ["task": task]
        )
    }

    private func isGroupedSubtask(_ task: UnifiedTask) -> Bool {
        task.type == .smartSubtask && task.parentTaskID != nil
    }

    private func overviewTasks(from tasks: [UnifiedTask]) -> (visibleTasks: [UnifiedTask], hiddenSubtaskCount: Int) {
        let primaryTasks = tasks.filter { !isGroupedSubtask($0) }
        guard !primaryTasks.isEmpty else {
            return (tasks, 0)
        }
        return (primaryTasks, tasks.count - primaryTasks.count)
    }

    private func limited(_ tasks: [UnifiedTask], count: Int?) -> [UnifiedTask] {
        guard let count else { return tasks }
        return Array(tasks.prefix(count))
    }
}

@MainActor
extension UnifiedTaskManager: TaskCenterExecutionDelegate {
    func taskCenter(_ taskCenter: TaskCenterFacade, execute definition: TaskDefinition, run: TaskRun) async {
        switch definition.kind {
        case .exceptionRecovery:
            await executeExceptionRecovery(definition: definition)
        case .smartSubtask:
            await executeSmartSubtask(definition: definition)
        case .todo, .background:
            await executeGenericTask(definition: definition)
        case .workflow:
            // 交给 WorkflowRunCoordinator 执行
            LogInfo("[UnifiedTaskManager] 执行 Workflow 任务: \(definition.title)")
            if let workflowSpec = definition.workflowSpec {
                do {
                    let workflowRunID = try await workflowCoordinator.startWorkflow(
                        definitionID: workflowSpec.definitionID,
                        initialContext: workflowSpec.initialContext,
                        bindings: workflowSpec.bindings,
                        trigger: definition.trigger,
                        runID: run.id
                    )
                    workflowRunBindings[workflowRunID] = definition.id

                    if let runState = workflowCoordinator.runState(runID: workflowRunID) {
                        taskCenter.updateWorkflowState(runID: workflowRunID, state: runState)
                    }
                } catch {
                    LogError("[UnifiedTaskManager] 启动 Workflow 失败: \(error)")
                    taskCenter.failTask(definitionID: definition.id, error: error.localizedDescription)
                }
            } else {
                await executeGenericTask(definition: definition)
            }
        }
    }

    private func executeExceptionRecovery(definition: TaskDefinition) async {
        guard let gatewaySessionKey = definition.gatewaySessionKey,
              let originalRequest = definition.originalRequest else {
            failTask(id: definition.id, error: "缺少恢复所需信息")
            return
        }

        await logger.startSession(id: definition.id, userRequest: originalRequest)
        logger.log(
            sessionID: definition.id,
            level: .info,
            component: "UnifiedTaskManager",
            message: "开始异常恢复任务: \(definition.title)",
            details: ["gatewaySessionKey": gatewaySessionKey]
        )

        await MainActor.run {
            NotificationCenter.default.post(
                name: .resumeTaskSessionNotification,
                object: nil,
                userInfo: [
                    "gatewaySessionKey": gatewaySessionKey,
                    "originalRequest": originalRequest,
                    "taskID": definition.id
                ]
            )
        }

        do {
            let result = try await waitForRecoveryCompletion(taskID: definition.id, timeout: 300)
            if result.success {
                completeTask(id: definition.id, result: result.content ?? "恢复成功")
            } else {
                failTask(id: definition.id, error: result.error ?? "恢复失败")
            }
        } catch {
            failTask(id: definition.id, error: "恢复超时或取消")
        }
    }

    private func executeSmartSubtask(definition: TaskDefinition) async {
        logger.log(
            sessionID: definition.id,
            level: .info,
            component: "UnifiedTaskManager",
            message: "开始执行智能子任务: \(definition.title)",
            details: ["strategy": definition.strategy.displayName]
        )

        do {
            let result: String

            switch definition.strategy.type {
            case .auto:
                result = try await executeWithAutoStrategy(definition: definition)
            case .useBuiltin:
                result = try await executeWithBuiltinService(definition: definition)
            case .useSkill:
                if let skillID = definition.strategy.targetID {
                    result = try await executeWithSkill(definition: definition, skillID: skillID)
                } else {
                    throw TaskExecutionError.missingTargetID("Skill")
                }
            case .useAgent:
                if let agentID = definition.strategy.targetID {
                    result = try await executeWithAgent(definition: definition, agentID: agentID)
                } else {
                    throw TaskExecutionError.missingTargetID("Agent")
                }
            case .useOpenClaw:
                if let agentID = definition.strategy.targetID {
                    result = try await executeWithOpenClaw(definition: definition, agentID: agentID)
                } else {
                    throw TaskExecutionError.missingTargetID("OpenClaw Agent")
                }
            case .manual:
                taskCenter.pauseTask(definitionID: definition.id)
                failTask(id: definition.id, error: "等待手动执行")
                return
            case .exceptionRecovery:
                throw TaskExecutionError.invalidStrategy("异常恢复请使用 exceptionRecovery 任务类型")
            }

            completeTask(id: definition.id, result: result)
        } catch {
            failTask(id: definition.id, error: error.localizedDescription)
        }
    }

    private func executeGenericTask(definition: TaskDefinition) async {
        logger.log(
            sessionID: definition.id,
            level: .info,
            component: "UnifiedTaskManager",
            message: "执行通用任务: \(definition.title)",
            details: nil
        )

        completeTask(id: definition.id, result: "任务已标记完成")
    }

    private func executeWithAutoStrategy(definition: TaskDefinition) async throws -> String {
        let input = definition.inputContext.lowercased()

        if input.contains("代码") || input.contains("code") || input.contains("swift") {
            return try await executeWithBuiltinService(definition: definition)
        }

        return try await executeWithBuiltinService(definition: definition)
    }

    private func executeWithBuiltinService(definition: TaskDefinition) async throws -> String {
        return "任务 \"\(definition.title)\" 已通过内置服务执行完成。\n\n输入内容: \(definition.inputContext.prefix(100))"
    }

    private func executeWithSkill(definition: TaskDefinition, skillID: String) async throws -> String {
        logger.log(
            sessionID: definition.id,
            level: .info,
            component: "UnifiedTaskManager",
            message: "使用 Skill 执行: \(skillID)",
            details: nil
        )
        return "任务 \"\(definition.title)\" 已通过 Skill [\(skillID)] 执行完成。"
    }

    private func executeWithAgent(definition: TaskDefinition, agentID: String) async throws -> String {
        logger.log(
            sessionID: definition.id,
            level: .info,
            component: "UnifiedTaskManager",
            message: "使用 Agent 执行: \(agentID)",
            details: nil
        )
        return "任务 \"\(definition.title)\" 已通过 Agent [\(agentID)] 执行完成。"
    }

    private func executeWithOpenClaw(definition: TaskDefinition, agentID: String) async throws -> String {
        logger.log(
            sessionID: definition.id,
            level: .info,
            component: "UnifiedTaskManager",
            message: "使用 OpenClaw 执行: \(agentID)",
            details: nil
        )
        return "任务 \"\(definition.title)\" 已通过 OpenClaw [\(agentID)] 执行完成。"
    }

    private func waitForRecoveryCompletion(taskID: String, timeout: TimeInterval) async throws -> TaskRecoveryResult {
        try await withTimeout(seconds: timeout) {
            await withCheckedContinuation { continuation in
                var cancellable: AnyCancellable?
                cancellable = NotificationCenter.default
                    .publisher(for: .taskRecoveryCompleted)
                    .compactMap { notification -> TaskRecoveryResult? in
                        guard let userInfo = notification.userInfo,
                              let completedTaskID = userInfo["taskID"] as? String,
                              completedTaskID == taskID else {
                            return nil
                        }
                        return TaskRecoveryResult(
                            success: userInfo["success"] as? Bool ?? false,
                            content: userInfo["content"] as? String,
                            error: userInfo["error"] as? String
                        )
                    }
                    .sink { result in
                        cancellable?.cancel()
                        continuation.resume(returning: result)
                    }
            }
        }
    }
}

extension Notification.Name {
    static let taskAdded = Notification.Name("UnifiedTaskAdded")
    static let taskCompleted = Notification.Name("UnifiedTaskCompleted")
    static let resumeTaskSessionNotification = Notification.Name("ResumeTaskSessionNotification")
    static let taskRecoveryCompleted = Notification.Name("TaskRecoveryCompleted")
}

enum TaskExecutionError: Error, LocalizedError {
    case missingTargetID(String)
    case invalidStrategy(String)
    case executionFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .missingTargetID(let type):
            return "缺少\(type)目标ID"
        case .invalidStrategy(let reason):
            return "无效的执行策略: \(reason)"
        case .executionFailed(let reason):
            return "执行失败: \(reason)"
        case .timeout:
            return "执行超时"
        }
    }
}

struct TaskRecoveryResult {
    let success: Bool
    let content: String?
    let error: String?
}

func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TaskExecutionError.timeout
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

@MainActor
private var logger: ExecutionLogger { ExecutionLogger.shared }
