//
//  TaskCenterFacade.swift
//  MacAssistant
//
//  新任务系统统一入口
//

import Foundation
import Combine

@MainActor
protocol TaskCenterExecutionDelegate: AnyObject {
    func taskCenter(_ taskCenter: TaskCenterFacade, execute definition: TaskDefinition, run: TaskRun) async
}

@MainActor
final class TaskCenterFacade: ObservableObject {
    static let shared = TaskCenterFacade()

    @Published private(set) var definitions: [TaskDefinition] = []
    @Published private(set) var runs: [TaskRun] = []
    @Published private(set) var legacyTasks: [UnifiedTask] = []
    @Published private(set) var statistics: TaskStatistics = TaskStatistics(
        total: 0, pending: 0, running: 0, paused: 0, completed: 0, failed: 0
    )

    weak var executionDelegate: TaskCenterExecutionDelegate?

    private let store: TaskStore
    private let scheduler: TaskScheduler
    private let workflowDefinitionStore = WorkflowDefinitionStore.shared
    private var didBootstrap = false

    private init(
        store: TaskStore? = nil,
        scheduler: TaskScheduler? = nil
    ) {
        self.store = store ?? TaskStore.shared
        self.scheduler = scheduler ?? TaskScheduler.shared
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        definitions = store.definitions
        runs = store.runs
        rebuildLegacySnapshots()

        scheduler.runsProvider = { [weak self] in
            self?.runs ?? []
        }
        scheduler.onRunDue = { [weak self] runID in
            Task { @MainActor in
                await self?.triggerDueRun(runID: runID)
            }
        }
        scheduler.bootstrap()
    }

    func legacyTask(id: String) -> UnifiedTask? {
        legacyTasks.first { $0.id == id }
    }

    func attentionTasks(limit: Int? = nil) -> [UnifiedTask] {
        let now = Date()
        let sorted = definitions.compactMap { definition -> (task: UnifiedTask, priority: Int, date: Date)? in
            guard let task = legacyTask(id: definition.id) else { return nil }
            let run = preferredRun(for: definition.id)

            guard needsAttention(definition: definition, task: task, run: run, now: now) else {
                return nil
            }

            return (task, attentionPriority(for: definition, task: task, run: run), run?.updatedAt ?? task.updatedAt)
        }
        .sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.date > rhs.date
        }
        .map(\.task)

