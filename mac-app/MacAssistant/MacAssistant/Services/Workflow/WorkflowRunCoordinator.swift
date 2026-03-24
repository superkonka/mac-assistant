//
//  WorkflowRunCoordinator.swift
//  MacAssistant
//
//  Workflow 执行总控
//

import Foundation
import Combine

@MainActor
final class WorkflowRunCoordinator: ObservableObject {
    static let shared = WorkflowRunCoordinator()
    
    // MARK: - Published State
    
    @Published private(set) var activeRuns: [String: WorkflowRunState] = [:]
    @Published private(set) var isExecuting = false
    private var archivedRuns: [String: WorkflowRunState] = [:]
    private var runtimeBindings: [String: [WorkflowBinding]] = [:]
    private var runtimeDefinitions: [String: WorkflowDefinition] = [:]
    private let maxArchivedRuns = 200
    
    // MARK: - Dependencies
    
    private let definitionStore = WorkflowDefinitionStore.shared
    private let draftService = WorkflowDraftService.shared
    private let executorRegistry = StepExecutorRegistry.shared
    private var cancellables = Set<AnyCancellable>()
    
    // 执行队列
    private var executionQueue: [String] = []
    private var currentRunID: String?
    
    private init() {
        registerDefaultExecutors()
    }
    
    // MARK: - Executor 注册
    
    private func registerDefaultExecutors() {
        executorRegistry.register(BrowserStepExecutor.shared, forID: "browser")
        executorRegistry.register(SkillStepExecutor.shared, forID: "skill")
        executorRegistry.register(ServiceStepExecutor.shared, forID: "service")
        executorRegistry.register(AgentStepExecutor.shared, forID: "agent")
        executorRegistry.register(ApprovalStepExecutor.shared, forID: "approval")
        executorRegistry.register(NotificationStepExecutor.shared, forID: "notification")
        
        LogInfo("[WorkflowRunCoordinator] 已注册默认执行器")
    }
    
    // MARK: - Workflow 启动
    
    /// 启动新的 Workflow Run
    func startWorkflow(
        definitionID: String,
        initialContext: [String: String] = [:],
        bindings: [WorkflowBinding] = [],
        trigger: TaskTrigger = .manual,
        runID: String? = nil
    ) async throws -> String {
        guard let definition = definitionStore.definition(id: definitionID) else {
            throw WorkflowRunError.definitionNotFound
        }
        
        let runID = runID ?? "workflow-\(UUID().uuidString.prefix(8))"
        
        LogInfo("[WorkflowRunCoordinator] 启动 Workflow: \(definition.name), RunID: \(runID)")
        archivedRuns.removeValue(forKey: runID)
        runtimeBindings[runID] = bindings
        runtimeDefinitions.removeValue(forKey: runID)
        
        // 创建初始状态
        let runState = WorkflowRunState(
            definitionID: definitionID,
            activeStepID: definition.steps.first?.id,
            stepRuns: [],
            sharedContext: initialContext,
            pendingApproval: nil,
            blockingReason: nil,
            lastReflectionAt: nil,
            nextWakeAt: nil,
            checkpoints: [
                WorkflowCheckpoint(
                    id: "start-\(runID)",
                    timestamp: Date(),
                    kind: .stepStarted,
                    description: "Workflow 启动",
                    metadata: ["definitionID": definitionID]
                )
            ]
        )
        
        activeRuns[runID] = runState
        
        // 开始执行
        Task {
            await executeWorkflow(runID: runID)
        }
        
        return runID
    }
    
    // MARK: - Workflow 执行
    