        return limited(sorted, count: limit)
    }

    func activeTasks(limit: Int? = nil) -> [UnifiedTask] {
        let sorted = definitions.compactMap { definition -> (task: UnifiedTask, date: Date)? in
            guard let task = legacyTask(id: definition.id),
                  let run = preferredRun(for: definition.id),
                  run.phase == .queued || run.phase == .running else {
                return nil
            }

            return (task, run.updatedAt)
        }
        .sorted { $0.date > $1.date }
        .map(\.task)

        return limited(sorted, count: limit)
    }

    func upcomingTasks(limit: Int? = nil, within hours: Int? = 24) -> [UnifiedTask] {
        let now = Date()
        let horizon = hours.map { now.addingTimeInterval(TimeInterval($0 * 3600)) }

        let sorted = definitions.compactMap { definition -> (task: UnifiedTask, date: Date)? in
            guard let task = legacyTask(id: definition.id),
                  let run = preferredRun(for: definition.id),
                  let nextDate = upcomingDate(for: definition, run: run),
                  nextDate > now else {
                return nil
            }

            if let horizon, nextDate > horizon {
                return nil
            }

            switch run.phase {
            case .scheduled, .retryWaiting:
                return (task, nextDate)
            default:
                if definition.nextRunAt != nil {
                    return (task, nextDate)
                }
                return nil
            }
        }
        .sorted { $0.date < $1.date }
        .map(\.task)

        return limited(sorted, count: limit)
    }

    func recentResultTasks(limit: Int? = nil) -> [UnifiedTask] {
        let sorted = definitions.compactMap { definition -> (task: UnifiedTask, date: Date)? in
            guard let task = legacyTask(id: definition.id),
                  let run = latestSuccessfulRun(for: definition.id) else {
                return nil
            }

            return (task, run.finishedAt ?? run.updatedAt)
        }
        .sorted { $0.date > $1.date }
        .map(\.task)

        return limited(sorted, count: limit)
    }

    func historyTasks(limit: Int? = nil) -> [UnifiedTask] {
        let sorted = definitions.compactMap { definition -> (task: UnifiedTask, date: Date)? in
            guard let task = legacyTask(id: definition.id),
                  let run = latestTerminalRun(for: definition.id) else {
                return nil
            }

            return (task, run.finishedAt ?? run.updatedAt)
        }
        .sorted { $0.date > $1.date }
        .map(\.task)

        return limited(sorted, count: limit)
    }

    func completedTodayCount() -> Int {
        let calendar = Calendar.current
        return legacyTasks.filter { task in
            guard task.status == .completed else { return false }
            let reference = task.completedAt ?? task.updatedAt
            return calendar.isDateInToday(reference)
        }.count
    }

    @discardableResult
    func importLegacyTask(_ task: UnifiedTask) -> TaskDefinition {
        if let existing = definition(id: task.id) {
            return existing
        }

        let trigger = importedTrigger(for: task)
        var definition = TaskDefinition(
            id: task.id,
            title: task.title,
            description: task.description,
            kind: importedKind(for: task.type),
            source: importedSource(for: task.type),
            state: task.status == .paused ? .paused : .enabled,
            assignedAgentID: task.assignedAgentID,
            assignedAgentName: task.assignedAgentName,
            strategy: task.strategy,
            inputContext: task.inputContext,
            messages: task.messages,
            logs: task.logs,
            canResume: task.canResume,
            gatewaySessionKey: task.gatewaySessionKey,
            originalRequest: task.originalRequest,
            trigger: trigger,
            policy: importedPolicy(for: task),
            parentTaskID: task.parentTaskID
        )
        definition.createdAt = task.createdAt
        definition.updatedAt = task.updatedAt
        definition.lastRunAt = task.completedAt ?? task.startedAt
        definition.nextRunAt = task.status == .pending ? task.scheduledTime : nil

        upsert(definition)

        if let importedRun = importedRun(for: task) {
            upsert(importedRun)
        }

        return definition
    }

    @discardableResult
    func createRecoveryDefinition(
        title: String,
        originalRequest: String,
        errorMessage: String,
        gatewaySessionKey: String,
        messages: [TaskMessage] = [],
        trigger: TaskTrigger = .manual
    ) -> TaskDefinition {
        let now = Date()
        let nextRunAt = trigger.nextRunDate(from: now)

        if let existingIndex = definitions.firstIndex(where: {
            $0.kind == .exceptionRecovery && $0.gatewaySessionKey == gatewaySessionKey
        }) {
            var definition = definitions[existingIndex]
            definition.title = title
            definition.description = errorMessage
            definition.source = .recovery
            definition.state = .enabled
            definition.inputContext = originalRequest
            definition.originalRequest = originalRequest
            definition.gatewaySessionKey = gatewaySessionKey
            definition.messages = messages
            definition.canResume = true
            definition.trigger = trigger
            definition.nextRunAt = nextRunAt
            definition.updatedAt = now
            upsert(definition)

            if let nextRunAt {
                ensureScheduledRun(for: definition.id, at: nextRunAt)
            }

            return definition
        }

        var definition = TaskDefinition(
            title: title,
            description: errorMessage,
            kind: .exceptionRecovery,
            source: .recovery,
            strategy: .exceptionRecovery,
            inputContext: originalRequest,
            messages: messages,
            canResume: true,
            gatewaySessionKey: gatewaySessionKey,
            originalRequest: originalRequest,
            trigger: trigger,
            policy: .default
        )
        definition.nextRunAt = nextRunAt

        upsert(definition)

        if let nextRunAt {
            ensureScheduledRun(for: definition.id, at: nextRunAt)
        }

        return definition
    }

    @discardableResult
    func createSmartTask(
        title: String,
        description: String,
        inputContext: String,
        strategy: TaskExecutionStrategy,
        parentTaskID: String? = nil,
        trigger: TaskTrigger = .manual
    ) -> TaskDefinition {
        var definition = TaskDefinition(
            title: title,
            description: description,
            kind: .smartSubtask,
            source: .chat,
            strategy: strategy,
            inputContext: inputContext,
            trigger: trigger,
            parentTaskID: parentTaskID
        )
        definition.nextRunAt = trigger.nextRunDate(from: Date())

        upsert(definition)

        if let nextRunAt = definition.nextRunAt {
            ensureScheduledRun(for: definition.id, at: nextRunAt)
        }

        return definition
    }

    @discardableResult
    func createTodoDefinition(
        title: String,
        description: String = "",
        scheduledTime: Date? = nil
    ) -> TaskDefinition {
        let trigger = scheduledTime.map(TaskTrigger.once(at:)) ?? .manual
        var definition = TaskDefinition(
            title: title,
            description: description,
            kind: .todo,
            source: .manual,
            strategy: .manual,
            inputContext: description,
            trigger: trigger
        )
        definition.nextRunAt = scheduledTime

        upsert(definition)

        if let scheduledTime {
            ensureScheduledRun(for: definition.id, at: scheduledTime)
        }

        return definition
    }

    @discardableResult
    func createWorkflowDefinition(
        title: String,
        description: String = "",
        workflowSpec: WorkflowSpec,
        source: TaskDefinitionSource = .manual,
        trigger: TaskTrigger = .manual
    ) -> TaskDefinition {
        var definition = TaskDefinition(
            title: title,
            description: description,
            kind: .workflow,
            source: source,
            strategy: .auto,
            inputContext: description,
            trigger: trigger,
            workflowSpec: workflowSpec
        )
        definition.nextRunAt = trigger.nextRunDate(from: Date())

        upsert(definition)

        if let nextRunAt = definition.nextRunAt {
            ensureScheduledRun(for: definition.id, at: nextRunAt)
        }

        return definition
    }

    func startTask(definitionID: String) async {
        guard let definition = definition(id: definitionID) else { return }

        if let runningRun = activeRun(for: definitionID), runningRun.phase == .running {
            return
        }

        var run = resumableRun(for: definitionID) ?? TaskRun(definitionID: definitionID, phase: .queued)
        run.queueForExecution()
        run.start(incrementAttempt: run.attempt > 0)
        upsert(run)

        var updatedDefinition = definition
        updatedDefinition.state = .enabled
        updatedDefinition.nextRunAt = nil
        updatedDefinition.updatedAt = Date()
        upsert(updatedDefinition)

        guard let executionDelegate else {
            failTask(definitionID: definitionID, error: "没有可用的任务执行器")
            return
        }

        await executionDelegate.taskCenter(self, execute: updatedDefinition, run: run)
    }

    func pauseTask(definitionID: String) {
        guard var run = activeRun(for: definitionID) else { return }
        run.pause()
        upsert(run)
    }

    func resumeTask(definitionID: String) async {
        await startTask(definitionID: definitionID)
    }

    func retryTask(definitionID: String) async {
        guard let definition = definition(id: definitionID) else { return }

        let latestRunAttempt = latestRun(for: definitionID)?.attempt ?? 0
        var run = TaskRun(definitionID: definitionID, phase: .queued, attempt: latestRunAttempt)
        run.start(incrementAttempt: true)
        upsert(run)

        guard let executionDelegate else {
            failTask(definitionID: definitionID, error: "没有可用的任务执行器")
            return
        }

        await executionDelegate.taskCenter(self, execute: definition, run: run)
    }

    func cancelTask(definitionID: String) {
        guard var run = activeRun(for: definitionID) else { return }
        run.cancel()
        upsert(run)
    }

    func completeTask(definitionID: String, result: String) {
        guard var definition = definition(id: definitionID) else { return }
        guard var run = activeRun(for: definitionID) ?? latestRun(for: definitionID) else { return }

        run.succeed(result: result)
        definition.markRunFinished()
        definition.nextRunAt = nextScheduledDate(for: definition)

        upsert(run)
        upsert(definition)

        if let nextRunAt = definition.nextRunAt {
            ensureScheduledRun(for: definition.id, at: nextRunAt)
        }
    }

    func failTask(definitionID: String, error: String) {
        guard var definition = definition(id: definitionID) else { return }
        guard var run = activeRun(for: definitionID) ?? latestRun(for: definitionID) else { return }

        if run.attempt < definition.policy.maxRetries {
            let nextAttempt = run.attempt + 1
            let delay = definition.policy.retryBackoff.delaySeconds(for: nextAttempt)
            run.queueRetry(after: delay, message: error)
        } else {
            run.fail(message: error)
        }

        definition.markRunFinished()
        definition.updatedAt = Date()

        upsert(run)
        upsert(definition)
    }

    func updateWorkflowState(runID: String, state: WorkflowRunState) {
        guard var run = run(id: runID), !run.phase.isTerminal else { return }

        run.workflowState = state
        run.progress = workflowProgress(for: state)
        run.updatedAt = Date()

        switch workflowPhase(for: state) {
        case .running:
            run.phase = .running
            if run.startedAt == nil {
                run.startedAt = Date()
            }
            run.error = nil

        case .paused:
            run.phase = .paused
            run.error = TaskFailure(message: "Workflow 已暂停", recordedAt: Date())

        case .waitingInput:
            let detail = workflowDetailMessage(for: state) ?? "Workflow 等待更多输入"
            run.phase = .waitingInput
            run.error = TaskFailure(message: detail, recordedAt: Date())

        case .scheduled, .queued, .retryWaiting, .succeeded, .failed, .cancelled:
            break
        }

        upsert(run)

        if var definition = definition(id: run.definitionID) {
            definition.updatedAt = Date()
            upsert(definition)
        }
    }

    func completeWorkflowRun(runID: String, result: String? = nil) {
        guard let run = run(id: runID) else { return }
        let summary = result ?? workflowCompletionSummary(for: run.workflowState) ?? "Workflow 执行完成"
        completeTask(definitionID: run.definitionID, result: summary)
    }

    func failWorkflowRun(runID: String, error: String) {
        guard let run = run(id: runID) else { return }
        failTask(definitionID: run.definitionID, error: error)
    }

    func definitionID(forRunID runID: String) -> String? {
        run(id: runID)?.definitionID
    }

    func continueTask(definitionID: String, userInput: String?) async {
        guard var definition = definition(id: definitionID) else { return }

        let trimmedInput = userInput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedInput.isEmpty {
            definition.messages.append(
                TaskMessage(
                    id: UUID(),
                    role: .user,
                    content: trimmedInput,
                    timestamp: Date(),
                    agentID: nil,
                    agentName: nil
                )
            )

            let mergedInput = mergedInputContext(base: definition.inputContext, addition: trimmedInput)
            definition.inputContext = mergedInput

            if definition.kind == .exceptionRecovery {
                definition.originalRequest = mergedInputContext(
                    base: definition.originalRequest ?? definition.inputContext,
                    addition: trimmedInput
                )
            }

            definition.updatedAt = Date()
            upsert(definition)
        }

        switch legacyTask(id: definitionID)?.status {
        case .running:
            return
        case .completed, .failed:
            await retryTask(definitionID: definitionID)
        case .pending, .paused:
            await startTask(definitionID: definitionID)
        case .none:
            await startTask(definitionID: definitionID)
        }
    }

    func appendLog(
        definitionID: String,
        message: String,
        level: TaskLogEntry.LogLevel = .info,
        source: String? = nil
    ) {
        guard var definition = definition(id: definitionID) else { return }

        definition.logs.append(
            TaskLogEntry(
                id: UUID(),
                timestamp: Date(),
                level: level,
                message: message,
                source: source
            )
        )
        definition.updatedAt = Date()
        upsert(definition)
    }

    func appendMessage(
        definitionID: String,
        role: TaskMessage.TaskMessageRole,
        content: String,
        agentID: String? = nil,
        agentName: String? = nil
    ) {
        guard var definition = definition(id: definitionID) else { return }

        definition.messages.append(
            TaskMessage(
                id: UUID(),
                role: role,
                content: content,
                timestamp: Date(),
                agentID: agentID,
                agentName: agentName
            )
        )
        definition.updatedAt = Date()
        upsert(definition)
    }

    func removeTask(definitionID: String) {
        definitions.removeAll { $0.id == definitionID }
        runs.removeAll { $0.definitionID == definitionID }
        store.replaceDefinitions(definitions)
        store.replaceRuns(runs)
        rebuildLegacySnapshots()
    }

    func removeCompletedTasks() {
        let completedIDs = Set(
            legacyTasks
                .filter { $0.status == .completed }
                .map(\.id)
        )

        guard !completedIDs.isEmpty else { return }

        definitions.removeAll { completedIDs.contains($0.id) }
        runs.removeAll { completedIDs.contains($0.definitionID) }
        store.replaceDefinitions(definitions)
        store.replaceRuns(runs)
        rebuildLegacySnapshots()
    }

    private func triggerDueRun(runID: String) async {
        guard let dueRun = run(id: runID) else { return }
        scheduler.clearSignal(for: runID)
        await startTask(definitionID: dueRun.definitionID)
    }

    private func ensureScheduledRun(for definitionID: String, at date: Date) {
        if let existingIndex = runs.firstIndex(where: {
            $0.definitionID == definitionID && $0.phase == .scheduled
        }) {
            runs[existingIndex].scheduledAt = date
            runs[existingIndex].updatedAt = Date()
            store.replaceRuns(runs)
            rebuildLegacySnapshots()
            return
        }

        let run = TaskRun(
            definitionID: definitionID,
            phase: .scheduled,
            scheduledAt: date
        )
        upsert(run)
    }

    private func nextScheduledDate(for definition: TaskDefinition) -> Date? {
        switch definition.trigger.kind {
        case .manual, .once, .delay, .event:
            return nil
        case .recurring:
            return definition.trigger.nextRunDate(from: Date())
        }
    }

    private func mergedInputContext(base: String, addition: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { return addition }
        return "\(trimmedBase)\n\n补充说明：\(addition)"
    }

    private func workflowProgress(for state: WorkflowRunState) -> TaskProgress {
        let totalSteps = max(
            workflowDefinitionStore.definition(id: state.definitionID)?.steps.count ?? 0,
            state.stepRuns.count,
            1
        )
        let completedSteps = state.stepRuns.filter {
            $0.status == .completed || $0.status == .skipped
        }.count

        return TaskProgress(
            completedUnitCount: completedSteps,
            totalUnitCount: totalSteps,
            detail: workflowDetailMessage(for: state)
        )
    }

    private func workflowPhase(for state: WorkflowRunState) -> RunPhase {
        if state.pendingApproval != nil {
            return .waitingInput
        }

        if let blockingReason = state.blockingReason {
            switch blockingReason {
            case .paused:
                return .paused
            case .waitingUser, .waitingExternal, .waitingApproval:
                return .waitingInput
            case .error, .maxRetriesExceeded:
                return .waitingInput
            }
        }

        return .running
    }

    private func workflowDetailMessage(for state: WorkflowRunState) -> String? {
        if let approval = state.pendingApproval {
            return "等待审批：\(approval.stepName)"
        }

        if let blockingReason = state.blockingReason {
            return blockingReason.displayMessage
        }

        if let activeStepID = state.activeStepID,
           let stepRun = state.stepRuns.last(where: { $0.stepID == activeStepID }) {
            return "执行中：\(stepRun.stepName)"
        }

        if let nextWakeAt = state.nextWakeAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "下次唤醒 \(formatter.localizedString(for: nextWakeAt, relativeTo: Date()))"
        }

        return nil
    }

    private func workflowCompletionSummary(for state: WorkflowRunState?) -> String? {
        guard let state else { return nil }
        let completedSteps = state.stepRuns.filter { $0.status == .completed || $0.status == .skipped }.count
        if completedSteps > 0 {
            return "Workflow 执行完成，共完成 \(completedSteps) 个步骤。"
        }
        return "Workflow 执行完成。"
    }

    private func definition(id: String) -> TaskDefinition? {
        definitions.first { $0.id == id }
    }

    private func run(id: String) -> TaskRun? {
        runs.first { $0.id == id }
    }

    private func latestRun(for definitionID: String) -> TaskRun? {
        runs
            .filter { $0.definitionID == definitionID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    private func preferredRun(for definitionID: String) -> TaskRun? {
        runs
            .filter { $0.definitionID == definitionID }
            .sorted { lhs, rhs in
                if lhs.phase.isActive != rhs.phase.isActive {
                    return lhs.phase.isActive && !rhs.phase.isActive
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    private func activeRun(for definitionID: String) -> TaskRun? {
        runs
            .filter { $0.definitionID == definitionID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first(where: { !$0.phase.isTerminal })
    }

    private func resumableRun(for definitionID: String) -> TaskRun? {
        let candidatePhases: Set<RunPhase> = [.scheduled, .queued, .paused, .waitingInput, .retryWaiting]
        return runs
            .filter { $0.definitionID == definitionID && candidatePhases.contains($0.phase) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    private func importedKind(for type: UnifiedTaskType) -> TaskDefinitionKind {
        switch type {
        case .exceptionRecovery:
            return .exceptionRecovery
        case .smartSubtask:
            return .smartSubtask
        case .todo:
            return .todo
        case .background:
            return .background
        case .workflow:
            return .workflow
        }
    }

    private func importedSource(for type: UnifiedTaskType) -> TaskDefinitionSource {
        switch type {
        case .exceptionRecovery:
            return .recovery
        case .smartSubtask:
            return .chat
        case .todo:
            return .manual
        case .background:
            return .system
        case .workflow:
            return .chat
        }
    }

    private func importedTrigger(for task: UnifiedTask) -> TaskTrigger {
        guard let scheduledTime = task.scheduledTime else {
            return .manual
        }

        return .once(at: scheduledTime)
    }

    private func importedPolicy(for task: UnifiedTask) -> TaskPolicy {
        var policy = TaskPolicy.default
        policy.maxRetries = max(task.maxRetries, 0)
        return policy
    }

    private func importedRun(for task: UnifiedTask) -> TaskRun? {
        let attempt = max(task.retryCount + 1, 1)
        let runID = "imported-run-\(task.id)"

        switch task.status {
        case .pending:
            guard let scheduledTime = task.scheduledTime else {
                return nil
            }

            var run = TaskRun(
                id: runID,
                definitionID: task.id,
                phase: .scheduled,
                attempt: attempt,
                scheduledAt: scheduledTime
            )
            run.updatedAt = task.updatedAt
            return run

        case .running:
            var run = TaskRun(
                id: runID,
                definitionID: task.id,
                phase: .running,
                attempt: attempt
            )
            run.startedAt = task.startedAt ?? task.updatedAt
            run.updatedAt = task.updatedAt
            run.executionTime = task.executionTime
            return run

        case .paused:
            var run = TaskRun(
                id: runID,
                definitionID: task.id,
                phase: .paused,
                attempt: attempt
            )
            run.startedAt = task.startedAt
            run.updatedAt = task.updatedAt
            run.executionTime = task.executionTime
            return run

        case .completed:
            var run = TaskRun(
                id: runID,
                definitionID: task.id,
                phase: .succeeded,
                attempt: attempt
            )
            run.startedAt = task.startedAt
            run.finishedAt = task.completedAt ?? task.updatedAt
            run.output = TaskOutput(summary: task.result)
            run.updatedAt = task.updatedAt
            run.executionTime = task.executionTime
            return run

        case .failed:
            var run = TaskRun(
                id: runID,
                definitionID: task.id,
                phase: .failed,
                attempt: attempt
            )
            run.startedAt = task.startedAt
            run.finishedAt = task.completedAt ?? task.updatedAt
            run.error = TaskFailure(
                message: task.errorMessage ?? "任务执行失败",
                recordedAt: task.updatedAt
            )
            run.updatedAt = task.updatedAt
            run.executionTime = task.executionTime
            return run
        }
    }

    private func upsert(_ definition: TaskDefinition) {
        if let index = definitions.firstIndex(where: { $0.id == definition.id }) {
            definitions[index] = definition
        } else {
            definitions.append(definition)
        }

        store.upsert(definition: definition)
        rebuildLegacySnapshots()
    }

    private func upsert(_ run: TaskRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }

        store.upsert(run: run)
        rebuildLegacySnapshots()
    }

    private func rebuildLegacySnapshots() {
        legacyTasks = TaskLegacyBridge.buildLegacyTasks(definitions: definitions, runs: runs)
        statistics = TaskLegacyBridge.makeStatistics(from: legacyTasks)
    }

    private func latestSuccessfulRun(for definitionID: String) -> TaskRun? {
        runs
            .filter { $0.definitionID == definitionID && $0.phase == .succeeded }
            .sorted { ($0.finishedAt ?? $0.updatedAt) > ($1.finishedAt ?? $1.updatedAt) }
            .first
    }

    private func latestTerminalRun(for definitionID: String) -> TaskRun? {
        runs
            .filter { $0.definitionID == definitionID && $0.phase.isTerminal }
            .sorted { ($0.finishedAt ?? $0.updatedAt) > ($1.finishedAt ?? $1.updatedAt) }
            .first
    }

    private func upcomingDate(for definition: TaskDefinition, run: TaskRun?) -> Date? {
        if let retryDate = run?.nextRetryAt {
            return retryDate
        }
        if let scheduledAt = run?.scheduledAt {
            return scheduledAt
        }
        return definition.nextRunAt
    }

    private func needsAttention(
        definition: TaskDefinition,
        task: UnifiedTask,
        run: TaskRun?,
        now: Date
    ) -> Bool {
        guard definition.state != .archived else { return false }

        if let run {
            switch run.phase {
            case .waitingInput, .failed:
                return true
            case .paused:
                return run.scheduledAt == nil && run.nextRetryAt == nil
            case .scheduled, .retryWaiting:
                return false
            case .queued, .running, .succeeded, .cancelled:
                break
            }
        }

        if definition.kind == .exceptionRecovery && definition.canResume {
            let nextDate = upcomingDate(for: definition, run: run)
            if let nextDate {
                return nextDate <= now
            }
            return true
        }

        return task.status == .failed
    }

    private func attentionPriority(
        for definition: TaskDefinition,
        task: UnifiedTask,
        run: TaskRun?
    ) -> Int {
        guard let run else {
            return definition.kind == .exceptionRecovery ? 2 : 4
        }

        switch run.phase {
        case .waitingInput:
            return 0
        case .failed:
            return 1
        case .paused:
            return definition.kind == .exceptionRecovery ? 2 : 3
        default:
            return task.type == .exceptionRecovery ? 2 : 4
        }
    }

    private func limited(_ tasks: [UnifiedTask], count: Int?) -> [UnifiedTask] {
        guard let count else { return tasks }
        return Array(tasks.prefix(count))
    }
}