    private func executeWorkflow(runID: String) async {
        guard var runState = activeRuns[runID] else {
            LogError("[WorkflowRunCoordinator] 找不到 Run: \(runID)")
            return
        }
        
        guard let definition = workflowDefinition(for: runState, runID: runID) else {
            LogError("[WorkflowRunCoordinator] 找不到 Definition: \(runState.definitionID)")
            activeRuns.removeValue(forKey: runID)
            return
        }
        
        isExecuting = true
        currentRunID = runID
        
        defer {
            isExecuting = false
            currentRunID = nil
        }
        
        LogInfo("[WorkflowRunCoordinator] 开始执行 Workflow Run: \(runID)")

        guard !definition.steps.isEmpty else {
            LogInfo("[WorkflowRunCoordinator] Workflow 无步骤，直接完成: \(runID)")
            await notifyCompletion(runID: runID, success: true)
            return
        }

        var currentIndex = startingStepIndex(for: runState, in: definition)

        while currentIndex < definition.steps.count {
            let step = definition.steps[currentIndex]

            // 检查是否被取消
            guard activeRuns[runID] != nil else {
                LogInfo("[WorkflowRunCoordinator] Workflow 已取消: \(runID)")
                return
            }
            
            // 检查是否阻塞
            if let blockingReason = runState.blockingReason {
                LogInfo("[WorkflowRunCoordinator] Workflow 阻塞: \(blockingReason.displayMessage)")
                await handleBlocking(runID: runID, reason: blockingReason)
                return
            }
            
            // 执行步骤
            let result = await executeStep(step, runID: runID, definition: definition, runState: &runState)
            
            // 更新状态
            activeRuns[runID] = runState
            
            // 处理结果
            switch result {
            case .success(let output):
                LogInfo("[WorkflowRunCoordinator] 步骤成功: \(step.name)")
                runState.sharedContext.merge(output) { _, new in new }
                runState.activeStepID = nextStepID(after: step, in: definition)
                currentIndex = nextStepIndex(after: step, in: definition) ?? definition.steps.count
                
            case .failure(let error):
                LogError("[WorkflowRunCoordinator] 步骤失败: \(step.name), 错误: \(error.message)")
                
                if error.isRetryable && shouldRetry(step: step, runState: runState) {
                    LogInfo("[WorkflowRunCoordinator] 重试步骤: \(step.name)")
                    // 重试逻辑
                    continue
                } else if let onFailureStepID = step.onFailureStepID,
                          let failureIndex = stepIndex(for: onFailureStepID, in: definition) {
                    LogInfo("[WorkflowRunCoordinator] 失败后跳转到步骤: \(onFailureStepID)")
                    runState.activeStepID = onFailureStepID
                    currentIndex = failureIndex
                    activeRuns[runID] = runState
                    continue
                } else {
                    runState.blockingReason = .error(error.message, error.isRetryable)
                    activeRuns[runID] = runState
                    await handleFailure(runID: runID, step: step, error: error)
                    return
                }
                
            case .waiting(let reason):
                LogInfo("[WorkflowRunCoordinator] 步骤等待: \(step.name), 原因: \(reason)")
                runState.blockingReason = .waitingExternal(reason)
                activeRuns[runID] = runState
                return
                
            case .needsApproval(let approval):
                LogInfo("[WorkflowRunCoordinator] 步骤需要审批: \(step.name)")
                runState.pendingApproval = approval
                runState.pendingReplan = nil
                runState.blockingReason = .waitingApproval("等待用户审批: \(step.name)")
                activeRuns[runID] = runState
                await notifyApprovalNeeded(runID: runID, approval: approval)
                return
                
            case .skipped(let reason):
                LogInfo("[WorkflowRunCoordinator] 步骤跳过: \(step.name), 原因: \(reason)")
                runState.activeStepID = nextStepID(after: step, in: definition)
                currentIndex = nextStepIndex(after: step, in: definition) ?? definition.steps.count
                
            case .jump(let toStepID):
                LogInfo("[WorkflowRunCoordinator] 跳转到步骤: \(toStepID)")
                if let jumpIndex = stepIndex(for: toStepID, in: definition) {
                    runState.activeStepID = toStepID
                    currentIndex = jumpIndex
                } else {
                    runState.blockingReason = .error("目标步骤不存在：\(toStepID)", false)
                    activeRuns[runID] = runState
                    await handleFailure(
                        runID: runID,
                        step: step,
                        error: StepExecutionError(
                            code: "STEP_NOT_FOUND",
                            message: "目标步骤不存在：\(toStepID)",
                            isRetryable: false
                        )
                    )
                    return
                }
            }
            
            // 记录检查点
            runState.checkpoints.append(WorkflowCheckpoint(
                id: "step-completed-\(step.id)-\(Date().timeIntervalSince1970)",
                timestamp: Date(),
                kind: .stepCompleted,
                description: "完成步骤: \(step.name)",
                metadata: ["stepID": step.id]
            ))

            activeRuns[runID] = runState
        }
        
        // Workflow 完成
        LogInfo("[WorkflowRunCoordinator] Workflow 完成: \(runID)")
        runState.checkpoints.append(WorkflowCheckpoint(
            id: "completed-\(runID)-\(Date().timeIntervalSince1970)",
            timestamp: Date(),
            kind: .stepCompleted,
            description: "Workflow 执行完成",
            metadata: [:]
        ))
        activeRuns[runID] = runState
        
        // 通知完成
        await notifyCompletion(runID: runID, success: true)
    }
    
    // MARK: - 步骤执行
    
    private func executeStep(
        _ step: WorkflowStepDef,
        runID: String,
        definition: WorkflowDefinition,
        runState: inout WorkflowRunState
    ) async -> StepExecutionResult {
        let binding = resolveBinding(for: step, runID: runID, in: definition)

        // 查找执行器
        guard let executor = executorRegistry.executor(for: step, binding: binding) else {
            return .failure(error: StepExecutionError(
                code: "NO_EXECUTOR",
                message: "找不到支持步骤 \(step.name) 的执行器",
                isRetryable: false
            ))
        }

        // 构建上下文
        let context = buildContext(step: step, binding: binding, runID: runID, runState: runState)
        
        // 记录步骤开始
        let stepRun = WorkflowStepRun(
            stepID: step.id,
            stepName: step.name,
            status: .running
        )
        runState.stepRuns.append(stepRun)
        let stepRunIndex = runState.stepRuns.count - 1
        runState.activeStepID = step.id

        // 检查审批策略
        let result: StepExecutionResult
        if definition.approvalPolicy.needsApproval(for: step, runCount: runState.stepRuns.count) {
            result = await ApprovalStepExecutor.shared.execute(step, context: context)
        } else {
            result = await executor.execute(step, context: context)
        }

        updateStepRun(&runState, at: stepRunIndex, with: result)
        return result
    }
    
    private func buildContext(
        step: WorkflowStepDef,
        binding: WorkflowBinding?,
        runID: String,
        runState: WorkflowRunState
    ) -> WorkflowContext {
        WorkflowContext(
            runID: runID,
            definitionID: runState.definitionID,
            stepID: step.id,
            binding: binding,
            variables: runState.sharedContext,
            previousOutputs: runState.stepRuns.compactMap { $0.output }.reduce([:]) { $0.merging($1) { _, new in new } }
        )
    }

    private func workflowDefinition(for runState: WorkflowRunState, runID: String) -> WorkflowDefinition? {
        runtimeDefinitions[runID] ?? definitionStore.definition(id: runState.definitionID)
    }

    private func resolveBinding(
        for step: WorkflowStepDef,
        runID: String,
        in definition: WorkflowDefinition
    ) -> WorkflowBinding? {
        guard let bindingID = step.bindingID else { return nil }

        let bindings = runtimeBindings[runID].flatMap { !$0.isEmpty ? $0 : nil } ?? definition.bindings

        return bindings.first {
            $0.id == bindingID || $0.targetID == bindingID || $0.name == bindingID
        }
    }
    
    private func shouldRetry(step: WorkflowStepDef, runState: WorkflowRunState) -> Bool {
        let retryCount = runState.stepRuns.filter { $0.stepID == step.id && $0.status == .failed }.count
        return retryCount < 3  // 最多重试3次
    }

    private func updateStepRun(
        _ runState: inout WorkflowRunState,
        at index: Int,
        with result: StepExecutionResult
    ) {
        guard runState.stepRuns.indices.contains(index) else { return }

        switch result {
        case .success(let output):
            runState.stepRuns[index].status = .completed
            runState.stepRuns[index].completedAt = Date()
            runState.stepRuns[index].output = output
            runState.stepRuns[index].error = nil

        case .failure(let error):
            runState.stepRuns[index].status = .failed
            runState.stepRuns[index].completedAt = Date()
            runState.stepRuns[index].error = StepRunError(
                code: error.code,
                message: error.message,
                isRetryable: error.isRetryable
            )

        case .waiting(let reason):
            runState.stepRuns[index].status = .running
            runState.stepRuns[index].error = StepRunError(
                code: "WAITING",
                message: reason,
                isRetryable: true
            )

        case .needsApproval:
            runState.stepRuns[index].status = .waitingApproval
            runState.stepRuns[index].error = nil

        case .skipped(let reason):
            runState.stepRuns[index].status = .skipped
            runState.stepRuns[index].completedAt = Date()
            runState.stepRuns[index].error = StepRunError(
                code: "SKIPPED",
                message: reason,
                isRetryable: false
            )

        case .jump(let toStepID):
            runState.stepRuns[index].status = .completed
            runState.stepRuns[index].completedAt = Date()
            runState.stepRuns[index].output = ["nextStepID": toStepID]
            runState.stepRuns[index].error = nil
        }
    }

    private func startingStepIndex(
        for runState: WorkflowRunState,
        in definition: WorkflowDefinition
    ) -> Int {
        guard let activeStepID = runState.activeStepID,
              let index = stepIndex(for: activeStepID, in: definition) else {
            return 0
        }

        guard let latestStepRun = runState.stepRuns.last(where: { $0.stepID == activeStepID }) else {
            return index
        }

        switch latestStepRun.status {
        case .completed, .skipped:
            return nextStepIndex(after: definition.steps[index], in: definition) ?? definition.steps.count
        case .pending, .running, .failed, .waitingApproval, .cancelled:
            return index
        }
    }

    private func stepIndex(for stepID: String, in definition: WorkflowDefinition) -> Int? {
        definition.steps.firstIndex(where: { $0.id == stepID })
    }

    private func nextStepID(after step: WorkflowStepDef, in definition: WorkflowDefinition) -> String? {
        if let nextStepID = step.nextStepID {
            return nextStepID
        }

        guard let currentIndex = stepIndex(for: step.id, in: definition) else { return nil }
        let nextIndex = definition.steps.index(after: currentIndex)
        guard definition.steps.indices.contains(nextIndex) else { return nil }
        return definition.steps[nextIndex].id
    }

    private func nextStepIndex(after step: WorkflowStepDef, in definition: WorkflowDefinition) -> Int? {
        guard let nextStepID = nextStepID(after: step, in: definition) else { return nil }
        return stepIndex(for: nextStepID, in: definition)
    }
    
    // MARK: - 事件处理
    
    private func handleBlocking(runID: String, reason: WorkflowBlockingReason) async {
        // 通知用户或触发 Reflection
        LogInfo("[WorkflowRunCoordinator] 处理阻塞: \(runID), 原因: \(reason.displayMessage)")
        
        // 这里可以触发 ReflectionPlanner 来决定下一步
    }
    
    private func handleFailure(runID: String, step: WorkflowStepDef, error: StepExecutionError) async {
        LogError("[WorkflowRunCoordinator] 处理失败: \(runID), 步骤: \(step.name)")
        
        // 记录失败检查点
        if var runState = activeRuns[runID] {
            runState.checkpoints.append(WorkflowCheckpoint(
                id: "step-failed-\(step.id)-\(Date().timeIntervalSince1970)",
                timestamp: Date(),
                kind: .stepFailed,
                description: "步骤失败: \(step.name), 错误: \(error.message)",
                metadata: ["stepID": step.id, "errorCode": error.code]
            ))
            activeRuns[runID] = runState
        }
        
        // 通知失败
        await notifyCompletion(runID: runID, success: false, error: error.message)
    }
    
    private func notifyApprovalNeeded(runID: String, approval: PendingApproval) async {
        // 发送通知给用户
        let message = ApprovalStepExecutor.shared.generateApprovalMessage(approval: approval)
        let definitionID = activeRuns[runID]?.definitionID

        if var runState = activeRuns[runID] {
            runState.checkpoints.append(
                WorkflowCheckpoint(
                    id: "approval-requested-\(runID)-\(Date().timeIntervalSince1970)",
                    timestamp: Date(),
                    kind: .approvalRequested,
                    description: "等待用户审批: \(approval.stepName)",
                    metadata: ["stepID": approval.stepID]
                )
            )
            activeRuns[runID] = runState
        }
        
        // 通过 NotificationCenter 通知 UI
        await MainActor.run {
            NotificationCenter.default.post(
                name: .workflowApprovalNeeded,
                object: nil,
                userInfo: [
                    "runID": runID,
                    "definitionID": definitionID as Any,
                    "approval": approval,
                    "message": message
                ]
            )
        }
    }
    
    private func notifyCompletion(runID: String, success: Bool, error: String? = nil) async {
        let runState = activeRuns[runID] ?? archivedRuns[runID]
        let definition = runState.flatMap { definitionStore.definition(id: $0.definitionID) }
        let summary = completionSummary(definition: definition, runState: runState)

        if let runState {
            archiveRunState(runState, for: runID)
        }

        await MainActor.run {
            NotificationCenter.default.post(
                name: success ? .workflowCompleted : .workflowFailed,
                object: nil,
                userInfo: [
                    "runID": runID,
                    "definitionID": runState?.definitionID as Any,
                    "summary": summary as Any,
                    "error": error as Any
                ]
            )
        }

        activeRuns.removeValue(forKey: runID)
        runtimeBindings.removeValue(forKey: runID)
        runtimeDefinitions.removeValue(forKey: runID)
    }

    private func completionSummary(
        definition: WorkflowDefinition?,
        runState: WorkflowRunState?
    ) -> String? {
        let completedSteps = runState?.stepRuns.filter {
            $0.status == .completed || $0.status == .skipped
        }.count ?? 0

        if let definition {
            return "Workflow「\(definition.name)」执行完成，已完成 \(completedSteps) 个步骤。"
        }

        if completedSteps > 0 {
            return "Workflow 执行完成，已完成 \(completedSteps) 个步骤。"
        }

        return "Workflow 执行完成。"
    }
    
    // MARK: - 用户交互
    
    /// 处理用户审批响应
    func handleApprovalResponse(runID: String, approved: Bool, response: String? = nil) {
        Task {
            let result = ApprovalStepExecutor.shared.handleApprovalResponse(
                runID: runID,
                approved: approved,
                response: response
            )
            
            guard var runState = activeRuns[runID] else { return }
            guard let definition = definitionStore.definition(id: runState.definitionID) else { return }
            
            // 清除阻塞状态
            runState.pendingApproval = nil
            runState.pendingReplan = nil
            runState.blockingReason = nil
            
            switch result {
            case .success(let output):
                runState.sharedContext.merge(output) { _, new in new }
                if let activeStepID = runState.activeStepID,
                   let stepIndex = runState.stepRuns.lastIndex(where: { $0.stepID == activeStepID }) {
                    runState.stepRuns[stepIndex].status = .completed
                    runState.stepRuns[stepIndex].completedAt = Date()
                    runState.stepRuns[stepIndex].output = output
                }
                if let activeStepID = runState.activeStepID,
                   let currentStepIndex = self.stepIndex(for: activeStepID, in: definition) {
                    runState.activeStepID = nextStepID(after: definition.steps[currentStepIndex], in: definition)
                }
                runState.checkpoints.append(WorkflowCheckpoint(
                    id: "approval-granted-\(runID)-\(Date().timeIntervalSince1970)",
                    timestamp: Date(),
                    kind: .approvalGranted,
                    description: "用户批准",
                    metadata: [:]
                ))
                activeRuns[runID] = runState
                
                // 继续执行
                await executeWorkflow(runID: runID)
                
            case .failure(let error):
                if let activeStepID = runState.activeStepID,
                   let stepIndex = runState.stepRuns.lastIndex(where: { $0.stepID == activeStepID }) {
                    runState.stepRuns[stepIndex].status = .failed
                    runState.stepRuns[stepIndex].completedAt = Date()
                    runState.stepRuns[stepIndex].error = StepRunError(
                        code: error.code,
                        message: error.message,
                        isRetryable: error.isRetryable
                    )
                }
                runState.blockingReason = .error(error.message, error.isRetryable)
                runState.checkpoints.append(WorkflowCheckpoint(
                    id: "approval-denied-\(runID)-\(Date().timeIntervalSince1970)",
                    timestamp: Date(),
                    kind: .approvalDenied,
                    description: "用户拒绝",
                    metadata: [:]
                ))
                activeRuns[runID] = runState
                await notifyCompletion(runID: runID, success: false, error: error.message)
                
            default:
                break
            }
        }
    }
    
    /// 暂停 Workflow
    func pauseWorkflow(runID: String) {
        guard var runState = activeRuns[runID] else { return }
        runState.blockingReason = .paused
        runState.nextWakeAt = nil
        activeRuns[runID] = runState
        LogInfo("[WorkflowRunCoordinator] Workflow 已暂停: \(runID)")
    }
    
    /// 恢复 Workflow
    func resumeWorkflow(runID: String) {
        guard var runState = activeRuns[runID] else { return }
        runState.blockingReason = nil
        runState.nextWakeAt = nil
        runState.lastReflectionAt = Date()
        activeRuns[runID] = runState
        LogInfo("[WorkflowRunCoordinator] Workflow 已恢复: \(runID)")
        
        Task {
            await executeWorkflow(runID: runID)
        }
    }

    /// 标记 Workflow 需要重新规划
    func markNeedsReplan(runID: String, reason: String) {
        guard var runState = activeRuns[runID] else { return }
        runState.pendingReplan = nil
        runState.blockingReason = .waitingUser("需要重新规划: \(reason)")
        runState.lastReflectionAt = Date()
        runState.nextWakeAt = Date().addingTimeInterval(900)
        runState.checkpoints.append(
            WorkflowCheckpoint(
                id: "replan-\(runID)-\(Date().timeIntervalSince1970)",
                timestamp: Date(),
                kind: .replanRequested,
                description: "触发重新规划: \(reason)",
                metadata: [:]
            )
        )
        activeRuns[runID] = runState
        LogInfo("[WorkflowRunCoordinator] Workflow 标记为待重新规划: \(runID), 原因: \(reason)")

        NotificationCenter.default.post(
            name: .workflowReplanRequested,
            object: nil,
            userInfo: [
                "runID": runID,
                "definitionID": runState.definitionID,
                "reason": reason,
                "stepID": runState.activeStepID as Any
            ]
        )
    }

    func prepareReplan(runID: String, userInput: String) throws -> PendingWorkflowReplan {
        guard var runState = activeRuns[runID] else {
            throw WorkflowRunError.runNotFound
        }

        guard let definition = workflowDefinition(for: runState, runID: runID) else {
            throw WorkflowRunError.definitionNotFound
        }

        let replannedSteps = buildReplannedSteps(from: userInput)
        if let existingDraftID = runState.pendingReplan?.draftID {
            try? draftService.discardDraft(draftID: existingDraftID)
        }

        let draft = try draftService.createReplanDraft(
            definitionID: definition.id,
            runID: runID,
            stepID: runState.activeStepID,
            workflowName: definition.name,
            workflowDescription: definition.description,
            userInput: userInput,
            steps: replannedSteps
        )

        let preview = PendingWorkflowReplan(
            draftID: draft.id,
            sourceStepID: runState.activeStepID,
            reason: runState.blockingReason?.displayMessage ?? "用户要求调整执行方案",
            userInput: userInput,
            requestedAt: Date(),
            proposedSteps: replannedSteps
        )

        runState.sharedContext["replan_request"] = userInput
        runState.pendingReplan = preview
        runState.blockingReason = .waitingUser("等待确认新的执行方案")
        runState.lastReflectionAt = Date()
        runState.nextWakeAt = Date().addingTimeInterval(900)
        runState.checkpoints.append(
            WorkflowCheckpoint(
                id: "replan-preview-\(runID)-\(Date().timeIntervalSince1970)",
                timestamp: Date(),
                kind: .replanRequested,
                description: "生成新的 workflow 执行方案预览",
                metadata: ["input": userInput]
            )
        )
        activeRuns[runID] = runState

        NotificationCenter.default.post(
            name: .workflowReplanPreviewReady,
            object: nil,
            userInfo: [
                "runID": runID,
                "definitionID": definition.id,
                "draftID": draft.id,
                "previewSteps": preview.proposedSteps.map(\.name),
                "stepID": runState.activeStepID as Any
            ]
        )

        return preview
    }

    func applyPreparedReplan(runID: String) throws -> [WorkflowStepDef] {
        guard var runState = activeRuns[runID] else {
            throw WorkflowRunError.runNotFound
        }

        guard let definition = workflowDefinition(for: runState, runID: runID) else {
            throw WorkflowRunError.definitionNotFound
        }

        guard let preview = runState.pendingReplan else {
            throw WorkflowRunError.executionFailed
        }

        let currentIndex = startingStepIndex(for: runState, in: definition)
        let preservedPrefix = Array(definition.steps.prefix(currentIndex))
        let storedDraft = WorkflowDraftStore.shared.draft(id: preview.draftID)
        let effectiveSteps = storedDraft?.suggestedSteps.isEmpty == false
            ? (storedDraft?.suggestedSteps ?? preview.proposedSteps)
            : preview.proposedSteps

        runtimeDefinitions[runID] = WorkflowDefinition(
            id: definition.id,
            name: definition.name,
            description: definition.description,
            steps: preservedPrefix + effectiveSteps,
            bindings: runtimeBindings[runID].flatMap { !$0.isEmpty ? $0 : nil } ?? definition.bindings,
            approvalPolicy: definition.approvalPolicy,
            reflectionPolicy: definition.reflectionPolicy,
            reminderPolicy: definition.reminderPolicy,
            tags: definition.tags,
            isTemplate: definition.isTemplate,
            templateID: definition.templateID
        )

        runState.activeStepID = effectiveSteps.first?.id
        runState.blockingReason = nil
        runState.pendingApproval = nil
        runState.pendingReplan = nil
        runState.lastReflectionAt = Date()
        runState.nextWakeAt = nil
        runState.checkpoints.append(
            WorkflowCheckpoint(
                id: "replan-applied-\(runID)-\(Date().timeIntervalSince1970)",
                timestamp: Date(),
                kind: .replanExecuted,
                description: "用户确认并应用新的执行方案",
                metadata: ["input": preview.userInput]
            )
        )
        activeRuns[runID] = runState

        try? draftService.markReplanDraftApplied(draftID: preview.draftID)

        NotificationCenter.default.post(
            name: .workflowReplanApplied,
            object: nil,
            userInfo: [
                "runID": runID,
                "definitionID": definition.id,
                "draftID": preview.draftID,
                "stepID": runState.activeStepID as Any
            ]
        )

        Task {
            await executeWorkflow(runID: runID)
        }

        return effectiveSteps
    }
    
    /// 取消 Workflow
    func cancelWorkflow(runID: String) {
        // 取消所有执行器
        for executor in executorRegistry.allExecutors().values {
            executor.cancel(runID: runID)
        }
        
        activeRuns.removeValue(forKey: runID)
        archivedRuns.removeValue(forKey: runID)
        runtimeBindings.removeValue(forKey: runID)
        runtimeDefinitions.removeValue(forKey: runID)
        LogInfo("[WorkflowRunCoordinator] Workflow 已取消: \(runID)")
    }
    
    // MARK: - 查询
    
    func runState(runID: String) -> WorkflowRunState? {
        activeRuns[runID] ?? archivedRuns[runID]
    }
    
    func isRunning(runID: String) -> Bool {
        activeRuns[runID] != nil && activeRuns[runID]?.blockingReason == nil
    }
    
    func isBlocked(runID: String) -> Bool {
        activeRuns[runID]?.blockingReason != nil
    }
    
    func allActiveRunIDs() -> [String] {
        Array(activeRuns.keys).sorted()
    }

    private func archiveRunState(_ runState: WorkflowRunState, for runID: String) {
        archivedRuns[runID] = runState

        if archivedRuns.count > maxArchivedRuns,
           let oldestRunID = archivedRuns.min(by: {
               ($0.value.checkpoints.last?.timestamp ?? .distantPast) < ($1.value.checkpoints.last?.timestamp ?? .distantPast)
           })?.key {
            archivedRuns.removeValue(forKey: oldestRunID)
        }
    }
}

private extension WorkflowRunCoordinator {
    func buildReplannedSteps(from userInput: String) -> [WorkflowStepDef] {
        let parsedStepNames = RequestPlanningHeuristics.workflowStepsPreview(from: userInput)
        let effectiveStepNames = parsedStepNames.isEmpty ? ["执行调整后的方案"] : parsedStepNames
        return effectiveStepNames.enumerated().map { index, name in
            WorkflowStepDef(
                name: name,
                description: index == 0 ? userInput : "",
                kind: .action
            )
        }
    }
}

// MARK: - Errors

enum WorkflowRunError: Error {
    case definitionNotFound
    case runNotFound
    case alreadyRunning
    case executionFailed
    
    var localizedDescription: String {
        switch self {
        case .definitionNotFound:
            return "找不到 Workflow 定义"
        case .runNotFound:
            return "找不到 Workflow 运行实例"
        case .alreadyRunning:
            return "Workflow 正在运行中"
        case .executionFailed:
            return "Workflow 执行失败"
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let workflowApprovalNeeded = Notification.Name("WorkflowApprovalNeeded")
    static let workflowCompleted = Notification.Name("WorkflowCompleted")
    static let workflowFailed = Notification.Name("WorkflowFailed")
    static let workflowReplanRequested = Notification.Name("WorkflowReplanRequested")
    static let workflowReplanPreviewReady = Notification.Name("WorkflowReplanPreviewReady")
    static let workflowReplanApplied = Notification.Name("WorkflowReplanApplied")
}

// MARK: - StepExecutionResult 扩展

extension StepExecutionResult {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
