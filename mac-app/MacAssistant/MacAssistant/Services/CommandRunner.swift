//
//  CommandRunner.swift
//  MacAssistant
//
//  主命令处理器 - 纯原生运行时
//

import Foundation
import SwiftUI
import Combine
import AppKit
import CoreGraphics
import UserNotifications

class CommandRunner: ObservableObject {
    private struct TaskExecutionResult {
        let agent: Agent
        let content: String
        let failed: Bool
    }

    private struct ConversationProgressSnapshot: Equatable {
        let messageKey: String
        let content: String
        let agentID: String?
        let agentName: String?
        let metadata: [String: String]
    }

    private struct DirectKimiCLIFallbackPolicy {
        let timeout: TimeInterval
        let statusSummary: String
        let logReason: String
    }

    @Published var messages: [ChatMessage] = [] {
        didSet {
            guard !isRestoringPersistedState else { return }
            StorageManager.shared.replaceRecentMessages(messages)
        }
    }
    @Published var taskSessions: [AgentTaskSession] = [] {
        didSet {
            guard !isRestoringPersistedState else { return }
            executionJournal.saveTaskSessions(taskSessions)
        }
    }
    @Published private(set) var messageExecutionTraces: [UUID: ExecutionTrace] = [:]
    @Published var currentExecutionTrace: ExecutionTrace?
    @Published var isProcessing = false
    
    /// 截图路径（最近一张）
    @Published var lastScreenshotPath: String?
    
    private let agentStore = AgentStore.shared
    private let orchestrator = AgentOrchestrator.shared
    private let creationSkill = AgentCreationSkill.shared
    private let conversationControl = ConversationControlStore.shared
    private let skillRegistry = AISkillRegistry.shared
    private let toolSkillRegistry = SkillRegistry.shared
    private let skillEvolutionAdvisor = SkillEvolutionAdvisor.shared
    private let memoryRecallCoordinator = MemoryRecallCoordinator.shared
    private let runtimeAdapter: any ConversationRuntimeAdapter
    private let localKimiCLIService = LocalKimiCLIService.shared
    private let requestPlanner = RequestPlanner.shared
    private let logger = ConversationLogger.shared
    private let preferences = UserPreferenceStore.shared
    private let executionJournal = ExecutionJournalStore.shared
    @MainActor
    private let unifiedTaskManager = UnifiedTaskManager.shared
    private let initialSetupPromptKey = "initial_setup_prompt"
    private let pendingWorkflowDesignKey = "pending_workflow_design"
    private let workflowOriginalInputKey = "workflow_original_input"
    private let workflowTaskSessionIDKey = "workflow_task_session_id"
    private let workflowDraftIDKey = "workflow_draft_id"
    private let pendingWorkflowClarificationKey = "pending_workflow_clarification"
    private let pendingWorkflowDraftKey = "pending_workflow_draft"
    private let pendingWorkflowRunKey = "pending_workflow_run"
    private let pendingWorkflowReplanKey = "pending_workflow_replan"
    private let pendingWorkflowReplanPreviewKey = "pending_workflow_replan_preview"
    private let workflowModificationInputKey = "workflow_modification_input"
    private let workflowDefinitionIDKey = "workflow_definition_id"
    private let workflowTaskDefinitionIDKey = "workflow_task_definition_id"
    private let workflowRunIDKey = "workflow_run_id"
    private let workflowStepIDKey = "workflow_step_id"
    private let directKimiCLIFallbackTimeout: TimeInterval = 90
    private let directKimiCLIInterruptedStreamFallbackTimeout: TimeInterval = 60
    private let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    
    private var cancellables: Set<AnyCancellable> = []
    private var isWaitingForScreenRecordingAuthorization = false
    private var isRestartingForScreenRecordingPermission = false
    private var isWaitingForKimiCLILogin = false
    private var pendingKimiCLILoginAgentID: String?
    private var traceDismissTasks: [UUID: Task<Void, Never>] = [:]
    private var traceSettleTasks: [UUID: Task<Void, Never>] = [:]
    private var isRestoringPersistedState = false
    private var taskSessionProgressSnapshots: [String: ConversationProgressSnapshot] = [:]
    private var unifiedTaskProgressSnapshots: [String: ConversationProgressSnapshot] = [:]
    
    static let shared = CommandRunner()
    
    init(runtimeAdapter: any ConversationRuntimeAdapter = NativeConversationRuntimeAdapter.shared) {
        self.runtimeAdapter = runtimeAdapter
        restorePersistedState()
        setupNotifications()
        Task { @MainActor in
            setupConversationProgressFeeds()
        }
        Task {
            await reconcileInterruptedTaskSessions(trigger: "launch")
        }
    }

    var isLoading: Bool { isProcessing }
    
    private func setupNotifications() {
        NotificationCenter.default.publisher(for: NSNotification.Name("ShowCapabilityDiscovery"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let gap = notification.object as? CapabilityGap {
                    self?.handleCapabilityGap(gap)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resumePendingScreenRecordingFlowIfNeeded()
                    await self?.resumePendingKimiCLILoginFlowIfNeeded()
                    await self?.reconcileInterruptedTaskSessions(trigger: "foreground")
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .skillEvolutionProposalReady)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let proposal = notification.object as? SkillEvolutionProposal else {
                    return
                }
                self?.presentSkillEvolutionProposal(proposal)
            }
            .store(in: &cancellables)
        
        // 监听统一任务管理器的恢复请求
        NotificationCenter.default.publisher(for: .resumeTaskSessionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let userInfo = notification.userInfo,
                      let gatewaySessionKey = userInfo["gatewaySessionKey"] as? String,
                      let originalRequest = userInfo["originalRequest"] as? String,
                      let taskID = userInfo["taskID"] as? String else {
                    return
                }
                Task {
                    await self?.handleUnifiedTaskRecovery(
                        taskID: taskID,
                        gatewaySessionKey: gatewaySessionKey,
                        originalRequest: originalRequest
                    )
                }
            }
            .store(in: &cancellables)
        
        // 监听健康监控告警
        NotificationCenter.default.publisher(for: Notification.Name("healthMonitorAlert"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let userInfo = notification.userInfo as? [String: Any] else { return }
                Task {
                    await self?.handleHealthMonitorAlert(userInfo)
                }
            }
            .store(in: &cancellables)
        
        // 监听健康监控 AI 诊断请求
        NotificationCenter.default.publisher(for: Notification.Name("healthMonitorAIDiagnosis"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let userInfo = notification.userInfo as? [String: Any] else { return }
                Task {
                    await self?.handleHealthMonitorAIDiagnosis(userInfo)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workflowApprovalNeeded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.presentWorkflowApprovalRequest(notification)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workflowReplanRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.presentWorkflowReplanRequest(notification)
                }
            }
            .store(in: &cancellables)

        _ = skillEvolutionAdvisor.scanNow()
    }

    @MainActor
    private func setupConversationProgressFeeds() {
        // 使用 reduce 处理可能的重复 key，保留最后一个值
        taskSessionProgressSnapshots = taskSessions.compactMap { session -> (String, ConversationProgressSnapshot)? in
            guard let snapshot = taskSessionProgressSnapshot(for: session) else { return nil }
            return (conversationProgressIdentity(for: session), snapshot)
        }.reduce(into: [:]) { dict, pair in
            dict[pair.0] = pair.1
        }
        
        unifiedTaskProgressSnapshots = unifiedTaskManager.tasks.compactMap { task -> (String, ConversationProgressSnapshot)? in
            guard let snapshot = unifiedTaskProgressSnapshot(for: task) else { return nil }
            return (conversationProgressIdentity(for: task), snapshot)
        }.reduce(into: [:]) { dict, pair in
            dict[pair.0] = pair.1
        }

        $taskSessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                Task { @MainActor in
                    self?.syncTaskSessionProgressFeed(with: sessions)
                }
            }
            .store(in: &cancellables)

        unifiedTaskManager.$tasks
            .receive(on: RunLoop.main)
            .sink { [weak self] tasks in
                Task { @MainActor in
                    self?.syncUnifiedTaskProgressFeed(with: tasks)
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 主要处理入口
    
    /// 处理用户输入（主入口 - 智能解析版）
    func processInput(_ text: String, images: [String] = []) async {
        let contextualImages = resolveImagesForRequest(text: text, explicitImages: images)

        let envelope = await MainActor.run { () -> RequestEnvelope in
            let activeBrowserSession = BrowserSessionStore.shared.activeSession
            return RequestEnvelope(
                originalText: text,
                images: contextualImages,
                sessionTopology: conversationControl.currentTopology(),
                currentAgent: orchestrator.currentAgent,
                needsInitialSetup: agentStore.needsInitialSetup,
                lastMessage: messages.last,
                creationFlowActive: creationSkill.isInCreationFlow,
                resumableTaskSessionID: latestResumableTaskSessionID(),
                activeWorkflowDesignContext: activeWorkflowDesignContext(),
                activeBrowserSession: activeBrowserSession,
                activeBrowserSnapshot: activeBrowserSession?.latestSnapshot,
                activeBrowserObservation: activeBrowserSession?.latestObservation ??
                    activeBrowserSession?.latestSnapshot.map(BrowserObservation.init(snapshot:)),
                activeBrowserDelta: activeBrowserSession?.latestDelta,
                activeBrowserPlannerState: activeBrowserSession?.plannerState
            )
        }
        let request = AssembledConversationContext(
            text: text,
            images: contextualImages,
            envelope: envelope
        )
        let plan = await requestPlanner.plan(envelope)
        await processPreparedRequest(request, plan: plan)
    }

    func processPreparedRequest(
        _ request: AssembledConversationContext,
        plan: RequestPlan
    ) async {
        if !plan.shouldAppendUserMessage {
            logRequestPlan(plan)
            await executeRequestPlan(plan, anchorMessageID: request.envelope.id)
            return
        }

        // 3. 记录用户输入和统一规划结果
        logger.logUserInput(request.text, parsed: plan.parsedInput)
        logRequestPlan(plan)

        // 4. 记录用户消息到记忆系统（秘书的基本职责：记住用户的话）
        await MainActor.run {
            recordConversationToMemory(
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    content: request.text,
                    timestamp: Date(),
                    images: request.images
                )
            )
        }
        
        // 5. 准备带记忆上下文的提示词
        _ = await MainActor.run {
            prepareRequestWithMemory(
                text: request.text,
                systemPrompt: nil
            )
        }
        
        // 6. 添加用户消息（显示原始输入）
        let userMessage = ChatMessage(
            id: UUID(),
            role: .user,
            content: request.text,  // 显示原始输入
            timestamp: Date(),
            images: request.images
        )
        let userMessageID = userMessage.id
        await MainActor.run {
            clearFinishedExecutionTraces()
            messages.append(userMessage)
            isProcessing = true
        }

        // 7. 执行请求（sendViaGateway 会自动注入记忆上下文）
        await executeRequestPlan(plan, anchorMessageID: userMessageID)
    }

    private func executeRequestPlan(
        _ plan: RequestPlan,
        anchorMessageID: UUID
    ) async {
        // MARK: - 启动执行链路日志
        let sessionID = plan.envelope.id.uuidString
        _ = await ExecutionLogger.shared.startSession(
            id: sessionID,
            userRequest: plan.envelope.originalText
        )
        
        // 记录Planner决策
        await ExecutionLogger.shared.logPlannerDecision(
            sessionID: sessionID,
            action: "\(plan.primaryAction)",
            reason: plan.reason,
            confidence: plan.confidence.rawValue
        )
        
        if !plan.notices.isEmpty {
            await MainActor.run {
                for notice in plan.notices {
                    appendSystemMessage(notice)
                }
            }
        }

        if let requestedAgentSwitch = plan.requestedAgentSwitch {
            let switched = await handleAgentSwitch(
                requestedAgentSwitch.agent,
                reason: requestedAgentSwitch.reason,
                requiredCapability: requestedAgentSwitch.requiredCapability
            )
            guard switched else { return }
        }

        switch plan.primaryAction {
        case .cancelPendingFlow:
            await cancelPendingFlow(plan)

        case .startBrowserSession(let url, let originalInput):
            await executeBrowserSessionStart(url: url, originalInput: originalInput)

        case .continueBrowserSession(let sessionID, let input):
            await executeBrowserSessionContinuation(sessionID: sessionID, input: input)

        case .continueAgentCreationFlow(let input):
            await creationSkill.handleInput(input, runner: self)

        case .resumeInterruptedTask(let sessionID):
            await resumeTaskSessionIfPossible(sessionID)

        case .respondToSkillEvolution(let proposalID, let accepted):
            let response = accepted
                ? skillEvolutionAdvisor.acceptProposal(id: proposalID)
                : skillEvolutionAdvisor.rejectProposal(id: proposalID)
            await MainActor.run {
                messages.append(
                    ChatMessage(
                        id: UUID(),
                        role: .assistant,
                        content: response,
                        timestamp: Date(),
                        agentId: "builtin-skill-evolution-advisor",
                        agentName: "Skill 迭代顾问"
                    )
                )
                isProcessing = false
            }

        case .startWorkflowDesignSession(let input):
            await startWorkflowDesignInSideSession(originalInput: input)

        case .continueWorkflowDesignSession(let sessionID, let originalInput, let followUpInput):
            await continueWorkflowDesignTaskSession(
                sessionID: sessionID,
                originalInput: originalInput,
                followUpInput: followUpInput
            )

        case .respondToWorkflowDesignGuidance(let originalInput, let followUpInput, let accepted):
            if accepted {
                await continueWorkflowDesignInSideSession(
                    originalInput: originalInput,
                    followUpInput: followUpInput
                )
            } else {
                await MainActor.run {
                    messages.append(
                        ChatMessage(
                            id: UUID(),
                            role: .assistant,
                            content: "好，这次我先不继续展开这条业务工作流设计。后面你也可以直接告诉我要继续细化哪个环节，例如目标、触发方式、定时规则或交付形式。",
                            timestamp: Date(),
                            agentId: "builtin-agent-creation-guard",
                            agentName: "Agent 创建顾问"
                        )
                    )
                    isProcessing = false
                }
            }

        case .respondToDetectedSkillSuggestion(let messageID, let action):
            await MainActor.run {
                isProcessing = false
            }
            await handleDetectedSkillSuggestionAction(
                messageID: messageID,
                action: action,
                images: plan.envelope.images
            )

        case .respondToLegacySkillSuggestion(let skill, let input, let accepted):
            if accepted {
                await runDetectedSkillInSideSession(
                    skill: skill,
                    input: input,
                    images: plan.envelope.images,
                    suggestionMessageID: plan.envelope.lastMessage?.id
                )
            } else {
                await MainActor.run {
                    preferences.recordSkillRejection(skill)
                    if let messageID = plan.envelope.lastMessage?.id {
                        resolveDetectedSkillSuggestionMessage(
                            messageID: messageID,
                            content: "已跳过这次 \(skill.name) 建议。后续是否继续提示，可以在 Skills > 设置 里修改。"
                        )
                    }
                    isProcessing = false
                }
            }

        case .requestInitialSetup:
            await MainActor.run {
                isProcessing = false
                presentInitialSetupPrompt(for: plan.envelope.images.isEmpty ? "开始对话" : "处理附件请求")
            }

        case .showSkillEvolutionOverview:
            await presentSkillEvolutionOverview()

        case .showPlannerConsole:
            await presentPlannerConsoleStatus()

        case .executeToolSkill(let name, let input):
            await handleToolSkillCommand(name, input: input)

        case .showSkillOverview:
            await presentProjectSkillOverview()

        case .showAgentCreationGuidance(let kind):
            await presentAgentCreationGuidance(kind: kind, originalInput: plan.envelope.originalText)

        case .executeLocalToolSkill(let name, let input):
            await handleToolSkillCommand(name, input: input)

        case .executeExplicitSkill(let skill, let input):
            await handleSkillCommand(skill, input: input, images: plan.envelope.images)

        case .handleDetectedSkill(let skill, let input, let executionInput):
            await handleDetectedSkill(
                skill,
                input: input,
                executionInput: executionInput,
                images: plan.envelope.images,
                anchorMessageID: anchorMessageID
            )

        case .handleAgentSuggestion(let suggestion, let input):
            await handleAgentSuggestion(suggestion, input: input, images: plan.envelope.images)

        case .executeNativeSkill(let skillID, let parameters, let title):
            await handleNativeSkillExecution(
                plan: plan,
                skillID: skillID,
                parameters: parameters,
                title: title
            )

        case .executeSubtaskPlan(let subtaskPlan, let originalInput):
            await handlePlannedSubtasks(plan: plan, subtaskPlan: subtaskPlan, originalInput: originalInput)

        case .routeMainConversation(let input):
            await processCleanInput(input, images: plan.envelope.images, anchorMessageID: anchorMessageID)
            
        // MARK: - 异常处理场景（方案C）
        case .handleStreamInterrupted(let sessionID, let originalRequest, let partialResult):
            await handleStreamInterrupted(
                sessionID: sessionID,
                originalRequest: originalRequest,
                partialResult: partialResult,
                images: plan.envelope.images
            )
            
        case .checkTaskStatus(let sessionID):
            await handleCheckTaskStatus(sessionID: sessionID)
            
        case .autoRecoverTask(let sessionID, let delaySeconds):
            await BackgroundTaskRecoveryService.shared.scheduleRecovery(
                sessionID: sessionID,
                originalRequest: "",
                delaySeconds: delaySeconds
            )
            await MainActor.run { isProcessing = false }
            
        // MARK: - Workflow 编排场景（新增）
        case .requestWorkflowClarification(let candidate, let slots):
            await handleWorkflowClarification(plan: plan, candidate: candidate, slots: slots)
            
        case .createWorkflowDraft(let candidate, let originalInput):
            await handleWorkflowDraftCreation(plan: plan, candidate: candidate, originalInput: originalInput)
            
        case .startWorkflowRun(let definitionID, let initialContext):
            await handleWorkflowStart(plan: plan, definitionOrDraftID: definitionID, initialContext: initialContext)
            
        case .continueWorkflowRun(let runID, let stepID, let userResponse):
            LogInfo("继续 WorkflowRun: \(runID), 步骤: \(stepID ?? "next"), 用户响应: \(userResponse)")
            await handleWorkflowContinuation(plan: plan, runID: runID, stepID: stepID, userResponse: userResponse)
            
        case .reflectWorkflowRun(let runID, let trigger):
            // 反思 workflow run（通常由定时器触发，不直接回复用户）
            LogInfo("反思 WorkflowRun: \(runID), 触发器: \(trigger.rawValue)")
            // TODO: 调用 ReflectionPlanner
            await MainActor.run { isProcessing = false }
            
        case .remindUserAboutWorkflow(let runID, let reason, let priority):
            // 提醒用户关于 workflow
            let priorityEmoji = priority == .critical ? "🔴" : priority == .high ? "🟡" : "🔵"
            let message = "\(priorityEmoji) Workflow 提醒\n\(reason)"
            await MainActor.run {
                messages.append(
                    ChatMessage(
                        id: UUID(),
                        role: .assistant,
                        content: message,
                        timestamp: Date(),
                        metadata: [
                            "workflow_run_id": runID,
                            "reminder_priority": String(priority.rawValue)
                        ]
                    )
                )
                isProcessing = false
            }
            
        // MARK: - Phase 2: MCP 原生调度
        case .executeMCPService(let serviceID, let operation, let parameters):
            await executeMCPServiceDirectly(
                plan: plan,
                serviceID: serviceID,
                operation: operation,
                parameters: parameters
            )
            
        // MARK: - Phase 1: 服务管理调度
        case .manageService(let serviceID, let operation, let userIntent):
            await executeServiceManagement(
                serviceID: serviceID,
                operation: operation,
                userIntent: userIntent,
                anchorMessageID: anchorMessageID
            )
            
        case .executeNativeServiceLifecycle(let serviceID, let action, let title):
            // 原生服务生命周期管理（占位实现）
            LogInfo("[CommandRunner] 执行原生服务生命周期: \(serviceID) - \(action.rawValue)")
            await MainActor.run {
                appendSystemMessage("[\(title)] 服务 \(serviceID) \(action.rawValue) 操作已触发")
                isProcessing = false
            }
        }
    }

    // MARK: - 服务管理执行
    
    private func executeServiceManagement(
        serviceID: String,
        operation: String,
        userIntent: String?,
        anchorMessageID: UUID
    ) async {
        guard let op = ServiceOperation(rawValue: operation) else {
            await MainActor.run {
                appendSystemMessage("❌ 未知的服务操作: \(operation)")
                isProcessing = false
            }
            return
        }
        
        // 执行服务管理操作
        let result = await ServicePlanner.shared.executeAndReport(
            serviceId: serviceID,
            operation: op,
            userIntent: userIntent
        ) { executionResult in
            // 实时更新主会话
            Task { @MainActor in
                if executionResult.isProgress {
                    // 进度更新：更新或添加系统消息
                    self.updateOrAppendSystemMessage(executionResult.message)
                }
            }
        }
        
        // 最终结果显示在主会话
        await MainActor.run {
            let emoji = result.success ? "✅" : "❌"
            self.appendSystemMessage("\(emoji) \(result.message)")
            self.isProcessing = false
        }
    }
    
    private func updateOrAppendSystemMessage(_ content: String) {
        // 简化实现：直接追加新消息
        // 实际可以优化为更新最后一条系统消息
        if messages.last?.role == .system {
            // 更新最后一条系统消息
            let updatedMessage = ChatMessage(
                id: messages.last!.id,
                role: .system,
                content: content,
                timestamp: Date()
            )
            messages[messages.count - 1] = updatedMessage
        } else {
            Task { @MainActor in
                appendSystemMessage(content)
            }
        }
    }

    private func logRequestPlan(_ plan: RequestPlan) {
        let currentAgentID = plan.envelope.currentAgent?.id ?? "none"
        let mentionID = plan.requestedAgentSwitch?.agent.id ?? "none"
        LogInfo(
            "RequestPlanner decision requestID=\(plan.envelope.id.uuidString) " +
            "planner=\(plan.plannerID) action=\(plan.summary) confidence=\(plan.confidence.rawValue) " +
            "mode=\(plan.executionMode.rawValue) tasks=\(plan.taskSummary) " +
            "currentAgent=\(currentAgentID) mentionedAgent=\(mentionID) " +
            "images=\(plan.envelope.images.count) notices=\(plan.notices.count) " +
            "reason=\(plan.reason)"
        )
    }

    private func handlePlannedSubtasks(
        plan: RequestPlan,
        subtaskPlan: SubtaskPlan,
        originalInput: String
    ) async {
        let decomposition = await MainActor.run {
            SubtaskCoordinator.shared.enqueuePlan(subtaskPlan)
        }

        let taskIDs = await MainActor.run {
            decomposition.subtasks.compactMap { SubtaskCoordinator.shared.unifiedTaskID(forSubtaskID: $0.id) }
        }

        for taskID in taskIDs {
            await unifiedTaskManager.startTask(id: taskID)
        }

        let subtaskTitles = decomposition.subtasks.prefix(3).map(\.title).joined(separator: " / ")
        let moreSuffix = decomposition.subtasks.count > 3 ? " 等 \(decomposition.subtasks.count) 个子任务" : ""

        await MainActor.run {
            messages.append(
                ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: "我已经把这个请求拆成 \(decomposition.subtasks.count) 个子任务并提交到任务中心开始执行：\(subtaskTitles)\(moreSuffix)。后续你可以在任务中心查看每个子任务的进展。",
                    timestamp: Date(),
                    metadata: [
                        "subtask_parent_id": decomposition.parentTaskID,
                        "subtask_count": String(decomposition.subtasks.count),
                        "planner_action": plan.summary,
                        "original_input": originalInput
                    ]
                )
            )
            isProcessing = false
        }
    }

    private func handleNativeSkillExecution(
        plan: RequestPlan,
        skillID: String,
        parameters: [String: String],
        title: String
    ) async {
        do {
            let registry = await MainActor.run { SkillAdapterRegistry.shared }
            if await MainActor.run(body: { SkillCatalog.shared.find(byID: skillID) == nil }) {
                await registry.syncToCatalog()
            }

            let executionParameters = Dictionary(uniqueKeysWithValues: parameters.map { key, value in
                (key, value as Any)
            })
            let result = try await registry.execute(skillID: skillID, parameters: executionParameters)
            let content = formatNativeSkillExecutionResult(
                title: title,
                skillID: skillID,
                parameters: parameters,
                result: result
            )

            await MainActor.run {
                messages.append(
                    ChatMessage(
                        id: UUID(),
                        role: .assistant,
                        content: content,
                        timestamp: Date(),
                        metadata: [
                            "native_skill_id": skillID,
                            "planner_action": plan.summary
                        ].merging(parameters) { current, _ in current }
                    )
                )
                isProcessing = false
            }
        } catch {
            await MainActor.run {
                messages.append(
                    ChatMessage(
                        id: UUID(),
                        role: .assistant,
                        content: "原生执行链调用失败：\(error.localizedDescription)",
                        timestamp: Date(),
                        metadata: [
                            "native_skill_id": skillID,
                            "planner_action": plan.summary
                        ]
                    )
                )
                isProcessing = false
            }
        }
    }

    private func formatNativeSkillExecutionResult(
        title: String,
        skillID: String,
        parameters: [String: String],
        result: SkillExecutionResult
    ) -> String {
        let operation = parameters["operation"] ?? "invoke"
        let endpoint = parameters["endpoint"] ?? (operation == "health" ? "默认健康检查" : "默认入口")

        if !result.success {
            let response = result.output?["response"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let response, !response.isEmpty {
                return """
                \(title)失败。

                - Skill: \(skillID)
                - 操作: \(operation)
                - Endpoint: \(endpoint)
                - 错误: \(result.error ?? "未知错误")

                返回内容：
                \(response)
                """
            }

            return """
            \(title)失败。

            - Skill: \(skillID)
            - 操作: \(operation)
            - Endpoint: \(endpoint)
            - 错误: \(result.error ?? "未知错误")
            """
        }

        let response = result.output?["response"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusCode = result.output?["status_code"] ?? "200"
        let serviceName = result.output?["service_name"] ?? skillID

        if let response, !response.isEmpty {
            return """
            已通过原生执行链完成「\(serviceName)」\(operation == "health" ? "检查" : "调用")。

            - Skill: \(skillID)
            - 操作: \(operation)
            - Endpoint: \(endpoint)
            - HTTP: \(statusCode)

            返回内容：
            \(response)
            """
        }

        return """
        已通过原生执行链完成「\(serviceName)」\(operation == "health" ? "检查" : "调用")。

        - Skill: \(skillID)
        - 操作: \(operation)
        - Endpoint: \(endpoint)
        - HTTP: \(statusCode)
        """
    }

    // MARK: - Phase 2: MCP 原生调度执行
    
    /// 直接执行 MCP 服务调用（不经过 LLM runtime）
    private func executeMCPServiceDirectly(
        plan: RequestPlan,
        serviceID: String,
        operation: String,
        parameters: [String: String]
    ) async {
        let sessionID = plan.envelope.id.uuidString
        
        LogInfo("[CommandRunner] 直接执行 MCP 服务: serviceID=\(serviceID), operation=\(operation)")
        
        // 记录执行链路日志
        await ExecutionLogger.shared.log(
            sessionID: sessionID,
            level: .info,
            component: "MCPExecutor",
            message: "直接执行 MCP 服务: \(serviceID)",
            details: [
                "service_id": serviceID,
                "operation": operation,
                "parameters": parameters.description
            ]
        )
        
        // 显示开始状态
        await MainActor.run {
            appendSystemMessage("🔧 正在调用 \(serviceID)...")
        }
        
        do {
            // 构建执行参数
            var executionParameters: [String: Any] = [
                "operation": operation
            ]
            
            // 如果 parameters 不为空，根据 operation 构造合适的 endpoint 和 body
            if !parameters.isEmpty {
                switch operation {
                case "search", "query":
                    if let keyword = parameters["keyword"] {
                        executionParameters["endpoint"] = "/api/search"
                        executionParameters["method"] = "POST"
                        executionParameters["body"] = ["query": keyword]
                    }
                case "trending":
                    executionParameters["endpoint"] = "/api/trending/list"
                    executionParameters["method"] = "GET"
                default:
                    // 默认使用 health check
                    executionParameters["endpoint"] = "/health"
                    executionParameters["method"] = "GET"
                }
            }
            
            // 直接调用 SkillAdapterRegistry
            let result = try await SkillAdapterRegistry.shared.execute(
                skillID: "mcp.\(serviceID)",
                parameters: executionParameters
            )
            
            // 格式化结果
            let content: String
            if result.success, let output = result.output {
                let serviceName = output["service_name"] ?? serviceID
                let responseText = output["response"] ?? "调用成功"
                let statusCode = output["status_code"] ?? "200"
                
                content = """
                ✅ MCP 服务调用成功

                - 服务: \(serviceName)
                - 操作: \(operation)
                - 状态: HTTP \(statusCode)

                返回结果：
                \(responseText)
                """
            } else {
                let errorMsg = result.error ?? "未知错误"
                content = """
                ❌ MCP 服务调用失败

                - 服务: \(serviceID)
                - 操作: \(operation)
                - 错误: \(errorMsg)
                """
            }
            
            await MainActor.run {
                messages.append(
                    ChatMessage(
                        id: UUID(),
                        role: .assistant,
                        content: content,
                        timestamp: Date(),
                        metadata: [
                            "mcp_service_id": serviceID,
                            "mcp_operation": operation,
                            "mcp_success": String(result.success)
                        ]
                    )
                )
                isProcessing = false
            }
            
        } catch {
            LogError("[CommandRunner] MCP 服务调用异常: \(error)")
            
            await MainActor.run {
                messages.append(
                    ChatMessage(
                        id: UUID(),
                        role: .assistant,
                        content: """
                        ❌ MCP 服务调用异常

                        - 服务: \(serviceID)
                        - 操作: \(operation)
                        - 错误: \(error.localizedDescription)
                        """,
                        timestamp: Date(),
                        metadata: [
                            "mcp_service_id": serviceID,
                            "mcp_operation": operation,
                            "mcp_error": error.localizedDescription
                        ]
                    )
                )
                isProcessing = false
            }
        }
    }

    private func handleWorkflowClarification(
        plan: RequestPlan,
        candidate: WorkflowCandidate,
        slots: [PlanningSlot]
    ) async {
        do {
            let draft = try await upsertWorkflowDraftForClarification(
                plan: plan,
                candidate: candidate,
                slots: slots
            )
            await presentWorkflowDraft(draft)
        } catch {
            await presentWorkflowError("创建 workflow 草稿失败：\(error.localizedDescription)")
        }
    }

    private func handleWorkflowDraftCreation(
        plan: RequestPlan,
        candidate: WorkflowCandidate,
        originalInput: String
    ) async {
        do {
            if let existingDraftID = plan.metadata[workflowDraftIDKey] {
                let modificationInput = plan.metadata[workflowModificationInputKey] ?? plan.envelope.originalText
                let normalized = RequestPlanningHeuristics.normalized(modificationInput)
                let genericModifyRequests: Set<String> = ["修改", "调整", "改一下", "编辑", "优化"]

                guard !genericModifyRequests.contains(normalized) else {
                    await presentWorkflowError(
                        "告诉我你想怎么改这个 workflow 草稿，例如“增加发送通知步骤”或“去掉保存记录”。",
                        metadata: [
                            workflowDraftIDKey: existingDraftID,
                            pendingWorkflowDraftKey: "true"
                        ]
                    )
                    return
                }

                let stepNames = RequestPlanningHeuristics.workflowStepsPreview(from: modificationInput)
                let steps = stepNames.map { WorkflowStepDef(name: $0, kind: .action) }
                let draft = try await updateWorkflowDraftSteps(draftID: existingDraftID, steps: steps)
                await presentWorkflowDraft(
                    draft,
                    preface: "我已经根据你的补充更新了这个 workflow 草稿。"
                )
                return
            }

            let draft = try await createWorkflowDraft(candidate: candidate, originalInput: originalInput)
            await presentWorkflowDraft(draft)
        } catch {
            await presentWorkflowError("生成 workflow 草稿失败：\(error.localizedDescription)")
        }
    }

    private func handleWorkflowStart(
        plan: RequestPlan,
        definitionOrDraftID: String,
        initialContext: [String: String]
    ) async {
        do {
            let definition = try await publishedWorkflowDefinitionIfNeeded(id: definitionOrDraftID)
            let task = await MainActor.run {
                unifiedTaskManager.createWorkflowTask(
                    title: definition.name,
                    description: definition.description,
                    definitionID: definition.id,
                    initialContext: initialContext
                )
            }
            await unifiedTaskManager.startTask(id: task.id)

            await MainActor.run {
                if let lastMessage = plan.envelope.lastMessage,
                   lastMessage.metadata?[workflowDraftIDKey] == definitionOrDraftID {
                    resolvePendingControlMessage(
                        lastMessage,
                        content: "已发布 workflow 草稿「\(definition.name)」，并转入任务中心执行。"
                    )
                }

                messages.append(
                    ChatMessage(
                        id: UUID(),
                        role: .assistant,
                        content: "已发布并启动 workflow「\(definition.name)」。你可以在任务中心查看进度，后续需要继续输入时也会回到主会话。",
                        timestamp: Date(),
                        metadata: [
                            workflowDefinitionIDKey: definition.id,
                            workflowTaskDefinitionIDKey: task.id
                        ]
                    )
                )
                isProcessing = false
            }
        } catch {
            await presentWorkflowError("启动 workflow 失败：\(error.localizedDescription)")
        }
    }

    private func handleWorkflowContinuation(
        plan: RequestPlan,
        runID: String,
        stepID: String?,
        userResponse: String
    ) async {
        LogInfo("继续 WorkflowRun: \(runID), stepID=\(stepID ?? "next")")

        let taskDefinitionID: String?
        if let plannedTaskDefinitionID = plan.metadata[workflowTaskDefinitionIDKey] {
            taskDefinitionID = plannedTaskDefinitionID
        } else {
            taskDefinitionID = await MainActor.run {
                unifiedTaskManager.workflowTaskID(forRunID: runID)
            }
        }
        let runState = await MainActor.run { WorkflowRunCoordinator.shared.runState(runID: runID) }

        if runState?.pendingApproval != nil {
            guard let approved = RequestPlanningHeuristics.workflowApprovalDecision(from: userResponse) else {
                await presentWorkflowError(
                    "当前 workflow 正在等待审批。请回复“确认”继续执行，或回复“拒绝”终止这一步。",
                    metadata: workflowPendingMetadata(
                        runID: runID,
                        taskDefinitionID: taskDefinitionID,
                        stepID: stepID,
                        needsReplan: false,
                        needsReplanPreview: false
                    )
                )
                return
            }

            await MainActor.run {
                WorkflowRunCoordinator.shared.handleApprovalResponse(
                    runID: runID,
                    approved: approved,
                    response: userResponse
                )
            }

            await MainActor.run {
                if let lastMessage = plan.envelope.lastMessage,
                   lastMessage.metadata?[workflowRunIDKey] == runID {
                    resolvePendingControlMessage(
                        lastMessage,
                        content: approved ? "已批准该 workflow 步骤，继续执行中。" : "已拒绝该 workflow 步骤。"
                    )
                }

                messages.append(
                    ChatMessage(
                        id: UUID(),
                        role: .assistant,
                        content: approved ? "我已经收到你的审批结果，workflow 正在继续执行。" : "我已经记录这次拒绝，并停止当前 workflow 步骤。",
                        timestamp: Date(),
                        metadata: workflowPendingMetadata(
                            runID: runID,
                            taskDefinitionID: taskDefinitionID,
                            stepID: stepID,
                            needsReplan: false,
                            needsReplanPreview: false
                        )
                    )
                )
                isProcessing = false
            }
            return
        }

        if let pendingReplan = runState?.pendingReplan {
            let explicitDecision = RequestPlanningHeuristics.workflowApprovalDecision(from: userResponse)
            let hasAlternativeSteps = !RequestPlanningHeuristics.workflowStepsPreview(from: userResponse).isEmpty

            if explicitDecision == true {
                do {
                    let appliedSteps = try await MainActor.run {
                        try WorkflowRunCoordinator.shared.applyPreparedReplan(runID: runID)
                    }

                    await MainActor.run {
                        if let lastMessage = plan.envelope.lastMessage,
                           lastMessage.metadata?[workflowRunIDKey] == runID {
                            resolvePendingControlMessage(
                                lastMessage,
                                content: "已确认这份新的 workflow 方案，正在继续执行。"
                            )
                        }

                        messages.append(
                            ChatMessage(
                                id: UUID(),
                                role: .assistant,
                                content: "我已经应用新的 workflow 方案，后续会按 \(appliedSteps.count) 个更新后的步骤继续执行。",
                                timestamp: Date(),
                                metadata: workflowPendingMetadata(
                                    runID: runID,
                                    taskDefinitionID: taskDefinitionID,
                                    stepID: appliedSteps.first?.id,
                                    needsReplan: false,
                                    needsReplanPreview: false
                                )
                            )
                        )
                        isProcessing = false
                    }
                } catch {
                    await presentWorkflowError(
                        "应用新的 workflow 规划失败：\(error.localizedDescription)",
                        metadata: workflowPendingMetadata(
                            runID: runID,
                            taskDefinitionID: taskDefinitionID,
                            stepID: stepID,
                            needsReplan: true,
                            needsReplanPreview: true
                        )
                    )
                }
                return
            }

            if explicitDecision == false && !hasAlternativeSteps {
                await presentWorkflowError(
                    "好的，这个新方案先不应用。直接告诉我你希望怎么调整后续步骤，我会重新给你一版方案预览。",
                    metadata: workflowPendingMetadata(
                        runID: runID,
                        taskDefinitionID: taskDefinitionID,
                        stepID: pendingReplan.sourceStepID ?? stepID,
                        needsReplan: true,
                        needsReplanPreview: false
                    )
                )
                return
            }

            do {
                let preview = try await MainActor.run {
                    try WorkflowRunCoordinator.shared.prepareReplan(
                        runID: runID,
                        userInput: userResponse
                    )
                }

                await MainActor.run {
                    if let lastMessage = plan.envelope.lastMessage,
                       lastMessage.metadata?[workflowRunIDKey] == runID {
                        resolvePendingControlMessage(
                            lastMessage,
                            content: "已收到新的调整要求，我先生成了一版新的 workflow 方案预览。"
                        )
                    }
                    presentWorkflowReplanPreview(
                        runID: runID,
                        taskDefinitionID: taskDefinitionID,
                        preview: preview
                    )
                }
            } catch {
                await presentWorkflowError(
                    "生成新的 workflow 方案预览失败：\(error.localizedDescription)",
                    metadata: workflowPendingMetadata(
                        runID: runID,
                        taskDefinitionID: taskDefinitionID,
                        stepID: stepID,
                        needsReplan: true,
                        needsReplanPreview: false
                    )
                )
            }
            return
        }

        if case .waitingUser(let detail)? = runState?.blockingReason,
           detail.contains("需要重新规划") || plan.metadata[pendingWorkflowReplanKey] == "true" {
            do {
                let preview = try await MainActor.run {
                    try WorkflowRunCoordinator.shared.prepareReplan(
                        runID: runID,
                        userInput: userResponse
                    )
                }

                await MainActor.run {
                    if let lastMessage = plan.envelope.lastMessage,
                       lastMessage.metadata?[workflowRunIDKey] == runID {
                        resolvePendingControlMessage(
                            lastMessage,
                            content: "已收到新的规划要求，我先生成了一版新的 workflow 方案预览。"
                        )
                    }

                    presentWorkflowReplanPreview(
                        runID: runID,
                        taskDefinitionID: taskDefinitionID,
                        preview: preview
                    )
                    isProcessing = false
                }
            } catch {
                await presentWorkflowError(
                    "更新 workflow 规划失败：\(error.localizedDescription)",
                    metadata: workflowPendingMetadata(
                        runID: runID,
                        taskDefinitionID: taskDefinitionID,
                        stepID: stepID,
                        needsReplan: true,
                        needsReplanPreview: false
                    )
                )
            }
            return
        }

        guard let taskDefinitionID else {
            await presentWorkflowError("找不到要继续的 workflow 任务。")
            return
        }

        await unifiedTaskManager.continueTask(id: taskDefinitionID, with: userResponse)
        await MainActor.run {
            messages.append(
                ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: "我已经把你的补充发送给 workflow 任务，继续执行中。",
                    timestamp: Date(),
                    metadata: workflowPendingMetadata(
                        runID: runID,
                        taskDefinitionID: taskDefinitionID,
                        stepID: stepID,
                        needsReplan: false,
                        needsReplanPreview: false
                    )
                )
            )
            isProcessing = false
        }
    }

    private func workflowPendingMetadata(
        runID: String,
        taskDefinitionID: String?,
        stepID: String?,
        needsReplan: Bool,
        needsReplanPreview: Bool
    ) -> [String: String] {
        var metadata: [String: String] = [
            workflowRunIDKey: runID
        ]
        if let taskDefinitionID {
            metadata[workflowTaskDefinitionIDKey] = taskDefinitionID
        }
        if let stepID {
            metadata[workflowStepIDKey] = stepID
        }
        if needsReplan || needsReplanPreview {
            metadata[pendingWorkflowRunKey] = "true"
            metadata[pendingWorkflowReplanKey] = "true"
        }
        if needsReplanPreview {
            metadata[pendingWorkflowReplanPreviewKey] = "true"
        }
        return metadata
    }

    @MainActor
    private func createWorkflowDraft(
        candidate: WorkflowCandidate,
        originalInput: String
    ) throws -> WorkflowDraft {
        try WorkflowDraftService.shared.createDraft(from: candidate, originalInput: originalInput)
    }

    @MainActor
    private func updateWorkflowDraftSteps(
        draftID: String,
        steps: [WorkflowStepDef]
    ) throws -> WorkflowDraft {
        try WorkflowDraftService.shared.updateDraftSteps(draftID: draftID, steps: steps)
    }

    @MainActor
    private func upsertWorkflowDraftForClarification(
        plan: RequestPlan,
        candidate: WorkflowCandidate,
        slots: [PlanningSlot]
    ) throws -> WorkflowDraft {
        if let draftID = plan.metadata[workflowDraftIDKey] {
            return try WorkflowDraftService.shared.fillSlots(draftID: draftID, slots: slots)
        }

        return try WorkflowDraftService.shared.createDraft(
            from: candidate,
            originalInput: plan.envelope.originalText
        )
    }

    @MainActor
    private func publishedWorkflowDefinitionIfNeeded(id: String) throws -> WorkflowDefinition {
        if let definition = WorkflowDefinitionStore.shared.definition(id: id) {
            return definition
        }

        return try WorkflowDraftService.shared.publishDraft(draftID: id)
    }

    @MainActor
    private func presentWorkflowDraft(
        _ draft: WorkflowDraft,
        preface: String? = nil
    ) {
        var contentSections: [String] = []
        if let preface, !preface.isEmpty {
            contentSections.append(preface)
        }
        contentSections.append(WorkflowDraftService.shared.generateNextStepsSuggestion(draft: draft))
        if draft.status == .ready {
            contentSections.append(WorkflowDraftService.shared.generateExecutionPreview(draft: draft))
        }

        var metadata: [String: String] = [
            workflowDraftIDKey: draft.id,
            "workflow_candidate": draft.name
        ]
        if draft.status == .ready {
            metadata[pendingWorkflowDraftKey] = "true"
        } else if !draft.missingSlots.isEmpty {
            metadata[pendingWorkflowClarificationKey] = "true"
        }

        messages.append(
            ChatMessage(
                id: UUID(),
                role: .assistant,
                content: contentSections.joined(separator: "\n\n"),
                timestamp: Date(),
                metadata: metadata
            )
        )
        isProcessing = false
    }

    @MainActor
    private func presentWorkflowError(
        _ content: String,
        metadata: [String: String]? = nil
    ) {
        messages.append(
            ChatMessage(
                id: UUID(),
                role: .assistant,
                content: content,
                timestamp: Date(),
                metadata: metadata
            )
        )
        isProcessing = false
    }

    @MainActor
    private func presentWorkflowApprovalRequest(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let runID = userInfo["runID"] as? String,
              let message = userInfo["message"] as? String else {
            return
        }

        let taskDefinitionID = unifiedTaskManager.workflowTaskID(forRunID: runID)
        let stepID = (userInfo["approval"] as? PendingApproval)?.stepID
        var metadata: [String: String] = [
            pendingWorkflowRunKey: "true",
            workflowRunIDKey: runID
        ]
        if let taskDefinitionID, !taskDefinitionID.isEmpty {
            metadata[workflowTaskDefinitionIDKey] = taskDefinitionID
        }
        if let stepID, !stepID.isEmpty {
            metadata[workflowStepIDKey] = stepID
        }

        messages.append(
            ChatMessage(
                id: UUID(),
                role: .assistant,
                content: message,
                timestamp: Date(),
                metadata: metadata
            )
        )
        isProcessing = false
    }

    @MainActor
    private func presentWorkflowReplanRequest(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let runID = userInfo["runID"] as? String,
              let reason = userInfo["reason"] as? String else {
            return
        }

        let taskDefinitionID = unifiedTaskManager.workflowTaskID(forRunID: runID)
        let stepID = userInfo["stepID"] as? String
        var metadata: [String: String] = [
            pendingWorkflowRunKey: "true",
            pendingWorkflowReplanKey: "true",
            workflowRunIDKey: runID
        ]
        if let taskDefinitionID, !taskDefinitionID.isEmpty {
            metadata[workflowTaskDefinitionIDKey] = taskDefinitionID
        }
        if let stepID, !stepID.isEmpty {
            metadata[workflowStepIDKey] = stepID
        }
        let content = """
        当前 workflow 需要重新规划。

        原因：\(reason)

        直接告诉我你希望怎么调整后续步骤，例如“改成先收集未读消息，再生成回复草稿，最后等我确认发送”。
        """

        messages.append(
            ChatMessage(
                id: UUID(),
                role: .assistant,
                content: content,
                timestamp: Date(),
                metadata: metadata
            )
        )
        isProcessing = false
    }

    @MainActor
    private func presentWorkflowReplanPreview(
        runID: String,
        taskDefinitionID: String?,
        preview: PendingWorkflowReplan
    ) {
        let previewLines = preview.proposedSteps
            .enumerated()
            .map { "\($0.offset + 1). \($0.element.name)" }
            .joined(separator: "\n")
        let content = """
        我根据你的补充先生成了一版新的 workflow 方案预览：

        \(previewLines)

        如果你确认，就回复“确认”或“按这个执行”；如果还要改，直接继续描述你希望怎么调整。
        """

        var metadata = workflowPendingMetadata(
            runID: runID,
            taskDefinitionID: taskDefinitionID,
            stepID: preview.proposedSteps.first?.id ?? preview.sourceStepID,
            needsReplan: true,
            needsReplanPreview: true
        )
        metadata[workflowDraftIDKey] = preview.draftID

        messages.append(
            ChatMessage(
                id: UUID(),
                role: .assistant,
                content: content,
                timestamp: Date(),
                metadata: metadata
            )
        )
        isProcessing = false
    }

    private func presentProjectSkillOverview() async {
        let currentAgentName = orchestrator.currentAgent?.name
        LogInfo(
            "Presenting project skill overview currentAgent=\(currentAgentName ?? "none")"
        )
        let content = await openClawSkillOverviewMessage()
        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date(),
            agentId: orchestrator.currentAgent?.id,
            agentName: currentAgentName
        )

        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowSkillsBrowser"),
                object: nil
            )
            messages.append(message)
            isProcessing = false
        }
        LogInfo(
            "Project skill overview appended currentAgent=\(currentAgentName ?? "none")"
        )
    }

    private func projectSkillOverviewMessage() -> String {
        let currentAgent = orchestrator.currentAgent?.displayName ?? "当前 Agent"
        let builtinSummary = builtInSkillAudienceSummary()
        let toolCommands = toolSkillRegistry
            .allSkillNames()
            .map { "`/\($0)`" }
            .joined(separator: "、")

        return """
        我已经把 Skills 面板打开了。

        现在你能直接调用的能力，可以先这样理解：

        1. 对话内置能力
        \(builtinSummary)

        2. 命令型工具
        • 当前内置命令包括 \(toolCommands)
        • 更适合系统、文件、App、Git、Futu 这类明确操作

        3. Skills 管理
        • 在 Skills 面板可以查看内置技能、自定义技能和技能目录
        • 支持创建可进化的命令技能
        你现在正在使用 \(currentAgent)。
        直接告诉我目标就行，例如：
        • “帮我审查这个 PR”
        • “打开 Safari”
        • “总结这个设计文档的核心结论”
        """
    }

    private func openClawSkillOverviewMessage() async -> String {
        do {
            let report = try await fetchSkillsStatusForOverview(timeoutSeconds: 4)
            let eligibleSkills = report.skills.filter { $0.eligible && !$0.disabled }
            let unavailableSkills = report.skills.filter { !$0.eligible || $0.disabled }
            var sections: [String] = [
                "我已经把 Skills 面板打开了。",
                "你现在能直接用的能力，重点看这三层：",
                "1. 对话内置能力\n\(builtInSkillAudienceSummary())"
            ]

            if eligibleSkills.isEmpty {
                sections.append("2. 已就绪的扩展 Skills\n• 当前还没有可直接运行的外部 Skill。")
            } else {
                sections.append(
                    "2. 已就绪的扩展 Skills（\(eligibleSkills.count) 个）\n\(groupedSkillSummary(for: eligibleSkills))"
                )
            }

            if !unavailableSkills.isEmpty {
                sections.append(
                    "3. 还没就绪的扩展 Skills（\(unavailableSkills.count) 个）\n\(unavailableSkillSummary(for: unavailableSkills))"
                )
            } else {
                sections.append("3. 环境状态\n• 当前已检测到的扩展 Skills 都满足运行条件。")
            }

            sections.append(
                """
                如果这批能力还不够，你可以直接在 Skills 面板的“市场”页继续安装更多 Skills。
                也可以直接说目标，我会自己选最合适的能力，比如：
                • 帮我审查这个 PR
                • 检查这台 Mac 的安全配置
                • 总结这份会议纪要
                """
            )
            return sections.joined(separator: "\n\n")
        } catch {
            LogWarning(
                "Skills overview fallback triggered error=\(error.localizedDescription)"
            )
            return projectSkillOverviewMessage()
        }
    }

    private func fetchSkillsStatusForOverview(timeoutSeconds: Double) async throws -> SkillsStatusReport {
        let runtimeAdapter = self.runtimeAdapter
        return try await withThrowingTaskGroup(of: SkillsStatusReport.self) { group in
            group.addTask {
                try await runtimeAdapter.skillsStatus()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeoutSeconds, 0) * 1_000_000_000))
                throw NSError(
                    domain: "CommandRunner",
                    code: 18,
                    userInfo: [
                        NSLocalizedDescriptionKey: "skills.status timed out after \(Int(timeoutSeconds))s"
                    ]
                )
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw NSError(
                    domain: "CommandRunner",
                    code: 19,
                    userInfo: [NSLocalizedDescriptionKey: "skills.status returned no result"]
                )
            }

            group.cancelAll()
            return result
        }
    }

    private func builtInSkillAudienceSummary() -> String {
        let availableSkills = skillRegistry.skills.filter(skillRegistry.isAvailable)
        let grouped = Dictionary(grouping: availableSkills, by: builtInSkillAudienceGroupTitle(for:))
        let orderedTitles = ["视觉与截图", "文本与代码"]

        let lines = orderedTitles.compactMap { title -> String? in
            guard let skills = grouped[title], !skills.isEmpty else { return nil }
            let names = skills.map(\.name).joined(separator: "、")
            return "• \(title)：\(names)"
        }

        if lines.isEmpty {
            return "• 当前没有已就绪的内置 Skill。"
        }

        let unavailableCount = skillRegistry.skills.count - availableSkills.count
        if unavailableCount > 0 {
            return lines.joined(separator: "\n") + "\n• 另有 \(unavailableCount) 个内置 Skill 会在你切换到对应 Agent 后自动可用"
        }
        return lines.joined(separator: "\n")
    }

    private func builtInSkillAudienceGroupTitle(for skill: AISkill) -> String {
        switch skill {
        case .screenshot:
            return "视觉与截图"
        case .codeReview, .explainSelection, .translateText, .summarizeText:
            return "文本与代码"
        case .analyzeDisk:
            return "磁盘管理"
        }
    }

    private func presentSkillEvolutionOverview() async {
        let newlyDiscovered = skillEvolutionAdvisor.scanNow()
        if !newlyDiscovered.isEmpty {
            await MainActor.run {
                for proposal in newlyDiscovered {
                    presentSkillEvolutionProposal(proposal)
                }
            }
        }

        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: skillEvolutionAdvisor.summaryMessage(),
            timestamp: Date(),
            agentId: "builtin-skill-evolution-advisor",
            agentName: "Skill 迭代顾问"
        )

        await MainActor.run {
            messages.append(message)
            isProcessing = false
        }
    }

    private func presentPlannerConsoleStatus() async {
        let preferredPlannerAgentName: String = {
            if let agentID = preferences.plannerPreferredAgentID,
               let agent = agentStore.usableAgents.first(where: { $0.id == agentID }) {
                return agent.displayName
            }
            return "自动选择"
        }()

        let shadowStatus = preferences.plannerShadowEnabled ? "已开启" : "未开启"
        let content = """
        我已经把 **Skills > 设置 > Planner Console** 打开了。

        当前这条意图分析/调度链路的真实状态是：
        • 主 Planner：\(preferences.plannerPrimaryStrategy.displayName)
        • Planner Agent：\(preferredPlannerAgentName)
        • 影子对比：\(shadowStatus)
        • Dispatcher：已启用，会决定主会话 / side task
        • Local System Guard：已启用，只在高置信度系统操作时才会本地截走
        • Self-heal：已启用，负责 Agent 回退和 Kimi CLI 登录恢复

        你现在可以直接在面板里切换：
        • 规则优先
        • Planner Agent 接管
        • 是否开启影子对比
        • 由哪个 Agent 担任 Planner
        """

        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date(),
            agentId: "builtin-planner-console",
            agentName: "Planner Console"
        )

        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowSkillsBrowser"),
                object: "设置"
            )
            messages.append(message)
            isProcessing = false
        }
    }

    private func groupedSkillSummary(for skills: [SkillStatus]) -> String {
        let grouped = Dictionary(grouping: skills, by: skillGroupTitle(for:))
        let orderedTitles = ["开发与仓库", "系统与运维", "内容与平台", "信息查询", "扩展工具"]

        return orderedTitles.compactMap { title -> String? in
            guard let groupSkills = grouped[title], !groupSkills.isEmpty else { return nil }
            let lines = groupSkills
                .sorted(by: { $0.name < $1.name })
                .map { "• `\($0.name)`: \(friendlySummary(for: $0))" }
                .joined(separator: "\n")
            return "\(title)\n\(lines)"
        }
        .joined(separator: "\n\n")
    }

    private func unavailableSkillSummary(for skills: [SkillStatus]) -> String {
        let missingDependencies = Array(
            Set(
                skills.flatMap { skill in
                    skill.missing.bins + skill.missing.env + skill.missing.config
                }
            )
        )
        .sorted()

        let dependencyLine: String
        if missingDependencies.isEmpty {
            dependencyLine = "• 这些 Skill 当前主要是未启用状态。"
        } else {
            let preview = missingDependencies.prefix(6).map { "`\($0)`" }.joined(separator: "、")
            dependencyLine = "• 当前主要缺少这些依赖：\(preview)"
        }

        let detailLines = skills
            .prefix(4)
            .map { skill -> String in
                let missing = skill.missing.bins + skill.missing.env + skill.missing.config
                if missing.isEmpty {
                    return "• `\(skill.name)`: 当前未启用"
                }
                return "• `\(skill.name)`: 缺少 \(missing.joined(separator: ", "))"
            }
            .joined(separator: "\n")

        if detailLines.isEmpty {
            return dependencyLine
        }

        return """
        \(dependencyLine)
        \(detailLines)
        需要的话，我可以继续带你补环境，或者去市场安装替代 Skill。
        """
    }

    private func skillGroupTitle(for skill: SkillStatus) -> String {
        let haystack = "\(skill.name) \(skill.description)".lowercased()

        if haystack.contains("weather") || haystack.contains("forecast") || haystack.contains("temperature") {
            return "信息查询"
        }

        if haystack.contains("xiaohongshu") || haystack.contains("小红书") || haystack.contains("comment") || haystack.contains("favorite") || haystack.contains("post") {
            return "内容与平台"
        }

        if haystack.contains("health") || haystack.contains("security") || haystack.contains("firewall") || haystack.contains("ssh") || haystack.contains("risk") || haystack.contains("host") {
            return "系统与运维"
        }

        if haystack.contains("coding") || haystack.contains("code") || haystack.contains("git") || haystack.contains("github") || haystack.contains("repo") || haystack.contains("pr") || haystack.contains("session") {
            return "开发与仓库"
        }

        return "扩展工具"
    }

    private func friendlySummary(for skill: SkillStatus) -> String {
        switch skill.name {
        case "coding-agent":
            return "复杂编码任务、重构和 PR 处理"
        case "git-github-manager":
            return "Git / GitHub、PR、Issue、Release 管理"
        case "healthcheck":
            return "主机安全巡检、SSH / 防火墙 / 更新风险检查"
        case "session-logs":
            return "搜索和分析历史会话日志"
        case "weather":
            return "查询天气和短期预报"
        case "xiaohongshu-manager":
            return "管理小红书内容、互动和账号状态"
        default:
            return compactSkillDescription(skill.description)
        }
    }

    private func compactSkillDescription(_ description: String) -> String {
        let separators = [
            "Use when:",
            "NOT for:",
            "Requires ",
            "Requires:",
            " This skill",
            "\n"
        ]

        for separator in separators {
            if let range = description.range(of: separator) {
                let trimmed = description[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func presentAgentCreationGuidance(
        kind: AgentCreationRequestKind,
        originalInput: String
    ) async {
        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: agentCreationGuidanceMessage(for: kind, originalInput: originalInput),
            timestamp: Date(),
            agentId: "builtin-agent-creation-guard",
            agentName: "Agent 创建顾问",
            metadata: kind == .workflowDesign
                ? [
                    pendingWorkflowDesignKey: "true",
                    workflowOriginalInputKey: originalInput
                ]
                : nil
        )

        await MainActor.run {
            messages.append(message)
            isProcessing = false

            if kind == .runtimeSetup {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ShowInitialSetupWizard"),
                    object: nil
                )
            }
        }
    }

    private func agentCreationGuidanceMessage(
        for kind: AgentCreationRequestKind,
        originalInput: String
    ) -> String {
        switch kind {
        case .runtimeSetup:
            return """
            我已经把这次请求切到 **本地 Agent 配置流程**，不会再交给通用对话 Agent 去“自己创建 Agent”。

            当前应用里“创建 Agent”指的是：
            • 配置 provider / model / 凭证
            • 建立一个可被路由的模型入口

            我已经为你打开配置向导。完成后，这个 Agent 就能参与正常对话和自愈切换。
            """

        case .workflowDesign:
            return """
            这次你的需求更像是 **业务工作流 Agent**，不是当前应用里那种“模型接入型 Agent”。

            你描述的是：
            \(originalInput)

            当前版本的 Agent 目前只承载：
            • provider / model / 凭证
            • 基础能力路由（文本、代码、视觉等）

            还**不能**直接承载：
            • 专属业务规则
            • 定时任务 / 订阅 / 提醒
            • 服务编排 / 状态跟踪

            所以把这类需求直接交给 Kimi / OpenClaw 去“设计并创建 Agent”是不合理的，我已经拦截了这条路径，避免再掉进长任务收尾丢失。

            更合理的落法是：
            1. 先保留一个可用的基础模型 Agent
            2. 再把这类业务规则 / 定时触发 / 通知逻辑沉淀成 Skill 或 AutoAgent 工作流

            如果你愿意，我下一步会把这类业务工作流拆成一个**独立设计子任务**继续整理，不影响当前主会话，也不会再串回别的话题。
            你直接回复“可以 / 继续 / 按这个来”就行。
            """
        }
    }

    private func continueWorkflowDesignInSideSession(
        originalInput: String,
        followUpInput: String
    ) async {
        await startWorkflowDesignInSideSession(
            originalInput: originalInput,
            supplementalInput: followUpInput,
            startedFromConfirmation: true
        )
    }

    private func continueWorkflowDesignTaskSession(
        sessionID: String,
        originalInput: String,
        followUpInput: String
    ) async {
        let trimmedFollowUp = followUpInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFollowUp.isEmpty else {
            await MainActor.run {
                isProcessing = false
            }
            return
        }

        let preferredExistingAgent = await MainActor.run { () -> Agent? in
            guard let existing = taskSession(for: sessionID),
                  let delegateAgentID = existing.delegateAgentID else {
                return nil
            }
            return agentStore.usableAgents.first(where: { $0.id == delegateAgentID })
        }

        guard let worker = preferredExistingAgent ?? workflowDesignWorkerAgent() else {
            await MainActor.run {
                messages.append(
                    ChatMessage(
                        id: UUID(),
                        role: .assistant,
                        content: """
                        我准备继续细化这条业务工作流，但当前没有可用的文本 Agent 可以接手原来的设计任务。

                        先配置或恢复一个可用的文本 Agent 后，我就能继续沿这条工作流设计 session 往下补。
                        """,
                        timestamp: Date(),
                        agentId: "builtin-agent-creation-guard",
                        agentName: "Agent 创建顾问"
                    )
                )
                isProcessing = false
            }
            return
        }

        let request = workflowDesignPrompt(
            originalInput: originalInput,
            followUpInput: followUpInput,
            continuingExistingSession: true
        )

        _ = await MainActor.run {
            appendTaskSessionMessage(
                sessionID: sessionID,
                role: .user,
                content: "继续补充：\(trimmedFollowUp)",
                agentName: orchestrator.currentAgent?.name
            )
        }

        let result = await runTaskSession(
            sessionID: sessionID,
            agent: worker,
            text: request,
            images: []
        )

        await MainActor.run {
            if result.failed {
                isProcessing = false
                return
            }

            appendAssistantConversationMessage(
                """
                我继续把这条业务工作流细化完善了一轮：

                \(result.content)
                """,
                metadata: [
                    workflowTaskSessionIDKey: sessionID,
                    workflowOriginalInputKey: originalInput
                ]
            )
            isProcessing = false
        }
    }

    private func startWorkflowDesignInSideSession(
        originalInput: String,
        supplementalInput: String? = nil,
        startedFromConfirmation: Bool = false
    ) async {
        guard let worker = workflowDesignWorkerAgent() else {
            await MainActor.run {
                messages.append(
                    ChatMessage(
                        id: UUID(),
                        role: .assistant,
                        content: """
                        我准备继续整理这条业务工作流方案了，但当前没有可用的文本 Agent 可接手这个独立子任务。

                        先配置一个可用的文本 Agent 后，我就能把这类“工作流设计”拆成后台独立任务继续处理。
                        """,
                        timestamp: Date(),
                        agentId: "builtin-agent-creation-guard",
                        agentName: "Agent 创建顾问"
                    )
                )
                isProcessing = false
            }
            return
        }

        let request = workflowDesignPrompt(
            originalInput: originalInput,
            followUpInput: supplementalInput,
            continuingExistingSession: false
        )
        let sessionID = await MainActor.run {
            createWorkflowDesignTaskSession(
                originalInput: originalInput,
                followUpInput: supplementalInput,
                worker: worker
            )
        }

        let result = await runTaskSession(
            sessionID: sessionID,
            agent: worker,
            text: request,
            images: []
        )

        await MainActor.run {
            if result.failed {
                isProcessing = false
                return
            }

            appendAssistantConversationMessage(
                """
                \(startedFromConfirmation ? "我继续把这条业务工作流整理成了一版可落地方案：" : "我已经直接把这条业务工作流拆成独立设计任务，并整理出一版可落地方案：")

                \(result.content)
                """,
                metadata: [
                    workflowTaskSessionIDKey: sessionID,
                    workflowOriginalInputKey: originalInput
                ]
            )
            isProcessing = false
        }
    }

    private func workflowDesignWorkerAgent() -> Agent? {
        if let worker = agentStore.workflowDesignerPreferredAgent {
            return worker
        }

        return preferredAgent(for: .textChat)
    }

    private func workflowDesignPrompt(
        originalInput: String,
        followUpInput: String?,
        continuingExistingSession: Bool
    ) -> String {
        """
        你正在执行一个“业务工作流设计”独立子任务。目标是把用户想要的业务 Agent / Skill / AutoAgent 工作流整理成一版可落地的方案，而不是创建模型接入型 Agent。

        用户最初需求：
        \(originalInput)

        用户刚才的确认或补充：
        \(followUpInput?.isEmpty == false ? followUpInput! : "无，直接根据原始需求先给出第一版方案。")

        请直接给出面向用户的结果，结构尽量清晰，至少包含：
        1. 目标定义
        2. 触发方式（手动 / 定时 / 事件）
        3. 关键步骤
        4. 需要哪些能力或依赖
        5. 适合拆成哪些 Skill / AutoAgent / MCP / 定时任务
        6. 第一版最小可行方案
        7. 还需要用户补充的关键信息

        要求：
        - 只围绕当前用户需求，不要默认股票、富途、交易等旧场景。
        - 不要提内部路由、主会话、子会话等实现细节。
        - 用中文直接输出可读方案。
        \(continuingExistingSession ? "- 这次是在继续细化已有方案，请吸收用户这次补充，输出更新后的完整版本，避免只给零散补丁。" : "")
        """
    }

    @MainActor
    private func createWorkflowDesignTaskSession(
        originalInput: String,
        followUpInput: String?,
        worker: Agent
    ) -> String {
        var session = AgentTaskSession(
            title: "🧭 业务工作流设计 · 独立规划",
            originalRequest: originalInput,
            status: .queued,
            statusSummary: "已拆出工作流设计子任务，正在后台规划",
            mainAgentName: orchestrator.currentAgent?.name,
            delegateAgentID: worker.id,
            delegateAgentName: worker.name,
            intentName: "业务工作流设计",
            isExpanded: true,
            inputImages: [],
            canResume: false
        )
        session.gatewaySessionKey = gatewaySessionKey(forTaskSessionID: session.id)

        let taskCardMessage = ChatMessage(
            id: UUID(),
            role: .system,
            content: "已将业务工作流设计拆到独立子任务，不影响主会话。",
            timestamp: Date(),
            linkedTaskSessionID: session.id,
            metadata: [
                workflowTaskSessionIDKey: session.id,
                workflowOriginalInputKey: originalInput
            ]
        )
        session.linkedMainMessageID = taskCardMessage.id
        session.messages = [
            TaskSessionMessage(role: .system, content: "这条工作流设计会在独立上下文里继续整理，避免串回旧主会话话题。"),
            TaskSessionMessage(role: .user, content: originalInput, agentName: orchestrator.currentAgent?.name)
        ]

        if let followUpInput,
           !followUpInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.messages.append(
                TaskSessionMessage(
                    role: .user,
                    content: "继续说明：\(followUpInput)",
                    agentName: orchestrator.currentAgent?.name
                )
            )
        }

        messages.append(taskCardMessage)
        taskSessions.append(session)
        return session.id
    }

    private func handleToolSkillCommand(_ skillName: String, input: String) async {
        guard let skill = toolSkillRegistry.getSkill(skillName) else {
            await MainActor.run {
                isProcessing = false
            }
            return
        }

        let args = input.split(whereSeparator: \.isWhitespace).map(String.init)
        let responseIdentity = toolSkillIdentity(for: skillName)

        do {
            let result = try await skill.execute(input, args: args)
            let message = ChatMessage(
                id: UUID(),
                role: .assistant,
                content: result,
                timestamp: Date(),
                agentId: responseIdentity.id,
                agentName: responseIdentity.name
            )

            await MainActor.run {
                messages.append(message)
                isProcessing = false
            }
        } catch {
            let message = ChatMessage(
                id: UUID(),
                role: .assistant,
                content: UserFacingErrorFormatter.inlineMessage(for: error, providerName: "/\(skillName)"),
                timestamp: Date(),
                agentId: responseIdentity.id,
                agentName: responseIdentity.name
            )

            await MainActor.run {
                messages.append(message)
                isProcessing = false
            }
        }
    }

    private func toolSkillIdentity(for skillName: String) -> (id: String?, name: String?) {
        switch skillName {
        case "app", "futu":
            return ("builtin-mac-operator", "Mac 操作 Agent")
        default:
            return (orchestrator.currentAgent?.id, orchestrator.currentAgent?.name)
        }
    }

    private func presentSkillEvolutionProposal(_ proposal: SkillEvolutionProposal) {
        let evidence = proposal.evidence.map { "• \($0)" }.joined(separator: "\n")
        let improvements = proposal.improvements.map { "• \($0)" }.joined(separator: "\n")

        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: """
            💡 检测到一条 Skill 优化提案

            目标 Skill: \(proposal.skillName)
            版本变化: v\(proposal.currentVersion) -> v\(proposal.suggestedVersion)
            原因: \(proposal.reason)

            观察依据：
            \(evidence)

            建议落地：
            \(improvements)

            回复 "是" 或 "y" 确认应用这条优化
            回复 "否" 或 "n" 忽略这条提案
            """,
            timestamp: Date(),
            agentId: "builtin-skill-evolution-advisor",
            agentName: "Skill 迭代顾问",
            metadata: ["pending_skill_evolution_id": proposal.id]
        )

        messages.append(message)
    }
    
    /// 处理纯净输入
    private func processCleanInput(_ text: String, images: [String], anchorMessageID: UUID) async {
        let preferCurrentAgent = RequestPlanningHeuristics.shouldRespectCurrentAgentSelection(
            for: text,
            images: images,
            currentAgent: orchestrator.currentAgent
        )

        // 检测意图
        let intent = await orchestrator.analyzeIntent(text)
        
        // 路由决策
        let routingResult = await orchestrator.route(
            text,
            images: images,
            intent: intent,
            preferCurrentAgent: preferCurrentAgent
        )
        
        // 处理路由结果
        switch routingResult {
        case .agentSelected(let agent):
            await handleAgentRequest(
                agent: agent,
                text: text,
                images: images,
                intent: intent,
                anchorMessageID: anchorMessageID
            )
            
        case .gapDetected(let gap):
            await handleCapabilityGapInChat(gap: gap)
            
        case .multipleAgents(let agents):
            await handleMultipleAgentOptions(agents: agents, text: text, images: images)
        }
    }

    /// 处理截图命令
    func handleScreenshot() {
        Task {
            let canCapture = await MainActor.run {
                ensureScreenRecordingAccessForScreenshot()
            }
            guard canCapture else { return }

            guard let screenshotPath = saveScreenshotToDesktop() else {
                await MainActor.run {
                    appendSystemMessage(
                        "这次没有生成截图文件。可能是你取消了截图，或者屏幕录制权限还没有真正生效。"
                    )
                }
                return
            }

            await MainActor.run {
                completeScreenshotFlow(with: screenshotPath)
            }
        }
    }
    
    // MARK: - 智能处理方法
    
    /// 处理 Agent 切换（带能力检查）
    private func handleAgentSwitch(_ agent: Agent, reason: String, requiredCapability: Capability? = nil) async -> Bool {
        // 检查是否需要特定能力
        if let capability = requiredCapability {
            if !agent.supports(capability) {
                // Agent 不支持所需能力，引导创建而不是切换
                let gap = CapabilityGap(
                    missingCapability: capability,
                    suggestedProviders: [.openai, .anthropic, .moonshot],
                    description: "\(agent.displayName) 不支持 \(capability.displayName) 能力"
                )
                
                let systemMessage = ChatMessage(
                    id: UUID(),
                    role: MessageRole.system,
                    content: """
                    ⚠️ \(agent.displayName) 不支持 \(capability.displayName)
                    
                    💡 我可以立即帮你创建一个支持此能力的 Agent：
                    """,
                    timestamp: Date()
                )
                
                await MainActor.run {
                    messages.append(systemMessage)
                    creationSkill.initiateCreation(for: gap, in: self)
                    isProcessing = false
                }
                
                // 记录能力缺口
                logger.logCapabilityGap(gap, context: "切换 Agent 时发现能力不匹配")
                return false
            }
        }
        
        let previousAgent = orchestrator.currentAgent
        orchestrator.switchToAgent(agent)
        
        // 记录 Agent 切换
        logger.logAgentSwitch(from: previousAgent, to: agent, reason: reason)
        
        let systemMessage = ChatMessage(
            id: UUID(),
            role: MessageRole.system,
            content: "🔄 \(reason)，已切换到 \(agent.displayName)",
            timestamp: Date()
        )
        await MainActor.run {
            messages.append(systemMessage)
        }
        return true
    }
    
    /// 处理 Skill 命令
    private func handleSkillCommand(_ skill: AISkill, input: String, images: [String]) async {
        let startTime = Date()
        
        let context = MacAssistant.SkillContext(
            input: input,
            images: images,
            currentAgent: orchestrator.currentAgent,
            runner: self
        )
        
        let result = await skillRegistry.execute(skill, context: context)
        let duration = Date().timeIntervalSince(startTime)
        
        // 记录 Skill 执行
        logger.logSkillExecution(skill, result: result, duration: duration)
        
        await MainActor.run {
            isProcessing = false
            handleSkillResult(result, for: skill)
        }
    }
    
    /// 处理检测到的 Skill 意图（带确认，考虑用户偏好）
    private func handleDetectedSkill(
        _ skill: AISkill,
        input: String,
        executionInput: String? = nil,
        images: [String],
        anchorMessageID: UUID
    ) async {
        if preferences.shouldSkipDetection(skill) {
            await processCleanInput(executionInput ?? input, images: images, anchorMessageID: anchorMessageID)
            return
        }

        if preferences.shouldAutoConfirm(skill) {
            preferences.recordSkillAcceptance(skill)
            await runDetectedSkillInSideSession(
                skill: skill,
                input: executionInput ?? input,
                images: images,
                suggestionMessageID: nil
            )
            return
        }

        let confirmMessage = ChatMessage(
            id: UUID(),
            role: MessageRole.assistant,
            content: "已检测到 \(skill.name) 意图",
            timestamp: Date(),
            agentId: "builtin-skill-suggester",
            agentName: "意图建议",
            metadata: [
                ChatMessage.detectedSkillKey: skill.rawValue,
                ChatMessage.detectedSkillInputKey: input,
                ChatMessage.detectedSkillExecutionInputKey: executionInput ?? input,
                ChatMessage.detectedSkillSourceKey: "自然意图"
            ]
        )
        await MainActor.run {
            messages.append(confirmMessage)
            isProcessing = false
        }
    }

    @MainActor
    func handleDetectedSkillSuggestionAction(
        messageID: UUID,
        action: DetectedSkillSuggestionAction,
        images: [String] = []
    ) async {
        guard let message = messages.first(where: { $0.id == messageID }),
              let suggestion = message.detectedSkillSuggestion else {
            return
        }

        switch action {
        case .runOnce:
            preferences.recordSkillAcceptance(suggestion.skill)
            await runDetectedSkillInSideSession(
                skill: suggestion.skill,
                input: suggestion.executionInput,
                images: images,
                suggestionMessageID: messageID
            )

        case .dismissOnce:
            preferences.recordSkillRejection(suggestion.skill)
            resolveDetectedSkillSuggestionMessage(
                messageID: messageID,
                content: "已跳过这次 \(suggestion.skill.name) 建议。后续是否继续提示，可以在 Skills > 设置 里修改。"
            )
            isProcessing = false

        case .alwaysAutoRun:
            preferences.setDetectionPreference(.autoRun, for: suggestion.skill)
            preferences.recordSkillAcceptance(suggestion.skill)
            await runDetectedSkillInSideSession(
                skill: suggestion.skill,
                input: suggestion.executionInput,
                images: images,
                suggestionMessageID: messageID
            )

        case .neverSuggest:
            preferences.setDetectionPreference(.neverSuggest, for: suggestion.skill)
            resolveDetectedSkillSuggestionMessage(
                messageID: messageID,
                content: "后续不再主动建议 \(suggestion.skill.name)。你仍然可以通过 `/\(suggestion.skill.rawValue)` 手动调用。"
            )
            isProcessing = false
        }
    }
    
    /// 处理 Agent 建议
    private func handleAgentSuggestion(_ suggestion: AgentSuggestion, input: String, images: [String]) async {
        switch suggestion.action {
        case .switchAgent:
            if let agent = suggestion.suggestedAgent {
                if shouldAutoDelegateToSuggestedAgent(input: input, images: images, suggestedAgent: agent) {
                    await delegateRequest(
                        to: agent,
                        text: input,
                        images: images,
                        intent: .imageAnalysis,
                        reason: "当前 Agent 不支持图片分析，已自动委托给 \(agent.displayName) 继续处理这次图片请求。"
                    )
                    return
                }

                let confirmMessage = ChatMessage(
                    id: UUID(),
                    role: MessageRole.assistant,
                    content: """
                    💡 \(suggestion.reason)
                    
                    建议切换到 \(agent.displayName) 来处理此请求。
                    
                    是否切换？
                    回复 "是" 或 "y" 确认切换并发送消息。
                    回复 "否" 或 "n" 使用当前 Agent 继续。
                    """,
                    timestamp: Date(),
                    metadata: ["pending_switch": agent.id, "pending_input": input]
                )
                await MainActor.run {
                    messages.append(confirmMessage)
                    isProcessing = false
                }
            }
            
        case .createVisionAgent:
            // 直接进入 Agent 创建流程
            if let gap = orchestrator.discoverGap(for: input) {
                await MainActor.run {
                    creationSkill.initiateCreation(for: gap, in: self)
                    isProcessing = false
                }
            }
        }
    }
    
    /// 处理 Skill 执行结果
    private func handleSkillResult(_ result: SkillResult, for skill: AISkill) {
        switch result {
        case .success(let message):
            let successMessage = ChatMessage(
                id: UUID(),
                role: MessageRole.assistant,
                content: "✅ \(skill.name) 执行成功：\(message)",
                timestamp: Date()
            )
            messages.append(successMessage)
            
        case .requiresInput(let prompt):
            let inputMessage = ChatMessage(
                id: UUID(),
                role: MessageRole.assistant,
                content: "🎯 **\(skill.name)** 需要更多信息：\n\n\(prompt)",
                timestamp: Date()
            )
            messages.append(inputMessage)
            
        case .requiresAgentCreation(let gap):
            creationSkill.initiateCreation(for: gap, in: self)
            
        case .error(let message):
            let errorMessage = ChatMessage(
                id: UUID(),
                role: MessageRole.assistant,
                content: "❌ \(skill.name) 执行失败：\(message)",
                timestamp: Date()
            )
            messages.append(errorMessage)
        }
    }

    private func runDetectedSkillInSideSession(
        skill: AISkill,
        input: String,
        images: [String],
        suggestionMessageID: UUID?
    ) async {
        let sessionID = await MainActor.run {
            isProcessing = false
            return createDetectedSkillTaskSession(
                skill: skill,
                request: input,
                images: images,
                suggestionMessageID: suggestionMessageID
            )
        }

        Task {
            await executeDetectedSkillTask(
                sessionID: sessionID,
                skill: skill,
                input: input,
                images: images
            )
        }
    }

    @MainActor
    private func createDetectedSkillTaskSession(
        skill: AISkill,
        request: String,
        images: [String],
        suggestionMessageID: UUID?
    ) -> String {
        var session = AgentTaskSession(
            title: "\(skill.emoji) \(skill.name) · 独立处理",
            originalRequest: request,
            status: .running,
            statusSummary: "已从主会话拆出，正在后台独立处理",
            mainAgentName: orchestrator.currentAgent?.name,
            delegateAgentID: "builtin-skill-\(skill.rawValue)",
            delegateAgentName: skill.name,
            intentName: "独立处理",
            isExpanded: true,
            inputImages: images,
            canResume: false
        )
        session.gatewaySessionKey = gatewaySessionKey(forTaskSessionID: session.id)

        let linkedMessageID: UUID
        let linkedTimestamp: Date

        if let suggestionMessageID,
           let existingMessage = messages.first(where: { $0.id == suggestionMessageID }) {
            linkedMessageID = existingMessage.id
            linkedTimestamp = existingMessage.timestamp

            replaceMessage(
                id: existingMessage.id,
                with: ChatMessage(
                    id: existingMessage.id,
                    role: .system,
                    content: "已将 \(skill.name) 拆到独立处理，不影响主会话。",
                    timestamp: linkedTimestamp,
                    linkedTaskSessionID: session.id
                )
            )
        } else {
            let taskCardMessage = ChatMessage(
                id: UUID(),
                role: .system,
                content: "已将 \(skill.name) 拆到独立处理，不影响主会话。",
                timestamp: Date(),
                linkedTaskSessionID: session.id
            )
            linkedMessageID = taskCardMessage.id
            linkedTimestamp = taskCardMessage.timestamp
            messages.append(taskCardMessage)
        }

        session.linkedMainMessageID = linkedMessageID
        session.messages = [
            TaskSessionMessage(role: .system, content: "该 Skill 以独立任务方式执行，不阻塞主会话。"),
            TaskSessionMessage(role: .user, content: request, timestamp: linkedTimestamp, agentName: orchestrator.currentAgent?.name)
        ]

        taskSessions.append(session)
        return session.id
    }

    private func executeDetectedSkillTask(
        sessionID: String,
        skill: AISkill,
        input: String,
        images: [String]
    ) async {
        let startTime = Date()
        let context = MacAssistant.SkillContext(
            input: input,
            images: images,
            currentAgent: orchestrator.currentAgent,
            runner: self
        )

        await MainActor.run {
            appendTaskSessionMessage(
                sessionID: sessionID,
                role: .assistant,
                content: "\(skill.name) 已开始执行，结果会单独回流到这张卡片。",
                agentName: skill.name
            )
            updateTaskSessionStatus(
                sessionID: sessionID,
                status: .running,
                summary: "\(skill.name) 正在独立处理，不影响当前对话。"
            )
        }

        let result = await skillRegistry.execute(skill, context: context)
        let duration = Date().timeIntervalSince(startTime)
        logger.logSkillExecution(skill, result: result, duration: duration)

        await MainActor.run {
            switch result {
            case .success(let message):
                appendTaskSessionMessage(
                    sessionID: sessionID,
                    role: .assistant,
                    content: message,
                    agentName: skill.name
                )
                updateTaskSessionStatus(
                    sessionID: sessionID,
                    status: .completed,
                    summary: "\(skill.name) 已返回结果",
                    isExpanded: true,
                    resultSummary: summarizeTaskResult(message),
                    errorMessage: nil
                )

            case .requiresInput(let prompt):
                appendTaskSessionMessage(
                    sessionID: sessionID,
                    role: .system,
                    content: prompt,
                    agentName: skill.name
                )
                updateTaskSessionStatus(
                    sessionID: sessionID,
                    status: .waitingUser,
                    summary: "\(skill.name) 还需要更多输入",
                    isExpanded: true,
                    resultSummary: nil,
                    errorMessage: prompt
                )

            case .requiresAgentCreation(let gap):
                let prompt = "\(skill.name) 还缺少 \(gap.missingCapability.displayName) 能力：\(gap.description)"
                appendTaskSessionMessage(
                    sessionID: sessionID,
                    role: .system,
                    content: prompt,
                    agentName: skill.name
                )
                updateTaskSessionStatus(
                    sessionID: sessionID,
                    status: .waitingUser,
                    summary: "\(skill.name) 需要先补齐能力",
                    isExpanded: true,
                    resultSummary: nil,
                    errorMessage: prompt
                )
                NotificationCenter.default.post(
                    name: NSNotification.Name("ShowCapabilityWizard"),
                    object: gap
                )

            case .error(let message):
                appendTaskSessionMessage(
                    sessionID: sessionID,
                    role: .system,
                    content: message,
                    agentName: skill.name
                )
                updateTaskSessionStatus(
                    sessionID: sessionID,
                    status: .failed,
                    summary: "\(skill.name) 没有成功完成",
                    isExpanded: true,
                    resultSummary: nil,
                    errorMessage: message
                )
            }
        }
    }

    @MainActor
    private func cancelPendingFlow(_ plan: RequestPlan) {
        var cancelledItems: [String] = []
        func record(_ label: String) {
            guard !cancelledItems.contains(label) else { return }
            cancelledItems.append(label)
        }

        if creationSkill.isInCreationFlow {
            creationSkill.cancel()
            record("Agent 创建流程")
        }

        if let browserLabel = BrowserSessionCoordinator.shared.cancelPendingFlow(
            sessionID: plan.envelope.activeBrowserSession?.id ??
                plan.envelope.lastMessage?.metadata?[BrowserConversationMetadataKeys.pendingSessionID]
        ) {
            record(browserLabel)
        }

        if let lastMessage = plan.envelope.lastMessage,
           let label = resolvePendingFlowCancellation(for: lastMessage) {
            record(label)
        }

        if plan.envelope.activeWorkflowDesignContext != nil,
           plan.envelope.lastMessage?.metadata?[pendingWorkflowDesignKey] != "true" {
            record("独立规划跟进")
        }

        let content: String
        if cancelledItems.isEmpty {
            content = "主会话没有检测到仍在等待处理的挂起流程，继续普通对话。"
        } else {
            content = "主会话已取消\(cancelledItems.joined(separator: "、"))，继续普通对话。"
        }

        messages.append(
            ChatMessage(
                id: UUID(),
                role: .assistant,
                content: content,
                timestamp: Date(),
                agentId: "builtin-main-session-guard",
                agentName: "主会话"
            )
        )
        isProcessing = false
    }

    @MainActor
    private func executeBrowserSessionStart(url: String, originalInput: String) async {
        let messages = await BrowserSessionCoordinator.shared.startSession(
            url: url,
            originalInput: originalInput
        )
        for message in messages {
            self.messages.append(message)
        }
        isProcessing = false
    }

    @MainActor
    private func executeBrowserSessionContinuation(sessionID: String, input: String) async {
        let messages = await BrowserSessionCoordinator.shared.continueSession(
            sessionID: sessionID,
            userInput: input
        )
        for message in messages {
            self.messages.append(message)
        }
        isProcessing = false
    }

    @MainActor
    private func resolvePendingFlowCancellation(for message: ChatMessage) -> String? {
        if message.metadata?[initialSetupPromptKey] == "true" {
            resolvePendingControlMessage(
                message,
                content: "已取消这次初始化配置提醒，主会话继续。"
            )
            return "初始化配置提醒"
        }

        if let pendingSwitchAgentID = message.metadata?["pending_switch"] {
            let agentName = agentStore.agent(withId: pendingSwitchAgentID)?.displayName ?? "目标 Agent"
            resolvePendingControlMessage(
                message,
                content: "已取消切换到 \(agentName) 的建议，继续保留当前主会话。"
            )
            return "Agent 切换建议"
        }

        if message.metadata?["pending_skill_evolution_id"] != nil {
            resolvePendingControlMessage(
                message,
                content: "已取消这次 Skill 优化提案确认，主会话继续。"
            )
            return "Skill 优化提案"
        }

        if message.metadata?[pendingWorkflowDesignKey] == "true" {
            resolvePendingControlMessage(
                message,
                content: "已取消这次业务规划引导，主会话继续。"
            )
            return "业务规划引导"
        }

        if let draftID = message.metadata?[workflowDraftIDKey],
           (
            message.metadata?[pendingWorkflowClarificationKey] == "true" ||
            message.metadata?[pendingWorkflowDraftKey] == "true"
           ) {
            try? WorkflowDraftService.shared.discardDraft(draftID: draftID)
            resolvePendingControlMessage(
                message,
                content: "已取消这次 workflow 草稿创建，主会话继续。"
            )
            return "Workflow 草稿创建"
        }

        if let workflowRunID = message.metadata?[workflowRunIDKey],
           message.metadata?[pendingWorkflowRunKey] == "true" {
            if let draftID = message.metadata?[workflowDraftIDKey] {
                try? WorkflowDraftService.shared.discardDraft(draftID: draftID)
            }
            WorkflowRunCoordinator.shared.cancelWorkflow(runID: workflowRunID)
            resolvePendingControlMessage(
                message,
                content: "已取消当前 workflow 的等待流程，主会话继续。"
            )
            return "Workflow 等待流程"
        }

        if message.metadata?[BrowserConversationMetadataKeys.pendingSessionID] != nil {
            resolvePendingControlMessage(
                message,
                content: "已取消这次网页协同流程，主会话继续。"
            )
            return "网页协同流程"
        }

        if let suggestion = message.detectedSkillSuggestion {
            resolveDetectedSkillSuggestionMessage(
                messageID: message.id,
                content: "已取消这次 \(suggestion.skill.name) 建议，主会话继续。"
            )
            return "\(suggestion.skill.name) 建议"
        }

        if let pendingSkill = message.metadata?["pending_skill"],
           let skill = AISkill(rawValue: pendingSkill) {
            resolvePendingControlMessage(
                message,
                content: "已取消这次 \(skill.name) 建议，主会话继续。"
            )
            return "\(skill.name) 建议"
        }

        return nil
    }

    @MainActor
    private func resolvePendingControlMessage(_ message: ChatMessage, content: String) {
        replaceMessage(
            id: message.id,
            with: ChatMessage(
                id: message.id,
                role: .system,
                content: content,
                timestamp: message.timestamp,
                linkedTaskSessionID: message.linkedTaskSessionID
            )
        )
    }

    @MainActor
    private func resolveDetectedSkillSuggestionMessage(messageID: UUID, content: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let timestamp = messages[index].timestamp
        replaceMessage(
            id: messageID,
            with: ChatMessage(
                id: messageID,
                role: .system,
                content: content,
                timestamp: timestamp
            )
        )
    }

    @MainActor
    private func replaceMessage(id: UUID, with message: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        var updatedMessages = messages
        updatedMessages[index] = message
        messages = updatedMessages
    }
    
    // MARK: - 路由处理
    
    /// 使用选定 Agent 处理请求
    private func handleAgentRequest(
        agent: Agent,
        text: String,
        images: [String],
        intent: Intent,
        anchorMessageID: UUID
    ) async {
        // 使用统一的 sessionID 用于日志和 trace
        let sessionID = anchorMessageID.uuidString
        
        // 启动执行链路日志
        _ = await ExecutionLogger.shared.startSession(
            id: sessionID,
            userRequest: text
        )
        
        let traceID = await MainActor.run {
            startExecutionTrace(
                anchorMessageID: anchorMessageID,
                agentName: agent.displayName,
                intentName: intent.displayName,
                summary: "原生运行时正在把这次请求交给 \(agent.displayName)",
                sessionID: sessionID
            )
        }
        
        // 发送给运行时适配器（默认原生，必要时回退到兼容层）
        await sendToRuntime(
            agent: agent,
            text: text,
            images: images,
            traceID: traceID,
            sessionID: sessionID,
            allowMemoryRecall: true
        )
    }
    
    /// 处理能力缺口（聊天内引导）
    private func handleCapabilityGapInChat(gap: CapabilityGap) async {
        // 记录能力缺口
        logger.logCapabilityGap(gap, context: "处理用户请求时检测到")
        
        // 检查是否是图片分析需求
        if gap.missingCapability == .vision || gap.missingCapability == .imageAnalysis {
            // 启动对话引导创建
            await MainActor.run {
                creationSkill.initiateCreation(for: gap, in: self)
            }
        } else {
            // 其他能力缺口，显示简单提示
            let message = ChatMessage(
                id: UUID(),
                role: .assistant,
                content: """
                💡 需要 **\(gap.missingCapability.displayName)** 能力
                
                \(gap.description)
                
                建议的提供商: \(gap.suggestedProviders.map { $0.displayName }.joined(separator: ", "))
                
                您可以在 Agent 列表中创建一个支持此能力的 Agent。
                """,
                timestamp: Date()
            )
            await MainActor.run {
                messages.append(message)
                isProcessing = false
            }
        }
    }
    
    /// 处理多个可选 Agent
    private func handleMultipleAgentOptions(agents: [Agent], text: String, images: [String]) async {
        var options = "找到多个可用的 Agent:\n\n"
        for (index, agent) in agents.enumerated() {
            options += "\(index + 1). \(agent.displayName) - \(agent.shortDescription)\n"
        }
        options += "\n回复数字选择，或直接输入继续。"
        
        let message = ChatMessage(
            id: UUID(),
            role: .system,
            content: options,
            timestamp: Date()
        )
        await MainActor.run {
            messages.append(message)
            isProcessing = false
        }
    }
    
    // MARK: - 视觉能力缺口处理
    
    private func handleVisionGap(screenshotPath: String) {
        if let agent = preferredAgent(for: .vision) {
            Task {
                await delegateRequest(
                    to: agent,
                    text: "分析这张截图",
                    images: [screenshotPath],
                    intent: .imageAnalysis,
                    reason: "当前 Agent 不支持图片分析，已自动委托给 \(agent.displayName) 处理刚才的截图。"
                )
            }
            return
        }

        // 检测能力缺口
        if let gap = orchestrator.discoverGap(for: "分析这张截图") {
            // 在聊天中启动创建流程
            creationSkill.initiateCreation(for: gap, in: self)
        }
    }
    
    // MARK: - 运行时适配器
    
    private func sendToRuntime(
        agent: Agent,
        text: String,
        images: [String],
        traceID: UUID? = nil,
        sessionID: String? = nil,
        allowMemoryRecall: Bool = true
    ) async {
        let startTime = Date()
        let mainSession = conversationControl.currentTopology()
        // 使用传入的 sessionID 或生成新的
        let logSessionID = sessionID ?? UUID().uuidString
        
        // MARK: - 统一记忆检索（向量化匹配，无需关键词触发）
        var memoryContext: UnifiedMemoryContext?
        if allowMemoryRecall {
            memoryContext = await retrieveUnifiedMemoryContext(
                text: text,
                sessionKey: mainSession.mainSessionKey,
                turns: messages.map { ConversationRecallTurn(role: $0.role.rawValue, content: $0.content) }
            )
            
            // 如果找到相关记忆，注入到对话中
            if let context = memoryContext, await UnifiedMemoryCoordinator.shared.shouldInjectMemory(context) {
                do {
                    try await runtimeAdapter.injectAssistantMessage(
                        sessionKey: mainSession.mainSessionKey,
                        message: context.formattedContext,
                        label: "Memory Context"
                    )
                    LogInfo("[CommandRunner] 注入统一记忆上下文: \(context.summary)")
                } catch {
                    LogWarning("[CommandRunner] 记忆上下文注入失败: \(error)")
                }
            }
        }
        let assistantMessage = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: "⏳ \(agent.name) 正在思考...",
            timestamp: Date(),
            agentId: agent.id,
            agentName: agent.name
        )
        
        do {
            await MainActor.run {
                messages.append(assistantMessage)
                if let traceID {
                    attachExecutionTrace(traceID: traceID, to: assistantMessage.id)
                    updateExecutionTrace(
                        traceID: traceID,
                        state: .running,
                        agentName: agent.displayName,
                        summary: "\(agent.displayName) 正在返回结果"
                    )
                }
            }

            // 记录开始发送（使用统一的 sessionID）
            await ExecutionLogger.shared.log(
                sessionID: logSessionID,
                level: .info,
                component: "RuntimeAdapter",
                message: "开始发送请求",
                details: [
                    "agent": agent.name,
                    "sessionKey": mainSession.mainSessionKey
                ]
            )
            
            LogInfo("[CommandRunner] 请求交由 \(type(of: runtimeAdapter)) 处理")
            
            let fullContent = try await sendViaGateway(
                agent: agent,
                sessionKey: mainSession.mainSessionKey,
                sessionLabel: mainSession.mainSessionLabel,
                text: text,
                images: images,
                assistantMessageID: assistantMessage.id,
                traceID: traceID
            )
            
            let duration = Date().timeIntervalSince(startTime)
            logger.logSystemResponse(fullContent, agent: agent)
            logger.logPerformance(operation: "runtime_request", duration: duration)
            
            // 记录成功完成
            await ExecutionLogger.shared.log(
                sessionID: logSessionID,
                level: .success,
                component: "Runtime",
                message: "请求处理完成",
                details: ["duration": "\(String(format: "%.2f", duration))s"]
            )
            await ExecutionLogger.shared.endSession(
                id: logSessionID,
                status: .completed
            )
            
            await MainActor.run {
                upsertAssistantMessage(
                    template: assistantMessage,
                    content: fullContent
                )
                if let traceID {
                    completeExecutionTrace(traceID: traceID, summary: "这次请求已处理完成")
                }
                isProcessing = false
            }
            
        } catch {
            logger.logError(error, context: "运行时请求失败")

            var terminalError = error
            var terminalAgent = agent

            await maybeStartKimiCLILoginRecovery(after: error, for: agent)

            if UserFacingErrorFormatter.shouldTemporarilySuspendAgent(after: error) {
                agentStore.markTemporarilyUnavailable(agent)
            }

            for fallbackAgent in fallbackAgentsForRecoverableFailure(
                after: error,
                failingAgent: agent,
                images: images
            ) {
                logger.logAgentSwitch(
                    from: agent,
                    to: fallbackAgent,
                    reason: "\(UserFacingErrorFormatter.recoveryFailureSummary(for: error))后自动切换到可用 Agent"
                )
                orchestrator.switchToAgent(fallbackAgent)

                await MainActor.run {
                    if let traceID {
                        updateExecutionTrace(
                            traceID: traceID,
                            state: .fallback,
                            agentName: fallbackAgent.displayName,
                            transitionLabel: "自动回退",
                            summary: "\(agent.displayName) \(UserFacingErrorFormatter.recoveryFailureSummary(for: error))，已切换到 \(fallbackAgent.displayName)"
                        )
                    }
                    updateAssistantIdentity(
                        id: assistantMessage.id,
                        agentId: fallbackAgent.id,
                        agentName: fallbackAgent.name
                    )
                    upsertAssistantMessage(
                        template: ChatMessage(
                            id: assistantMessage.id,
                            role: .assistant,
                            content: "⏳ \(fallbackAgent.name) 正在继续处理...",
                            timestamp: assistantMessage.timestamp,
                            agentId: fallbackAgent.id,
                            agentName: fallbackAgent.name
                        ),
                        content: "⏳ \(fallbackAgent.name) 正在继续处理..."
                    )
                    
                    // 同步到主会话：Agent 回退
                    let fallbackReason = UserFacingErrorFormatter.recoveryFailureSummary(for: error)
                    upsertConversationProgressMessage(
                        key: "agent_fallback_\(assistantMessage.id)",
                        content: "**\(agent.displayName)** \(fallbackReason)，正在切换到 **\(fallbackAgent.name)** 继续处理...",
                        agentID: fallbackAgent.id,
                        agentName: fallbackAgent.name,
                        metadata: [
                            "message_key": "agent_fallback_\(assistantMessage.id)",
                            "is_progress_update": "true",
                            "progress_source": "agent_fallback",
                            "from_agent": agent.id,
                            "from_agent_name": agent.displayName,
                            "to_agent": fallbackAgent.id,
                            "to_agent_name": fallbackAgent.name,
                            "fallback_reason": fallbackReason
                        ]
                    )
                }

                do {
                    terminalAgent = fallbackAgent
                    let fallbackContent = try await sendViaGateway(
                        agent: fallbackAgent,
                        sessionKey: mainSession.mainSessionKey,
                        sessionLabel: mainSession.mainSessionLabel,
                        text: text,
                        images: images,
                        assistantMessageID: assistantMessage.id,
                        traceID: traceID
                    )

                    let duration = Date().timeIntervalSince(startTime)
                    logger.logSystemResponse(fallbackContent, agent: fallbackAgent)
                    logger.logPerformance(operation: "openclaw_request_auth_fallback", duration: duration)
                    agentStore.restoreAvailability(for: fallbackAgent)

                    await MainActor.run {
                        upsertAssistantMessage(
                            template: ChatMessage(
                                id: assistantMessage.id,
                                role: .assistant,
                                content: fallbackContent,
                                timestamp: assistantMessage.timestamp,
                                agentId: fallbackAgent.id,
                                agentName: fallbackAgent.name
                            ),
                            content: fallbackContent
                        )
                        if let traceID {
                            completeExecutionTrace(traceID: traceID, summary: "这次请求已处理完成")
                        }
                        isProcessing = false
                    }
                    return
                } catch {
                    terminalError = error
                    logger.logError(error, context: "远端鉴权失败后回退到本地 Agent")

                    if UserFacingErrorFormatter.shouldTemporarilySuspendAgent(after: error) {
                        agentStore.markTemporarilyUnavailable(fallbackAgent)
                        continue
                    }
                    break
                }
            }

            // MARK: - 方案C：Planner驱动的异常处理决策
            // 先显示基础错误信息
            let baseUserFacingMessage = await recoveryGuidanceMessage(
                after: terminalError,
                failingAgent: terminalAgent,
                text: text,
                images: images
            ) ?? UserFacingErrorFormatter.chatMessage(
                for: terminalError,
                agentName: terminalAgent.displayName,
                providerName: terminalAgent.provider.displayName
            )

            if isKimiCLIAuthenticationFailure(terminalError, agent: terminalAgent) {
                await finalizeMainConversationFailure(
                    assistantMessage: assistantMessage,
                    traceID: traceID,
                    logSessionID: logSessionID,
                    agent: terminalAgent,
                    error: terminalError,
                    message: baseUserFacingMessage,
                    isRecoverable: false  // 认证失败不可自动恢复
                )
                return
            }
            
            // 如果是流中断，让Planner做智能决策
            var finalMessage = baseUserFacingMessage
            var shouldScheduleBackgroundRecovery = false
            
            // MARK: - 方案C：Planner驱动的异常处理决策
            // 对所有错误类型都进行Planner决策，并创建可恢复的任务会话
            let decision = await ExceptionHandlingPlanner.shared.planExceptionHandling(
                error: terminalError,
                sessionID: mainSession.mainSessionKey,
                originalRequest: text,
                partialResult: nil,
                recentUserInput: text,
                taskCharacteristics: TaskCharacteristics(
                    isLongRunning: text.count > 200 || text.contains("部署") || text.contains("配置"),
                    estimatedDuration: nil,
                    requiresUserInteraction: false,
                    hasSideEffects: text.contains("创建") || text.contains("删除") || text.contains("部署")
                )
            )
            
            LogInfo("[CommandRunner] Planner异常决策: \(decision.action), 理由: \(decision.reasoning)")
            
            // 根据决策执行不同策略
            switch decision.action {
            case .autoRecoverNow:
                // 立即恢复，修改消息提示
                finalMessage = baseUserFacingMessage + "\n\n🔄 正在自动尝试恢复..."
                
            case .scheduleBackgroundRecovery(let delay):
                // 安排后台恢复（方案A：兜底）
                shouldScheduleBackgroundRecovery = true
                finalMessage = baseUserFacingMessage + "\n\n⏱️ 已安排在\(delay)秒后自动检查恢复，你也可以点击「继续处理」立即恢复。"
                
            case .convertToBackgroundTask:
                // 转为后台任务
                shouldScheduleBackgroundRecovery = true
                finalMessage = baseUserFacingMessage + "\n\n🔄 这是一个可能需要较长时间的任务，已转为后台继续执行，完成后会通知你。"
                
            case .promptCheckStatus:
                // 提示检查状态（方案B：用户触发）
                finalMessage = baseUserFacingMessage + "\n\n💡 你可以发送「检查状态」查看任务当前进展。"
                
            case .waitForUserInput, .offerRecoveryOptions:
                // 等待用户输入，保持默认消息
                break
            }
            
            // 执行决策
            let scenario = ExceptionScenario(
                type: UserFacingErrorFormatter.isStreamInterruptedError(terminalError) ? .streamInterrupted : .agentFailure,
                sessionID: mainSession.mainSessionKey,
                originalRequest: text,
                partialResult: nil,
                error: terminalError,
                context: ExceptionScenario.ExceptionContext(
                    hasPartialResult: false,
                    isLongRunningTask: text.count > 200,
                    hasBackgroundRecoveryScheduled: shouldScheduleBackgroundRecovery,
                    userIntent: .unknown
                )
            )
            await ExceptionHandlingPlanner.shared.executeDecision(decision, scenario: scenario, runner: self)

            let recoveryTaskTitle = text.prefix(30).description + (text.count > 30 ? "..." : "")
            let recoveryErrorMessage = shouldScheduleBackgroundRecovery
                ? "已安排后台自动恢复，或点击「继续处理」立即重试"
                : "点击「继续处理」重试"
            let terminalAgentID = terminalAgent.id
            let terminalAgentName = terminalAgent.name
            let terminalErrorDescription = terminalError.localizedDescription
            let mainSessionKey = mainSession.mainSessionKey
            let statusSummary = finalMessage
            let taskStatus: TaskSessionStatus = shouldScheduleBackgroundRecovery ? .partial : .waitingUser
            
            // MARK: - 创建可恢复的任务会话
            // 对所有异常都创建任务卡片，让用户可以「继续处理」
            await MainActor.run {
                // 生成唯一的任务会话ID（使用时间戳避免冲突）
                let taskSessionID = "\(mainSessionKey)-\(Int(Date().timeIntervalSince1970))"
                
                // [迁移] 同时创建统一任务（新的统一任务系统）
                let unifiedTask = UnifiedTaskManager.shared.createExceptionRecoveryTask(
                    title: recoveryTaskTitle,
                    originalRequest: text,
                    errorMessage: recoveryErrorMessage,
                    gatewaySessionKey: mainSessionKey,
                    messages: [
                        TaskMessage(
                            id: UUID(),
                            role: .user,
                            content: text,
                            timestamp: Date(),
                            agentID: terminalAgentID,
                            agentName: terminalAgentName
                        ),
                        TaskMessage(
                            id: UUID(),
                            role: .system,
                            content: "请求处理中断: \(terminalErrorDescription)",
                            timestamp: Date(),
                            agentID: nil,
                            agentName: nil
                        )
                    ]
                )
                LogInfo("[CommandRunner] 创建统一异常恢复任务: \(unifiedTask.id)")
                
                // [兼容] 保留旧版AgentTaskSession供过渡期间使用
                let taskSession = AgentTaskSession(
                    id: taskSessionID,
                    title: recoveryTaskTitle,
                    originalRequest: text,
                    status: taskStatus,
                    statusSummary: statusSummary,
                    mainAgentName: terminalAgentName,
                    intentName: "异常恢复",
                    messages: [
                        TaskSessionMessage(
                            id: UUID(),
                            role: .user,
                            content: text,
                            timestamp: Date()
                        ),
                        TaskSessionMessage(
                            id: UUID(),
                            role: .system,
                            content: "请求处理中断: \(terminalErrorDescription)",
                            timestamp: Date()
                        )
                    ],
                    errorMessage: recoveryErrorMessage,
                    gatewaySessionKey: mainSessionKey,
                    canResume: true
                )
                self.taskSessions.append(taskSession)
                LogInfo("[CommandRunner] 创建异常恢复任务会话: \(taskSessionID)")
                LogInfo("[CommandRunner] 总任务数: \(self.taskSessions.count), 任务状态: \(taskSession.status)")
                
                // 强制触发 UI 更新
                self.objectWillChange.send()
            }
            
            await finalizeMainConversationFailure(
                assistantMessage: assistantMessage,
                traceID: traceID,
                logSessionID: logSessionID,
                agent: terminalAgent,
                error: terminalError,
                message: finalMessage,
                isRecoverable: true  // 已创建恢复任务，是可恢复的
            )
        }
    }

    private func finalizeMainConversationFailure(
        assistantMessage: ChatMessage,
        traceID: UUID?,
        logSessionID: String,
        agent: Agent,
        error: Error,
        message: String,
        isRecoverable: Bool = false
    ) async {
        await ExecutionLogger.shared.logError(
            sessionID: logSessionID,
            component: "CommandRunner",
            error: error,
            context: isRecoverable ? "请求处理中断（可恢复）" : "请求处理失败"
        )
        await ExecutionLogger.shared.endSession(
            id: logSessionID,
            status: isRecoverable ? .interrupted : .failed
        )

        await MainActor.run {
            if let traceID {
                if isRecoverable {
                    // 可恢复错误：Trace 标记为中断状态，而不是失败
                    updateExecutionTrace(
                        traceID: traceID,
                        state: .failed,
                        summary: "请求处理中断，已创建恢复任务"
                    )
                } else {
                    failExecutionTrace(traceID: traceID, summary: "这次请求处理失败")
                }
            }
            upsertAssistantMessage(
                template: ChatMessage(
                    id: assistantMessage.id,
                    role: .assistant,
                    content: message,
                    timestamp: assistantMessage.timestamp,
                    agentId: agent.id,
                    agentName: agent.name
                ),
                content: message
            )
            isProcessing = false
        }
    }

    private func prepareMemoryRecallPreludeIfNeeded(
        for text: String,
        sessionKey: String,
        traceID: UUID?
    ) async -> MemoryRecallPrelude? {
        let turns = await MainActor.run {
            self.messages.map {
                ConversationRecallTurn(role: $0.role.rawValue, content: $0.content)
            }
        }

        if let traceID, MemoryRecallCoordinator.isMemorySensitive(text) {
            await MainActor.run {
                self.updateExecutionTrace(
                    traceID: traceID,
                    state: .running,
                    summary: "正在调取相关记忆并准备本轮上下文"
                )
            }
        }

        guard let prelude = await memoryRecallCoordinator.recallPreludeIfNeeded(
            text: text,
            turns: turns
        ) else {
            return nil
        }

        do {
            try await runtimeAdapter.injectAssistantMessage(
                sessionKey: sessionKey,
                message: prelude.message,
                label: "Internal Recall"
            )
            LogInfo(
                "Injected memory recall prelude " +
                "sessionKey=\(sessionKey) hits=\(prelude.hitCount) forcedReindex=\(prelude.forcedReindex)"
            )
            return prelude
        } catch {
            LogWarning(
                "Failed to inject memory recall prelude " +
                "sessionKey=\(sessionKey) error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    private func fallbackAgentsForRecoverableFailure(
        after error: Error,
        failingAgent: Agent,
        images: [String]
    ) -> [Agent] {
        guard UserFacingErrorFormatter.shouldAttemptAutomaticAgentFallback(after: error) else {
            return []
        }

        let requiredCapability = recoveryCapability(for: images)
        return agentStore.fallbackCandidates(
            for: requiredCapability,
            excluding: [failingAgent.id],
            preferredCurrent: orchestrator.currentAgent
        )
    }

    private func recoveryCapability(for images: [String]) -> Capability {
        images.isEmpty ? .textChat : .vision
    }

    private func isKimiCLIAuthenticationFailure(_ error: Error, agent: Agent) -> Bool {
        agent.provider == .ollama && UserFacingErrorFormatter.isAuthenticationError(error)
    }

    private func maybeStartKimiCLILoginRecovery(after error: Error, for agent: Agent) async {
        guard isKimiCLIAuthenticationFailure(error, agent: agent) else {
            return
        }

        let alreadyWaiting = await MainActor.run { () -> Bool in
            isWaitingForKimiCLILogin && pendingKimiCLILoginAgentID == agent.id
        }
        guard !alreadyWaiting else { return }

        await MainActor.run {
            let launched = agentStore.launchKimiLogin()
            isWaitingForKimiCLILogin = true
            pendingKimiCLILoginAgentID = agent.id

            appendSystemMessage(
                launched
                ? """
                🌐 检测到 \(agent.displayName) 的 Kimi CLI 登录已失效。

                我已经在终端执行 `kimi login`。接下来通常会打开网页授权；你完成登录后回到应用，我会自动检测 Kimi CLI 是否已经恢复可用。
                """
                : """
                🌐 检测到 \(agent.displayName) 的 Kimi CLI 登录已失效。

                请在终端执行 `kimi login` 并完成网页授权。登录完成后回到应用，我会自动检测 Kimi CLI 是否已经恢复可用。
                """
            )
        }
    }

    private func recoveryGuidanceMessage(
        after error: Error,
        failingAgent: Agent,
        text: String,
        images: [String]
    ) async -> String? {
        guard UserFacingErrorFormatter.isAuthenticationError(error) ||
                UserFacingErrorFormatter.isMissingConfigurationError(error) else {
            return nil
        }

        if failingAgent.provider == .ollama {
            return """
            我刚刚尝试让 \(failingAgent.displayName) 调用 Kimi CLI，但检测到 CLI 登录已经失效，所以这次请求没有成功。

            我已经帮你拉起 `kimi login` 登录流程。通常完成网页授权后回到应用就行；如果没有自动弹出终端，也可以手动执行一次 `kimi login`。登录完成后，把刚才的问题再发一次，我会继续处理。
            """
        }

        let requiredCapability = recoveryCapability(for: images)
        guard preferredAgent(for: requiredCapability) == nil else {
            return nil
        }

        if requiredCapability == .vision {
            let gap = CapabilityGap(
                missingCapability: .vision,
                suggestedProviders: [.openai, .anthropic, .moonshot, .google],
                description: "需要一个支持图片分析的 Agent 才能继续处理这次请求",
                context: text
            )

            await MainActor.run {
                creationSkill.initiateCreation(for: gap, in: self)
            }

            return """
            ⚙️ 当前没有可用的视觉 Agent

            \(failingAgent.displayName) 已因鉴权失败被暂时停用。我已经打开配置引导；补一个支持图片分析的 Agent 后，就能继续处理这类请求。
            """
        }

        showInitialSetupGuidance(for: "继续对话")
        return """
        ⚙️ 当前没有可用的 LLM 或 CLI Agent

        \(failingAgent.displayName) 已因\(UserFacingErrorFormatter.isAuthenticationError(error) ? "认证失效" : "配置缺失")被暂时跳过。我已经打开配置向导；只要配置任意一个可用的 LLM 或 CLI Agent，就可以继续。
        """
    }

    private func gatewayReturnedError(_ content: String) -> NSError? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let lowercased = trimmed.lowercased()
        let hasProviderPayloadShape = lowercased.contains("\"error\"") ||
            lowercased.contains("'error'") ||
            lowercased.contains("invalid_api_key") ||
            lowercased.contains("invalid_authentication_error")
        let startsWithProviderPayload = lowercased.hasPrefix("{\"error\"") ||
            lowercased.hasPrefix("{'error'")

        guard lowercased.hasPrefix("error code:") ||
              (lowercased.hasPrefix("error:") && hasProviderPayloadShape) ||
              startsWithProviderPayload else {
            return nil
        }

        return NSError(
            domain: "CommandRunner.GatewayContent",
            code: gatewayReturnedErrorCode(from: trimmed) ?? 1,
            userInfo: [NSLocalizedDescriptionKey: trimmed]
        )
    }

    private func gatewayReturnedErrorCode(from content: String) -> Int? {
        guard let range = content.range(of: "Error code:", options: [.caseInsensitive]) else {
            return nil
        }

        let suffix = content[range.upperBound...]
        let digits = suffix
            .drop { !$0.isNumber }
            .prefix { $0.isNumber }

        return digits.isEmpty ? nil : Int(digits)
    }

    private func shouldAutoDelegateToSuggestedAgent(input: String, images: [String], suggestedAgent: Agent) -> Bool {
        suggestedAgent.supportsImageAnalysis && isImageAnalysisRequest(text: input, images: images)
    }

    private func isImageAnalysisRequest(text: String, images: [String]) -> Bool {
        if !images.isEmpty {
            return true
        }

        let normalized = text.lowercased()
        return ["图片", "图像", "截图", "看图", "分析图", "分析图片", "分析截图", "这张图"]
            .contains { normalized.contains($0) }
    }

    private func resolveImagesForRequest(text: String, explicitImages: [String]) -> [String] {
        if !explicitImages.isEmpty {
            return explicitImages
        }

        guard isImageAnalysisRequest(text: text, images: explicitImages) else {
            return []
        }

        if let recentImagePath = latestReusableImagePath() {
            return [recentImagePath]
        }

        return []
    }

    private func latestReusableImagePath() -> String? {
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

    private func preferredAgent(for capability: Capability) -> Agent? {
        let candidates = agentStore.autoRoutableAgentsSupporting(capability)

        if let current = orchestrator.currentAgent,
           current.supports(capability),
           agentStore.canUse(current) {
            return current
        }

        if let defaultAgent = agentStore.defaultAgent,
           defaultAgent.supports(capability) {
            return defaultAgent
        }

        return candidates.first
    }

    private func gatewaySessionKey(forTaskSessionID sessionID: String) -> String {
        conversationControl.currentTopology().taskSessionKey(for: sessionID)
    }

    private func gatewaySessionLabel(forTaskSessionID sessionID: String, baseLabel: String?, isResume: Bool = false) -> String? {
        guard let baseLabel = baseLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !baseLabel.isEmpty else {
            return nil
        }
        // 恢复任务时添加恢复标识，确保 label 唯一
        let effectiveBase = isResume ? "\(baseLabel) (恢复)" : baseLabel
        return "\(effectiveBase)-\(sessionID)"
    }

    private func directKimiCLIFallbackPolicy(after error: Error) -> DirectKimiCLIFallbackPolicy {
        if UserFacingErrorFormatter.isStreamInterruptedError(error) {
            return DirectKimiCLIFallbackPolicy(
                timeout: directKimiCLIInterruptedStreamFallbackTimeout,
                statusSummary: "主运行时长时间没有回传完整结果，已切换到直连 Kimi CLI 快速补结果",
                logReason: "stream_interrupted"
            )
        }

        if UserFacingErrorFormatter.isTransientServiceError(error) {
            return DirectKimiCLIFallbackPolicy(
                timeout: directKimiCLIFallbackTimeout,
                statusSummary: "主运行时当前不可用，已切换到直连 Kimi CLI",
                logReason: "transient_gateway_failure"
            )
        }

        return DirectKimiCLIFallbackPolicy(
            timeout: directKimiCLIFallbackTimeout,
            statusSummary: "OpenClaw 请求失败，已切换到直连 Kimi CLI",
            logReason: "gateway_failure"
        )
    }

    private func compactErrorDescription(_ error: Error, maxLength: Int = 220) -> String {
        let collapsed = (error as NSError).localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else {
            return collapsed
        }
        return String(collapsed.prefix(maxLength)) + "..."
    }

    private func sendViaGateway(
        agent: Agent,
        sessionKey: String,
        sessionLabel: String?,
        text: String,
        images: [String],
        taskSessionID: String? = nil,
        assistantMessageID: UUID,
        traceID: UUID? = nil
    ) async throws -> String {
        // MARK: - Memory Context Injection
        // 秘书的基本职责：记住上下文，在发送前增强提示词
        let (enhancedText, baseSystemPrompt) = await MainActor.run {
            prepareRequestWithMemory(
                text: text,
                sessionID: taskSessionID ?? sessionKey,
                systemPrompt: buildBaseSystemPrompt()
            )
        }
        
        // MARK: - Service Context Injection
        // 注入MacAssistant服务状态，让AI知道应用内部的服务情况
        let enhancedSystemPrompt = await MainActor.run {
            injectServiceContext(into: baseSystemPrompt)
        }
        
        // 更新 Trace：开始发送
        if let traceID = traceID {
            await MainActor.run {
                self.updateTraceStep(
                    traceID: traceID,
                    step: "建立连接",
                    details: "正在与 \(agent.displayName) 建立会话",
                    progress: 10,
                    log: "[→] 请求发送中..."
                )
            }
        }
        
        do {
            let content = try await runtimeAdapter.sendMessage(
                agent: agent,
                sessionKey: sessionKey,
                sessionLabel: sessionLabel,
                requestID: assistantMessageID.uuidString.lowercased(),
                text: enhancedText,  // 使用增强后的文本
                images: images,
                systemPrompt: enhancedSystemPrompt,  // Phase 4: 传递增强的系统提示词
                onAssistantText: { [weak self] partialText in
                    guard let self else { return }
                    guard self.gatewayReturnedError(partialText) == nil else { return }
                    
                    let textLength = partialText.count
                    
                    if let taskSessionID {
                        await MainActor.run {
                            self.updateTaskSessionMessage(
                                sessionID: taskSessionID,
                                messageID: assistantMessageID,
                                content: partialText
                            )
                            self.updateTaskSessionStatus(
                                sessionID: taskSessionID,
                                status: .running,
                                summary: "\(agent.displayName) 正在持续输出结果"
                            )
                        }
                    } else {
                        await MainActor.run {
                            self.updateAssistantMessage(id: assistantMessageID, content: partialText)
                        }
                    }
                    
                    // 更新 Trace：接收流式输出
                    if let traceID = traceID {
                        await MainActor.run {
                            let progress = min(10 + (textLength / 100), 90)
                            let displayText = partialText.suffix(100)
                            self.updateExecutionTrace(
                                traceID: traceID,
                                currentStep: "接收响应",
                                stepDetails: "已接收 \(textLength) 字符",
                                partialOutput: String(displayText),
                                progressPercent: progress,
                                addLog: (.info, "[←] 已接收 \(textLength) 字符")
                            )
                        }
                    }
                }
            )
            
            // 更新 Trace：完成
            if let traceID = traceID {
                await MainActor.run {
                    self.updateTraceStep(
                        traceID: traceID,
                        step: "完成",
                        details: "请求处理完成",
                        progress: 100,
                        log: "[✓] 请求完成"
                    )
                }
            }

            if let surfacedError = gatewayReturnedError(content) {
                throw surfacedError
            }

            let resolvedContent = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "服务已返回，但没有拿到可显示的内容。"
                : content

            await MainActor.run {
                if let taskSessionID {
                    self.updateTaskSessionMessage(
                        sessionID: taskSessionID,
                        messageID: assistantMessageID,
                        content: resolvedContent
                    )
                } else {
                    self.updateAssistantMessage(id: assistantMessageID, content: resolvedContent)
                }
            }
            
            // MARK: - 统一记忆索引（向量化存储，用于后续检索）
            let memorySessionKey = taskSessionID ?? sessionKey
            await MainActor.run {
                indexToUnifiedMemory(
                    sessionKey: memorySessionKey,
                    userMessage: text,
                    assistantResponse: resolvedContent
                )
                
                // 同时记录到旧记忆系统（向后兼容）
                recordConversationToMemory(
                    ChatMessage(
                        id: assistantMessageID,
                        role: .assistant,
                        content: resolvedContent,
                        timestamp: Date(),
                        agentId: agent.id,
                        agentName: agent.name
                    ),
                    sessionID: memorySessionKey
                )
            }

            return resolvedContent
        } catch {
            if let fallbackContent = try await fallbackToDirectKimiCLIIfNeeded(
                after: error,
                agent: agent,
                sessionKey: sessionKey,
                text: text,
                images: images,
                taskSessionID: taskSessionID,
                assistantMessageID: assistantMessageID,
                systemPrompt: enhancedSystemPrompt  // Phase 4: 传递增强的系统提示词
            ) {
                return fallbackContent
            }
            throw error
        }
    }

    private func fallbackToDirectKimiCLIIfNeeded(
        after error: Error,
        agent: Agent,
        sessionKey: String,
        text: String,
        images: [String],
        taskSessionID: String?,
        assistantMessageID: UUID,
        systemPrompt: String? = nil  // Phase 4: 支持记忆上下文注入
    ) async throws -> String? {
        guard shouldFallbackToDirectKimiCLI(after: error, agent: agent, sessionKey: sessionKey) else {
            return nil
        }

        let policy = directKimiCLIFallbackPolicy(after: error)
        let fallbackTarget = taskSessionID ?? "main"
        let upstreamError = compactErrorDescription(error)

        LogWarning(
            "Runtime fallback -> direct Kimi CLI start " +
            "agent=\(agent.id) sessionKey=\(sessionKey) target=\(fallbackTarget) " +
            "timeout=\(Int(policy.timeout))s reason=\(policy.logReason) upstreamError=\(upstreamError)"
        )

        await MainActor.run {
            if let taskSessionID {
                self.updateTaskSessionStatus(
                    sessionID: taskSessionID,
                    status: .running,
                    summary: policy.statusSummary
                )
            } else {
                if let traceID = self.currentExecutionTrace?.id {
                    self.updateExecutionTrace(
                        traceID: traceID,
                        state: .fallback,
                        agentName: agent.displayName,
                        transitionLabel: "直接 CLI",
                        summary: policy.statusSummary
                    )
                }
                self.updateAssistantMessage(
                    id: assistantMessageID,
                    content: "⏳ \(policy.statusSummary)..."
                )
            }
        }

        do {
            let content = try await localKimiCLIService.sendMessage(
                text: text,
                attachments: images,
                sessionKey: sessionKey,
                timeout: policy.timeout,
                requestSource: "runtime-fallback:\(policy.logReason)",
                systemPrompt: systemPrompt  // Phase 4: 传递系统提示词
            )
            let resolvedContent = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "本地 Kimi CLI 已执行，但没有返回可显示的内容。"
                : content

            LogInfo(
                "Runtime fallback -> direct Kimi CLI success " +
                "agent=\(agent.id) sessionKey=\(sessionKey) target=\(fallbackTarget) " +
                "timeout=\(Int(policy.timeout))s contentLength=\(resolvedContent.count)"
            )

            await MainActor.run {
                if let taskSessionID {
                    self.updateTaskSessionMessage(
                        sessionID: taskSessionID,
                        messageID: assistantMessageID,
                        content: resolvedContent
                    )
                } else {
                    self.updateAssistantMessage(id: assistantMessageID, content: resolvedContent)
                }
            }

            return resolvedContent
        } catch {
            LogError(
                "Runtime fallback -> direct Kimi CLI failed " +
                "agent=\(agent.id) sessionKey=\(sessionKey) target=\(fallbackTarget) " +
                "timeout=\(Int(policy.timeout))s reason=\(policy.logReason) upstreamError=\(upstreamError)",
                error: error
            )
            throw error
        }
    }

    private func shouldFallbackToDirectKimiCLI(
        after error: Error,
        agent: Agent,
        sessionKey: String
    ) -> Bool {
        guard agent.provider == .ollama else {
            return false
        }

        if UserFacingErrorFormatter.isAuthenticationError(error) {
            return false
        }

        if isClawManagedConversationSessionKey(sessionKey) {
            LogWarning(
                "Direct Kimi CLI fallback suppressed for Claw-managed conversation session " +
                "sessionKey=\(sessionKey)"
            )
            return false
        }

        let description = (error as NSError).localizedDescription.lowercased()
        let markers = [
            "openclaw",
            "gateway",
            "事件流意外结束",
            "stream ended unexpectedly",
            "recoverable assistant output",
            "bundlednotfound",
            "未打包在 app bundle 中",
            "未包含在应用中",
            "安装 openclaw 失败",
            "无法验证 openclaw",
            "启动超时"
        ]
        return markers.contains { description.contains($0) }
    }

    private func isClawManagedConversationSessionKey(_ sessionKey: String) -> Bool {
        let normalized = sessionKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.hasPrefix("conversation:") || normalized.contains(":conversation:")
    }

    private func delegateRequest(
        to agent: Agent,
        text: String,
        images: [String],
        intent: Intent,
        reason: String
    ) async {
        await MainActor.run {
            isProcessing = true
        }

        let mainAgent = await MainActor.run { orchestrator.currentAgent }
        let sessionID = await MainActor.run {
            createTaskSession(
                mainAgent: mainAgent,
                delegateAgent: agent,
                request: text,
                images: images,
                intent: intent,
                reason: reason
            )
        }

        let result = await runTaskSession(
            sessionID: sessionID,
            agent: agent,
            text: text,
            images: images
        )

        guard !result.failed else {
            await MainActor.run {
                isProcessing = false
            }
            return
        }

        await reflectTaskResultInMainConversation(
            taskSessionID: sessionID,
            originalUserRequest: text,
            mainAgent: mainAgent,
            delegateAgent: result.agent,
            taskResult: result.content
        )
    }

    func taskSession(for id: String?) -> AgentTaskSession? {
        guard let id else { return nil }
        return taskSessions.first { $0.id == id }
    }

    func toggleTaskSessionExpansion(_ id: String) {
        guard let index = taskSessions.firstIndex(where: { $0.id == id }) else { return }
        taskSessions[index].isExpanded.toggle()
        taskSessions[index].updatedAt = Date()
    }

    @MainActor
    func dismissTaskSessionFromTabs(_ id: String) {
        guard let index = taskSessions.firstIndex(where: { $0.id == id }) else { return }
        guard taskSessions[index].status == .completed else { return }
        guard taskSessions[index].dismissedAt == nil else { return }
        taskSessions[index].dismissedAt = Date()
        taskSessions[index].updatedAt = Date()
    }

    @MainActor
    func resumeTaskSession(_ id: String) {
        Task {
            await resumeTaskSessionIfPossible(id)
        }
    }

    @MainActor
    private func createTaskSession(
        mainAgent: Agent?,
        delegateAgent: Agent,
        request: String,
        images: [String],
        intent: Intent,
        reason: String
    ) -> String {
        var session = AgentTaskSession(
            title: "\(delegateAgent.name) 子会话",
            originalRequest: request,
            status: .queued,
            statusSummary: "等待 \(delegateAgent.displayName) 接手",
            mainAgentName: mainAgent?.name,
            delegateAgentID: delegateAgent.id,
            delegateAgentName: delegateAgent.name,
            intentName: intent.displayName,
            isExpanded: true,
            inputImages: images,
            canResume: false
        )
        session.gatewaySessionKey = gatewaySessionKey(forTaskSessionID: session.id)

        let taskCardMessage = ChatMessage(
            id: UUID(),
            role: .system,
            content: "🔀 \(reason)",
            timestamp: Date(),
            linkedTaskSessionID: session.id
        )
        session.linkedMainMessageID = taskCardMessage.id
        session.messages = [
            TaskSessionMessage(role: .system, content: reason),
            TaskSessionMessage(role: .user, content: request, agentName: mainAgent?.name)
        ]

        messages.append(taskCardMessage)
        taskSessions.append(session)
        return session.id
    }

    @MainActor
    private func updateTaskSessionMessage(
        sessionID: String,
        messageID: UUID,
        content: String
    ) {
        guard let sessionIndex = taskSessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = taskSessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        guard taskSessions[sessionIndex].messages[messageIndex].content != content else {
            return
        }

        var updatedSessions = taskSessions
        updatedSessions[sessionIndex].messages[messageIndex].content = content
        updatedSessions[sessionIndex].updatedAt = Date()
        if updatedSessions[sessionIndex].messages[messageIndex].role == .assistant {
            updatedSessions[sessionIndex].latestAssistantText = content
        }
        taskSessions = updatedSessions
    }

    @MainActor
    private func updateTaskSessionDelegateAgent(
        sessionID: String,
        agent: Agent
    ) {
        guard let index = taskSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        taskSessions[index].delegateAgentID = agent.id
        taskSessions[index].delegateAgentName = agent.name
        taskSessions[index].updatedAt = Date()
    }

    @MainActor
    private func updateTaskSessionRecoveryContext(
        sessionID: String,
        gatewaySessionKey: String? = nil,
        gatewayRunID: String? = nil,
        gatewayConversationSessionID: String? = nil,
        requestStartedAt: Date? = nil,
        latestAssistantText: String? = nil,
        canResume: Bool? = nil,
        lastReconciledAt: Date? = nil
    ) {
        guard let index = taskSessions.firstIndex(where: { $0.id == sessionID }) else { return }

        if let gatewaySessionKey {
            taskSessions[index].gatewaySessionKey = gatewaySessionKey
        }
        if let gatewayRunID {
            taskSessions[index].gatewayRunID = gatewayRunID
        }
        if let gatewayConversationSessionID {
            taskSessions[index].gatewayConversationSessionID = gatewayConversationSessionID
        }
        if let requestStartedAt {
            taskSessions[index].requestStartedAt = requestStartedAt
        }
        if let latestAssistantText {
            taskSessions[index].latestAssistantText = latestAssistantText
        }
        if let canResume {
            taskSessions[index].canResume = canResume
        }
        if let lastReconciledAt {
            taskSessions[index].lastReconciledAt = lastReconciledAt
        }
        taskSessions[index].updatedAt = Date()
    }

    @MainActor
    private func latestAssistantMessageID(forTaskSessionID sessionID: String) -> UUID? {
        guard let session = taskSessions.first(where: { $0.id == sessionID }) else { return nil }
        return session.messages.last(where: { $0.role == .assistant })?.id
    }

    private func summarizeTaskResult(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 220 else { return trimmed }
        let prefix = trimmed.prefix(220)
        return "\(prefix)…"
    }

    private func latestResumableTaskSessionID() -> String? {
        taskSessions
            .reversed()
            .first(where: { $0.canResume || $0.status == .partial || $0.status == .waitingUser })?
            .id
    }

    private func resumeTaskSessionIfPossible(_ sessionID: String) async {
        // 先尝试从运行时恢复已有结果
        let recovered = await reconcileTaskSession(sessionID, manualTrigger: true, allowRetry: true)
        guard !recovered else { return }
        
        // 如果无法恢复已有结果，尝试重新发送原始请求
        // 获取任务会话的原始请求
        let sessionSnapshot = await MainActor.run { taskSession(for: sessionID) }
        guard let session = sessionSnapshot,
              let originalRequest = session.messages.first(where: { $0.role == .user })?.content else {
            await MainActor.run {
                appendSystemMessage("无法找到原始请求，请重新输入。")
            }
            return
        }
        
        LogInfo("[CommandRunner] 重新尝试请求: session=\(sessionID)")
        
        // 更新任务会话状态为运行中
        await MainActor.run {
            if let index = taskSessions.firstIndex(where: { $0.id == sessionID }) {
                taskSessions[index].status = .running
                taskSessions[index].statusSummary = "正在重新处理..."
                taskSessions[index].updatedAt = Date()
            }
        }
        
        // 重新发送请求
        await processInput(originalRequest, images: [])
        
        // 更新任务会话状态
        await MainActor.run {
            if let index = taskSessions.firstIndex(where: { $0.id == sessionID }) {
                taskSessions[index].status = .completed
                taskSessions[index].statusSummary = "已重新处理完成"
                taskSessions[index].canResume = false
                taskSessions[index].updatedAt = Date()
            }
        }
    }

    private func reconcileInterruptedTaskSessions(trigger: String) async {
        let candidateIDs = await MainActor.run { () -> [String] in
            taskSessions
                .filter {
                    ($0.canResume || $0.status == .running || $0.status == .partial || $0.status == .waitingUser) &&
                    $0.gatewaySessionKey != nil &&
                    $0.requestStartedAt != nil
                }
                .sorted { $0.updatedAt < $1.updatedAt }
                .map(\.id)
        }

        for sessionID in candidateIDs {
            _ = await reconcileTaskSession(sessionID, manualTrigger: false, allowRetry: false)
        }

        if !candidateIDs.isEmpty {
            LogInfo("已完成中断任务回查，trigger=\(trigger)，任务数=\(candidateIDs.count)")
        }
    }
    
    // MARK: - Unified Task Recovery
    
    /// 处理统一任务管理器的恢复请求
    private func handleUnifiedTaskRecovery(
        taskID: String,
        gatewaySessionKey: String,
        originalRequest: String
    ) async {
        LogInfo("[CommandRunner] 处理统一任务恢复请求: taskID=\(taskID), sessionKey=\(gatewaySessionKey)")

        // 尝试恢复任务会话
        // 1. 先查找是否有对应的 AgentTaskSession
        let existingSessionID = await MainActor.run {
            taskSessions.first { $0.gatewaySessionKey == gatewaySessionKey }?.id
        }

        let success: Bool
        let resultContent: String

        if let sessionID = existingSessionID {
            // 使用现有的恢复逻辑
            await resumeTaskSessionIfPossible(sessionID)
            success = true
            resultContent = "任务会话已恢复"
        } else {
            // 直接重新发送请求
            await MainActor.run {
                self.isProcessing = true
            }

            // 重新处理原始请求
            await processInput(originalRequest, images: [])

            await MainActor.run {
                self.isProcessing = false
            }
            success = true
            resultContent = "请求已重新处理"
        }

        // 发送恢复完成通知
        await MainActor.run {
            NotificationCenter.default.post(
                name: .taskRecoveryCompleted,
                object: nil,
                userInfo: [
                    "taskID": taskID,
                    "success": success,
                    "content": resultContent
                ]
            )
        }
    }

    private func reconcileTaskSession(
        _ sessionID: String,
        manualTrigger: Bool,
        allowRetry: Bool
    ) async -> Bool {
        let snapshot = await MainActor.run { taskSession(for: sessionID) }
        guard let snapshot,
              let sessionKey = snapshot.gatewaySessionKey,
              let requestStartedAt = snapshot.requestStartedAt else {
            return false
        }

        if let recovery = await runtimeAdapter.recoverInterruptedTaskOutput(
            sessionKey: sessionKey,
            requestStartedAt: requestStartedAt,
            latestAssistantText: snapshot.latestAssistantText ?? ""
        ) {
            let summary = recovery.source == .history
                ? "已通过本地账本回查恢复结果"
                : "已恢复最近输出，但还没拿到完整收尾"

            await MainActor.run {
                if let assistantMessageID = latestAssistantMessageID(forTaskSessionID: sessionID) {
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: recovery.text
                    )
                }

                updateTaskSessionRecoveryContext(
                    sessionID: sessionID,
                    gatewayConversationSessionID: recovery.sessionID,
                    latestAssistantText: recovery.text,
                    canResume: recovery.source == .buffer,
                    lastReconciledAt: Date()
                )

                if recovery.source == .history {
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .completed,
                        summary: summary,
                        isExpanded: manualTrigger,
                        resultSummary: summarizeTaskResult(recovery.text),
                        errorMessage: nil
                    )
                } else {
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .partial,
                        summary: summary,
                        isExpanded: true,
                        errorMessage: snapshot.errorMessage
                    )
                }

                if manualTrigger {
                    let notice = recovery.source == .history
                        ? "我已经回查到刚才中断任务的结果：\n\n\(recovery.text)"
                        : "我已经恢复到刚才中断任务的最近输出，完整收尾还没回来。你可以继续观察任务卡片，或者再点一次继续处理。"
                    appendAssistantConversationMessage(notice)
                }
            }
            return true
        }

        guard manualTrigger,
              allowRetry,
              snapshot.canResume,
              let delegateAgentID = snapshot.delegateAgentID,
              let agent = agentStore.agent(withId: delegateAgentID),
              agentStore.canUse(agent) else {
            await MainActor.run {
                updateTaskSessionRecoveryContext(
                    sessionID: sessionID,
                    lastReconciledAt: Date()
                )
            }
            return false
        }

        let assistantMessageID = await MainActor.run { () -> UUID in
            if let existingID = latestAssistantMessageID(forTaskSessionID: sessionID) {
                return existingID
            }
            return appendTaskSessionMessage(
                sessionID: sessionID,
                role: .assistant,
                content: "⏳ \(agent.name) 正在继续处理...",
                agentName: agent.name
            )
        }

        await MainActor.run {
            isProcessing = true
            updateTaskSessionDelegateAgent(sessionID: sessionID, agent: agent)
            updateTaskSessionStatus(
                sessionID: sessionID,
                status: .running,
                summary: "正在继续处理上次中断的任务",
                isExpanded: true,
                errorMessage: nil
            )
            updateTaskSessionRecoveryContext(
                sessionID: sessionID,
                requestStartedAt: Date(),
                canResume: false
            )
            
            // 同步到主会话：任务恢复开始
            upsertConversationProgressMessage(
                key: "task_resume_\(sessionID)",
                content: "**\(agent.name)** 正在继续处理「\(snapshot.title)」...",
                agentID: agent.id,
                agentName: agent.name,
                metadata: [
                    "message_key": "task_resume_\(sessionID)",
                    "is_progress_update": "true",
                    "progress_source": "task_resume",
                    "task_session_id": sessionID,
                    "resume_phase": "started"
                ]
            )
        }

        do {
            let continuedContent = try await sendViaGateway(
                agent: agent,
                sessionKey: sessionKey,
                sessionLabel: gatewaySessionLabel(forTaskSessionID: sessionID, baseLabel: snapshot.title, isResume: true),
                text: snapshot.originalRequest,
                images: snapshot.inputImages ?? [],
                taskSessionID: sessionID,
                assistantMessageID: assistantMessageID
            )

            await MainActor.run {
                updateTaskSessionStatus(
                    sessionID: sessionID,
                    status: .completed,
                    summary: "\(agent.displayName) 已继续完成刚才的任务",
                    isExpanded: false,
                    resultSummary: summarizeTaskResult(continuedContent),
                    errorMessage: nil
                )
                updateTaskSessionRecoveryContext(
                    sessionID: sessionID,
                    latestAssistantText: continuedContent,
                    canResume: false,
                    lastReconciledAt: Date()
                )
                appendAssistantConversationMessage("我已经继续完成了刚才中断的任务：\n\n\(continuedContent)")
                
                // 同步到主会话：任务恢复完成
                upsertConversationProgressMessage(
                    key: "task_resume_\(sessionID)",
                    content: "**\(agent.displayName)** 已完成「\(snapshot.title)」。",
                    agentID: agent.id,
                    agentName: agent.name,
                    metadata: [
                        "message_key": "task_resume_\(sessionID)",
                        "is_progress_update": "true",
                        "progress_source": "task_resume",
                        "task_session_id": sessionID,
                        "resume_phase": "completed"
                    ]
                )
                
                isProcessing = false
            }
            return true
        } catch {
            // MARK: - Smart Recovery for Manual Resume
            LogInfo("CommandRunner: 手动恢复失败，尝试智能恢复 taskSessionID=\(sessionID)")
            
            let recoveryResult = await SmartRecoveryExecutor.shared.smartRecover(
                taskSessionID: sessionID,
                agent: agent,
                text: snapshot.originalRequest,
                images: snapshot.inputImages ?? [],
                error: error,
                previousSnapshot: nil
            ) { [weak self] message in
                Task { @MainActor in
                    self?.updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: message
                    )
                }
            }
            
            switch recoveryResult {
            case .success(let content):
                await MainActor.run {
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .completed,
                        summary: "\(agent.displayName) 通过智能恢复完成",
                        isExpanded: false,
                        resultSummary: summarizeTaskResult(content),
                        errorMessage: nil
                    )
                    updateTaskSessionRecoveryContext(
                        sessionID: sessionID,
                        latestAssistantText: content,
                        canResume: false,
                        lastReconciledAt: Date()
                    )
                    
                    // 同步到主会话：智能恢复完成
                    upsertConversationProgressMessage(
                        key: "task_resume_\(sessionID)",
                        content: "**\(agent.displayName)** 已通过智能恢复完成「\(snapshot.title)」。",
                        agentID: agent.id,
                        agentName: agent.name,
                        metadata: [
                            "message_key": "task_resume_\(sessionID)",
                            "is_progress_update": "true",
                            "progress_source": "task_resume",
                            "task_session_id": sessionID,
                            "resume_phase": "smart_recovered"
                        ]
                    )
                    appendAssistantConversationMessage("我已经通过智能恢复完成了任务：\n\n\(content)")
                    isProcessing = false
                }
                return true
                
            case .partial(let content, let plan):
                await MainActor.run {
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .partial,
                        summary: "智能恢复部分完成，需要继续处理",
                        isExpanded: true,
                        errorMessage: content
                    )
                    updateTaskSessionRecoveryContext(
                        sessionID: sessionID,
                        latestAssistantText: content,
                        canResume: true,
                        lastReconciledAt: Date()
                    )
                    isProcessing = false
                }
                return false
                
            case .needsConfirmation(_):
                await MainActor.run {
                    let confirmationMessage = """
                    🤖 智能分析完成
                    
                    问题: 执行中断或超时
                    建议: 自动调整超时设置、尝试备用 Agent 或拆分任务
                    
                    请再次点击「继续处理」确认执行调优方案。
                    """
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: confirmationMessage
                    )
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .waitingUser,
                        summary: "等待确认调优方案",
                        isExpanded: true,
                        errorMessage: confirmationMessage
                    )
                    isProcessing = false
                }
                return false
                
            case .failed, .inProgress:
                // 使用原有错误处理
                let message = UserFacingErrorFormatter.chatMessage(
                    for: error,
                    agentName: agent.displayName,
                    providerName: agent.provider.displayName
                )
                await MainActor.run {
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: UserFacingErrorFormatter.isStreamInterruptedError(error) ? .partial : .failed,
                        summary: UserFacingErrorFormatter.isStreamInterruptedError(error)
                            ? "继续处理中再次中断，已保留现场"
                            : "\(agent.displayName) 继续处理失败",
                        isExpanded: true,
                        errorMessage: message
                    )
                    updateTaskSessionRecoveryContext(
                        sessionID: sessionID,
                        canResume: UserFacingErrorFormatter.isStreamInterruptedError(error),
                        lastReconciledAt: Date()
                    )
                    if let latestAssistantText = snapshot.latestAssistantText,
                       UserFacingErrorFormatter.isStreamInterruptedError(error),
                       let assistantMessageID = latestAssistantMessageID(forTaskSessionID: sessionID) {
                        updateTaskSessionMessage(
                            sessionID: sessionID,
                            messageID: assistantMessageID,
                            content: latestAssistantText
                        )
                    }
                    appendSystemMessage(message)
                    isProcessing = false
                }
                return false
            }
        }
    }

    private func runTaskSession(
        sessionID: String,
        agent: Agent,
        text: String,
        images: [String]
    ) async -> TaskExecutionResult {
        let sessionKey = gatewaySessionKey(forTaskSessionID: sessionID)
        let requestStartedAt = Date()
        await MainActor.run {
            updateTaskSessionStatus(
                sessionID: sessionID,
                status: .running,
                summary: "\(agent.displayName) 正在处理这个任务",
                isExpanded: true
            )
            updateTaskSessionDelegateAgent(sessionID: sessionID, agent: agent)
            updateTaskSessionRecoveryContext(
                sessionID: sessionID,
                gatewaySessionKey: sessionKey,
                requestStartedAt: requestStartedAt,
                canResume: false
            )
        }

        let assistantMessageID = await MainActor.run {
            appendTaskSessionMessage(
                sessionID: sessionID,
                role: .assistant,
                content: "⏳ \(agent.name) 正在处理...",
                agentName: agent.name
            )
        }

        do {
            let content = try await sendViaGateway(
                agent: agent,
                sessionKey: sessionKey,
                sessionLabel: gatewaySessionLabel(
                    forTaskSessionID: sessionID,
                    baseLabel: taskSession(for: sessionID)?.title
                ),
                text: text,
                images: images,
                taskSessionID: sessionID,
                assistantMessageID: assistantMessageID
            )

            await MainActor.run {
                updateTaskSessionStatus(
                    sessionID: sessionID,
                    status: .completed,
                    summary: "\(agent.displayName) 已完成，结果已回流到主会话",
                    isExpanded: false,
                    resultSummary: summarizeTaskResult(content),
                    errorMessage: nil
                )
                updateTaskSessionRecoveryContext(
                    sessionID: sessionID,
                    latestAssistantText: content,
                    canResume: false,
                    lastReconciledAt: Date()
                )
            }

            return TaskExecutionResult(agent: agent, content: content, failed: false)
        } catch {
            logger.logError(error, context: "执行 Agent 子会话")

            var terminalError = error
            var terminalAgent = agent

            await maybeStartKimiCLILoginRecovery(after: error, for: agent)

            if UserFacingErrorFormatter.shouldTemporarilySuspendAgent(after: error) {
                agentStore.markTemporarilyUnavailable(agent)
            }

            for fallbackAgent in fallbackAgentsForRecoverableFailure(
                after: error,
                failingAgent: agent,
                images: images
            ) {
                logger.logAgentSwitch(
                    from: agent,
                    to: fallbackAgent,
                    reason: "子会话 \(UserFacingErrorFormatter.recoveryFailureSummary(for: error))后自动切换"
                )
                orchestrator.switchToAgent(fallbackAgent)

                await MainActor.run {
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .running,
                        summary: "\(agent.displayName) \(UserFacingErrorFormatter.recoveryFailureSummary(for: error))，已切换到 \(fallbackAgent.displayName)",
                        isExpanded: true
                    )
                    updateTaskSessionDelegateAgent(sessionID: sessionID, agent: fallbackAgent)
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: "⏳ \(fallbackAgent.name) 正在继续处理..."
                    )
                }

                do {
                    terminalAgent = fallbackAgent
                    let fallbackContent = try await sendViaGateway(
                        agent: fallbackAgent,
                        sessionKey: sessionKey,
                        sessionLabel: gatewaySessionLabel(
                            forTaskSessionID: sessionID,
                            baseLabel: taskSession(for: sessionID)?.title
                        ),
                        text: text,
                        images: images,
                        taskSessionID: sessionID,
                        assistantMessageID: assistantMessageID
                    )

                    await MainActor.run {
                        updateTaskSessionStatus(
                            sessionID: sessionID,
                            status: .completed,
                            summary: "\(fallbackAgent.displayName) 已完成，结果已回流到主会话",
                            isExpanded: false,
                            resultSummary: summarizeTaskResult(fallbackContent),
                            errorMessage: nil
                        )
                        updateTaskSessionRecoveryContext(
                            sessionID: sessionID,
                            latestAssistantText: fallbackContent,
                            canResume: false,
                            lastReconciledAt: Date()
                        )
                    }

                    return TaskExecutionResult(agent: fallbackAgent, content: fallbackContent, failed: false)
                } catch {
                    terminalError = error
                    logger.logError(error, context: "子会话回退 Agent 失败")

                    if UserFacingErrorFormatter.shouldTemporarilySuspendAgent(after: error) {
                        agentStore.markTemporarilyUnavailable(fallbackAgent)
                        continue
                    }
                    break
                }
            }

            let userFacingMessage = await recoveryGuidanceMessage(
                after: terminalError,
                failingAgent: terminalAgent,
                text: text,
                images: images
            ) ?? UserFacingErrorFormatter.chatMessage(
                for: terminalError,
                agentName: terminalAgent.displayName,
                providerName: terminalAgent.provider.displayName
            )
            let terminalAgentName = terminalAgent.displayName
            let isStreamInterrupted = UserFacingErrorFormatter.isStreamInterruptedError(terminalError)
            let isKimiLoginFailure = isKimiCLIAuthenticationFailure(terminalError, agent: terminalAgent)
            let initialStreamingPlaceholder = "⏳ \(terminalAgent.name) 正在处理..."
            let preservedAssistantText = await MainActor.run {
                taskSession(for: sessionID)?.latestAssistantText?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // MARK: - Smart Recovery Integration
            // 尝试智能自动恢复
            let shouldAttemptAutoRecovery = isStreamInterrupted || 
                UserFacingErrorFormatter.isTransientServiceError(terminalError)
            
            if shouldAttemptAutoRecovery {
                LogInfo("CommandRunner: 尝试智能恢复 taskSessionID=\(sessionID)")
                
                // 构建执行快照
                let snapshot = ExecutionSnapshot(
                    timestamp: Date(),
                    taskSessionID: sessionID,
                    agentID: UUID(uuidString: sessionID) ?? UUID(),
                    status: "failed",
                    progress: 0.5,
                    duration: -requestStartedAt.timeIntervalSinceNow,
                    retryCount: 0,
                    lastError: terminalError.localizedDescription,
                    partialResult: preservedAssistantText,
                    configSnapshot: [
                        "timeout": "120",
                        "agentProvider": terminalAgent.provider.rawValue
                    ]
                )
                
                // 调用智能恢复执行器
                let recoveryResult = await SmartRecoveryExecutor.shared.smartRecover(
                    taskSessionID: sessionID,
                    agent: terminalAgent,
                    text: text,
                    images: images,
                    error: terminalError,
                    previousSnapshot: snapshot
                ) { [weak self] message in
                    Task { @MainActor in
                        self?.updateTaskSessionMessage(
                            sessionID: sessionID,
                            messageID: assistantMessageID,
                            content: message
                        )
                    }
                }
                
                // 处理恢复结果
                switch recoveryResult {
                case .success(let content):
                    // 恢复成功
                    await MainActor.run {
                        self.updateTaskSessionMessage(
                            sessionID: sessionID,
                            messageID: assistantMessageID,
                            content: content
                        )
                        self.updateTaskSessionStatus(
                            sessionID: sessionID,
                            status: .completed,
                            summary: "\(terminalAgentName) 通过智能恢复完成",
                            isExpanded: false,
                            resultSummary: self.summarizeTaskResult(content),
                            errorMessage: nil
                        )
                        self.updateTaskSessionRecoveryContext(
                            sessionID: sessionID,
                            latestAssistantText: content,
                            canResume: false,
                            lastReconciledAt: Date()
                        )
                    }
                    return TaskExecutionResult(agent: terminalAgent, content: content, failed: false)
                    
                case .partial(let content, _):
                    // 部分恢复，需要继续
                    await MainActor.run {
                        self.updateTaskSessionMessage(
                            sessionID: sessionID,
                            messageID: assistantMessageID,
                            content: content
                        )
                        self.updateTaskSessionStatus(
                            sessionID: sessionID,
                            status: .partial,
                            summary: "智能恢复部分完成，需要继续处理",
                            isExpanded: true,
                            errorMessage: content
                        )
                        self.updateTaskSessionRecoveryContext(
                            sessionID: sessionID,
                            latestAssistantText: content,
                            canResume: true,
                            lastReconciledAt: Date()
                        )
                    }
                    return TaskExecutionResult(agent: terminalAgent, content: content, failed: true)
                    
                case .needsConfirmation(_):
                    // 需要用户确认
                    await MainActor.run {
                        let confirmationMessage = """
                        🤖 智能分析完成
                        
                        问题: 执行中断或超时
                        
                        建议调优方案：
                        自动调整超时设置、尝试备用 Agent 或拆分任务
                        
                        请点击任务卡片中的「继续处理」确认执行调优方案。
                        """
                        self.updateTaskSessionMessage(
                            sessionID: sessionID,
                            messageID: assistantMessageID,
                            content: confirmationMessage
                        )
                        self.updateTaskSessionStatus(
                            sessionID: sessionID,
                            status: .waitingUser,
                            summary: "等待确认调优方案",
                            isExpanded: true,
                            errorMessage: confirmationMessage
                        )
                        self.updateTaskSessionRecoveryContext(
                            sessionID: sessionID,
                            latestAssistantText: "等待用户确认调优方案",
                            canResume: true,
                            lastReconciledAt: Date()
                        )
                    }
                    return TaskExecutionResult(agent: terminalAgent, content: userFacingMessage, failed: true)
                    
                case .failed(let errorMessage):
                    // 恢复失败，显示原错误
                    LogWarning("Smart recovery failed: \(errorMessage)")
                    // 继续执行原有错误处理逻辑
                    fallthrough
                    
                case .inProgress:
                    // 恢复进行中
                    return TaskExecutionResult(agent: terminalAgent, content: "恢复中...", failed: true)
                }
            }
            
            await MainActor.run {
                if isStreamInterrupted {
                    let shouldPreservePartialOutput =
                        !(preservedAssistantText ?? "").isEmpty &&
                        preservedAssistantText != initialStreamingPlaceholder
                    if !shouldPreservePartialOutput {
                        updateTaskSessionMessage(
                            sessionID: sessionID,
                            messageID: assistantMessageID,
                            content: userFacingMessage
                        )
                    }
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .partial,
                        summary: "结果回传中断，已保留现场并等待回查",
                        isExpanded: true,
                        errorMessage: userFacingMessage
                    )
                    updateTaskSessionRecoveryContext(
                        sessionID: sessionID,
                        latestAssistantText: shouldPreservePartialOutput ? preservedAssistantText : userFacingMessage,
                        canResume: true
                    )
                } else if isKimiLoginFailure {
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: userFacingMessage
                    )
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .waitingUser,
                        summary: "等待完成 Kimi CLI 登录后继续",
                        isExpanded: true,
                        errorMessage: userFacingMessage
                    )
                    updateTaskSessionRecoveryContext(
                        sessionID: sessionID,
                        canResume: true
                    )
                } else {
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: userFacingMessage
                    )
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .failed,
                        summary: "\(terminalAgentName) 执行失败",
                        isExpanded: true,
                        errorMessage: userFacingMessage
                    )
                    updateTaskSessionRecoveryContext(
                        sessionID: sessionID,
                        canResume: false
                    )
                }
            }

            return TaskExecutionResult(agent: terminalAgent, content: userFacingMessage, failed: true)
        }
    }

    private func reflectTaskResultInMainConversation(
        taskSessionID: String,
        originalUserRequest: String,
        mainAgent: Agent?,
        delegateAgent: Agent,
        taskResult: String
    ) async {
        let traceAnchorMessageID = await MainActor.run {
            taskSession(for: taskSessionID)?.linkedMainMessageID
        }

        let reflectionAgent = await MainActor.run { () -> Agent? in
            if let mainAgent, agentStore.canUse(mainAgent) {
                return mainAgent
            }
            return preferredAgent(for: .textChat)
        }

        let traceID = await MainActor.run { () -> UUID? in
            if let traceAnchorMessageID {
                return startExecutionTrace(
                    anchorMessageID: traceAnchorMessageID,
                    agentName: reflectionAgent?.displayName ?? delegateAgent.displayName,
                    intentName: "结果整合",
                    summary: "主会话正在整合 \(delegateAgent.displayName) 的执行结果",
                    state: .synthesizing,
                    transitionLabel: "子会话回流"
                )
            }
            return nil
        }

        guard let reflectionAgent else {
            await MainActor.run {
                if let traceID {
                    completeExecutionTrace(traceID: traceID, summary: "已直接回流子会话结果")
                }
                let fallbackMessage = ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: summarizeTaskResult(taskResult),
                    timestamp: Date()
                )
                messages.append(fallbackMessage)
                isProcessing = false
            }
            return
        }

        let reflectionPrompt = """
        你现在是主会话 AI，需要根据一个子会话的执行结果，直接给用户最终答复。

        用户原始请求：
        \(originalUserRequest)

        子会话执行 Agent：
        \(delegateAgent.displayName)

        子会话结果：
        \(taskResult)

        请直接面向用户作答：
        1. 不要提内部委托、子会话、路由机制。
        2. 用自然语言整合子会话结果，给出结论或下一步建议。
        3. 如果信息不足，明确说明还缺什么。
        """

        _ = await sendToRuntime(agent: reflectionAgent, text: reflectionPrompt, images: [], traceID: traceID)
    }

    private func streamLocalBridgeForTask(
        sessionID: String,
        agent: Agent,
        text: String,
        images: [String],
        assistantMessageID: UUID
    ) async throws -> String {
        var requestBody: [String: Any] = [
            "model": "\(agent.provider.rawValue)/\(agent.model)",
            "messages": [
                ["role": "user", "content": text]
            ],
            "stream": true
        ]

        if !images.isEmpty && agent.supportsImageAnalysis {
            requestBody["images"] = images
        }

        let url = URL(string: "http://localhost:11434/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (stream, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "CommandRunner",
                code: 15,
                userInfo: [NSLocalizedDescriptionKey: "本地运行时请求失败"]
            )
        }

        var fullContent = ""
        var lastUpdateTime = Date()
        var hasReceivedContent = false

        for try await line in stream.lines {
            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {

                fullContent += content
                hasReceivedContent = true
                let contentSnapshot = fullContent
                await MainActor.run {
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: contentSnapshot
                    )
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .running,
                        summary: "\(agent.displayName) 正在持续输出结果"
                    )
                }
                lastUpdateTime = Date()
            }

            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let done = json["done"] as? Bool, done {
                break
            }

            if !hasReceivedContent && Date().timeIntervalSince(lastUpdateTime) > 3 {
                await MainActor.run {
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: "⏳ \(agent.name) 正在连接..."
                    )
                }
                lastUpdateTime = Date()
            }
        }

        if fullContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallback = "服务已返回，但没有拿到可显示的内容。"
            await MainActor.run {
                updateTaskSessionMessage(
                    sessionID: sessionID,
                    messageID: assistantMessageID,
                    content: fallback
                )
            }
            return fallback
        }

        return fullContent
    }

    private func sendToConfiguredProviderForTask(
        sessionID: String,
        agent: Agent,
        text: String,
        images: [String],
        assistantMessageID: UUID
    ) async throws -> String {
        guard let profile = agentStore.runtimeProfile(for: agent) else {
            throw NSError(
                domain: "CommandRunner",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: "\(agent.displayName) 缺少认证配置，请重新配置该 Agent。"]
            )
        }

        let responseText: String
        switch agent.provider {
        case .deepseek, .doubao, .zhipu, .openai, .moonshot, .minimax:
            responseText = try await callOpenAICompatibleProvider(
                agent: agent,
                text: text,
                images: images,
                profile: profile
            )
        case .anthropic:
            responseText = try await callAnthropicProvider(
                agent: agent,
                text: text,
                images: images,
                profile: profile
            )
        case .google:
            responseText = try await callGoogleProvider(
                agent: agent,
                text: text,
                images: images,
                profile: profile
            )
        case .ollama:
            throw NSError(
                domain: "CommandRunner",
                code: 17,
                userInfo: [NSLocalizedDescriptionKey: "本地 Agent 应该走本地运行时，不应走远端 provider 分支。"]
            )
        }

        let finalText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = finalText.isEmpty ? "服务已返回，但没有拿到可显示的内容。" : finalText
        await MainActor.run {
            updateTaskSessionMessage(
                sessionID: sessionID,
                messageID: assistantMessageID,
                content: content
            )
        }
        return content
    }

    private func streamLocalBridge(
        agent: Agent,
        text: String,
        images: [String],
        assistantMessageID: UUID
    ) async throws -> String {
        var requestBody: [String: Any] = [
            "model": "\(agent.provider.rawValue)/\(agent.model)",
            "messages": [
                ["role": "user", "content": text]
            ],
            "stream": true
        ]

        if !images.isEmpty && agent.supportsImageAnalysis {
            requestBody["images"] = images
        }

        let url = URL(string: "http://localhost:11434/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (stream, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "CommandRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "本地运行时请求失败"]
            )
        }

        var fullContent = ""
        var lastUpdateTime = Date()
        var hasReceivedContent = false

        for try await line in stream.lines {
            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {

                fullContent += content
                hasReceivedContent = true
                await updateAssistantMessage(id: assistantMessageID, content: fullContent)
                lastUpdateTime = Date()
            }

            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let done = json["done"] as? Bool, done {
                break
            }

            if !hasReceivedContent && Date().timeIntervalSince(lastUpdateTime) > 3 {
                await updateAssistantMessage(id: assistantMessageID, content: "⏳ \(agent.name) 正在连接...")
                lastUpdateTime = Date()
            }
        }

        if fullContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallback = "服务已返回，但没有拿到可显示的内容。"
            await updateAssistantMessage(id: assistantMessageID, content: fallback)
            return fallback
        }

        return fullContent
    }

    private func sendToConfiguredProvider(
        agent: Agent,
        text: String,
        images: [String],
        assistantMessageID: UUID
    ) async throws -> String {
        guard let profile = agentStore.runtimeProfile(for: agent) else {
            throw NSError(
                domain: "CommandRunner",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(agent.displayName) 缺少认证配置，请重新配置该 Agent。"]
            )
        }

        let responseText: String
        switch agent.provider {
        case .deepseek, .doubao, .zhipu, .openai, .moonshot, .minimax:
            responseText = try await callOpenAICompatibleProvider(
                agent: agent,
                text: text,
                images: images,
                profile: profile
            )
        case .anthropic:
            responseText = try await callAnthropicProvider(
                agent: agent,
                text: text,
                images: images,
                profile: profile
            )
        case .google:
            responseText = try await callGoogleProvider(
                agent: agent,
                text: text,
                images: images,
                profile: profile
            )
        case .ollama:
            throw NSError(
                domain: "CommandRunner",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "本地 Agent 应该走本地运行时，不应走远端 provider 分支。"]
            )
        }

        let finalText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = finalText.isEmpty ? "服务已返回，但没有拿到可显示的内容。" : finalText
        await updateAssistantMessage(id: assistantMessageID, content: content)
        return content
    }

    private func callOpenAICompatibleProvider(
        agent: Agent,
        text: String,
        images: [String],
        profile: AgentStore.RuntimeProfile
    ) async throws -> String {
        guard !profile.apiKey.isEmpty else {
            throw NSError(
                domain: "CommandRunner",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "\(agent.provider.displayName) API Key 为空，请重新配置。"]
            )
        }

        let endpoint = URL(string: "\(normalizedBaseURL(profile.baseURL))/chat/completions")!
        let messageContent = try buildOpenAICompatibleContent(text: text, images: images)
        var body: [String: Any] = [
            "model": profile.model,
            "messages": [
                ["role": "user", "content": messageContent]
            ],
            "stream": false
        ]
        body["temperature"] = adjustedTemperature(for: agent)
        body["max_tokens"] = agent.config.maxTokens

        let data = try await performJSONRequest(
            url: endpoint,
            headers: [
                "Authorization": "Bearer \(profile.apiKey)",
                "Content-Type": "application/json"
            ],
            body: body,
            providerName: agent.provider.displayName,
            agent: agent
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "CommandRunner",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "\(agent.provider.displayName) 返回了无法解析的响应。"]
            )
        }

        if let errorMessage = extractProviderErrorMessage(from: json) {
            throw NSError(domain: "CommandRunner", code: 6, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }

        let choices = json["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        return extractOpenAICompatibleText(from: message?["content"])
    }

    private func callAnthropicProvider(
        agent: Agent,
        text: String,
        images: [String],
        profile: AgentStore.RuntimeProfile
    ) async throws -> String {
        guard !profile.apiKey.isEmpty else {
            throw NSError(
                domain: "CommandRunner",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Anthropic API Key 为空，请重新配置。"]
            )
        }

        let endpoint = URL(string: "\(normalizedBaseURL(profile.baseURL))/messages")!
        let content = try buildAnthropicContent(text: text, images: images)
        var body: [String: Any] = [
            "model": profile.model,
            "max_tokens": max(agent.config.maxTokens, 1024),
            "messages": [
                ["role": "user", "content": content]
            ]
        ]
        body["temperature"] = adjustedTemperature(for: agent)

        let data = try await performJSONRequest(
            url: endpoint,
            headers: [
                "x-api-key": profile.apiKey,
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json"
            ],
            body: body,
            providerName: agent.provider.displayName,
            agent: agent
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "CommandRunner",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Anthropic 返回了无法解析的响应。"]
            )
        }

        if let errorMessage = extractProviderErrorMessage(from: json) {
            throw NSError(domain: "CommandRunner", code: 9, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }

        let contentBlocks = json["content"] as? [[String: Any]] ?? []
        let textBlocks = contentBlocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return textBlocks.joined(separator: "\n")
    }

    private func callGoogleProvider(
        agent: Agent,
        text: String,
        images: [String],
        profile: AgentStore.RuntimeProfile
    ) async throws -> String {
        guard !profile.apiKey.isEmpty else {
            throw NSError(
                domain: "CommandRunner",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Google API Key 为空，请重新配置。"]
            )
        }

        var components = URLComponents(string: "\(normalizedBaseURL(profile.baseURL))/models/\(profile.model):generateContent")
        components?.queryItems = [URLQueryItem(name: "key", value: profile.apiKey)]

        guard let endpoint = components?.url else {
            throw NSError(
                domain: "CommandRunner",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Google 请求地址无效。"]
            )
        }

        let parts = try buildGoogleParts(text: text, images: images)
        var body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": parts]
            ]
        ]
        body["generationConfig"] = [
            "temperature": adjustedTemperature(for: agent),
            "maxOutputTokens": agent.config.maxTokens
        ]

        let data = try await performJSONRequest(
            url: endpoint,
            headers: ["Content-Type": "application/json"],
            body: body,
            providerName: agent.provider.displayName,
            agent: agent
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "CommandRunner",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Google 返回了无法解析的响应。"]
            )
        }

        if let errorMessage = extractProviderErrorMessage(from: json) {
            throw NSError(domain: "CommandRunner", code: 13, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }

        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let content = candidates.first?["content"] as? [String: Any]
        let partsResponse = content?["parts"] as? [[String: Any]] ?? []
        let textParts = partsResponse.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return textParts.joined(separator: "\n")
    }

    private func performJSONRequest(
        url: URL,
        headers: [String: String],
        body: [String: Any],
        providerName: String,
        agent: Agent? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "CommandRunner",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "\(providerName) 没有返回有效的 HTTP 响应。"]
            )
        }

        // 记录详细的请求/响应日志用于诊断
        let hasAuthHeader = headers.keys.contains { $0.lowercased() == "authorization" || $0.lowercased() == "x-api-key" }
        let apiKeyPreview = hasAuthHeader ? "已提供" : "未提供"
        
        LogDebug("API 请求: \(providerName) \(url.path), 认证: \(apiKeyPreview), 状态码: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            let rawMessage = extractProviderErrorMessage(from: data)
            let responsePreview = String(data: data, encoding: .utf8)?.prefix(500) ?? "无法解析"
            
            LogError("API 错误: \(providerName) HTTP \(httpResponse.statusCode), 响应: \(responsePreview)")
            
            // 根据状态码提供用户友好的错误信息
            let userMessage: String
            switch httpResponse.statusCode {
            case 401:
                let detail = rawMessage ?? "API Key 无效或已过期"
                userMessage = "❌ \(providerName) 认证失败\n\n原因: \(detail)\n\n解决方法:\n1. 检查 API Key 是否正确复制（没有多余的空格）\n2. 确认 API Key 没有过期\n3. 在 Agent 列表中重新配置"
            case 403:
                userMessage = "❌ \(providerName) 权限不足\n\n您的 API Key 可能没有访问该模型的权限。"
            case 429:
                userMessage = "⚠️ \(providerName) 请求过于频繁\n\n请稍后再试，或检查您的用量限制。"
            case 500...599:
                userMessage = "⚠️ \(providerName) 服务器错误 (HTTP \(httpResponse.statusCode))\n\n这是提供商的服务器问题，请稍后再试。"
            default:
                userMessage = rawMessage ?? "\(providerName) 请求失败，HTTP \(httpResponse.statusCode)。"
            }
            
            throw NSError(
                domain: "CommandRunner",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: userMessage]
            )
        }

        if let agent {
            agentStore.restoreAvailability(for: agent)
        }

        return data
    }

    /// 根据模型调整 temperature
    /// 某些模型（如 kimi-k2.5）只支持特定的 temperature 值
    private func adjustedTemperature(for agent: Agent) -> Double {
        let model = agent.model.lowercased()
        
        // kimi-k2.5 只支持 temperature = 1
        if model.contains("kimi-k2.5") || model.contains("kimi-k2") {
            return 1.0
        }
        
        // 其他模型使用配置的值，但确保在有效范围内
        let temp = agent.config.temperature
        return max(0.0, min(2.0, temp))
    }

    private func extractProviderErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw?.isEmpty == false ? raw : nil
        }
        return extractProviderErrorMessage(from: json)
    }

    private func extractProviderErrorMessage(from json: [String: Any]) -> String? {
        if let error = json["error"] as? String, !error.isEmpty {
            return error
        }

        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let details = error["details"] as? String, !details.isEmpty {
                return details
            }
        }

        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }

        return nil
    }

    private func buildOpenAICompatibleContent(text: String, images: [String]) throws -> Any {
        let prompt = normalizedPrompt(text, hasImages: !images.isEmpty)
        guard !images.isEmpty else { return prompt }

        var content: [[String: Any]] = [
            ["type": "text", "text": prompt]
        ]

        for path in images {
            let attachment = try loadImageAttachment(at: path)
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:\(attachment.mimeType);base64,\(attachment.base64)"]
            ])
        }

        return content
    }

    private func buildAnthropicContent(text: String, images: [String]) throws -> [[String: Any]] {
        var content: [[String: Any]] = [
            ["type": "text", "text": normalizedPrompt(text, hasImages: !images.isEmpty)]
        ]

        for path in images {
            let attachment = try loadImageAttachment(at: path)
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": attachment.mimeType,
                    "data": attachment.base64
                ]
            ])
        }

        return content
    }

    private func buildGoogleParts(text: String, images: [String]) throws -> [[String: Any]] {
        var parts: [[String: Any]] = [
            ["text": normalizedPrompt(text, hasImages: !images.isEmpty)]
        ]

        for path in images {
            let attachment = try loadImageAttachment(at: path)
            parts.append([
                "inline_data": [
                    "mime_type": attachment.mimeType,
                    "data": attachment.base64
                ]
            ])
        }

        return parts
    }

    private func extractOpenAICompatibleText(from payload: Any?) -> String {
        if let text = payload as? String {
            return text
        }

        if let blocks = payload as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let type = block["type"] as? String, type == "output_text",
                   let text = block["text"] as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil
            }
            return texts.joined(separator: "\n")
        }

        return ""
    }

    private func loadImageAttachment(at path: String) throws -> (mimeType: String, base64: String) {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return (mimeType(for: url.pathExtension), data.base64EncodedString())
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        case "heic":
            return "image/heic"
        case "bmp":
            return "image/bmp"
        case "tiff", "tif":
            return "image/tiff"
        default:
            return "application/octet-stream"
        }
    }

    private func normalizedPrompt(_ text: String, hasImages: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return hasImages ? "请分析这张图片。" : "你好"
    }

    private func normalizedBaseURL(_ baseURL: String) -> String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    @MainActor
    private func updateAssistantMessage(id: UUID, content: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            if messages[index].content == content {
                scheduleTraceSettlementIfNeeded(forAssistantMessageID: id, content: content)
                return
            }
            var updatedMessages = messages
            updatedMessages[index].content = content
            messages = updatedMessages
            scheduleTraceSettlementIfNeeded(forAssistantMessageID: id, content: content)
        }
    }

    @MainActor
    private func updateAssistantIdentity(id: UUID, agentId: String?, agentName: String?) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        guard messages[index].agentId != agentId || messages[index].agentName != agentName else { return }
        var updatedMessages = messages
        updatedMessages[index].agentId = agentId
        updatedMessages[index].agentName = agentName
        messages = updatedMessages
    }

    @MainActor
    private func upsertAssistantMessage(template: ChatMessage, content: String) {
        if messages.contains(where: { $0.id == template.id }) {
            updateAssistantMessage(id: template.id, content: content)
            return
        }

        var recoveredMessage = template
        recoveredMessage.content = content
        messages.append(recoveredMessage)
        scheduleTraceSettlementIfNeeded(forAssistantMessageID: template.id, content: content)
        LogInfo("恢复缺失的 assistant 消息并补写最终内容: \(template.id.uuidString)")
        
        // 检测并同步服务状态
        Task {
            await MainActor.run {
                detectAndSyncServiceState(from: content)
            }
        }
    }
    
    // MARK: - 服务状态同步
    
    /// 从 AI 响应中检测服务状态变更并同步
    @MainActor
    private func detectAndSyncServiceState(from content: String) {
        // 1. 快速检查是否是服务操作相关内容
        guard ServiceStateParser.isServiceStartRelated(content) ||
              content.contains("MCP") ||
              content.contains("服务") ||
              content.contains("启动") ||
              content.contains("停止") else {
            return
        }
        
        // 2. 提取服务列表（如果是批量操作）
        let serviceList = ServiceStateParser.extractServiceList(from: content)
        if !serviceList.isEmpty {
            // 批量更新服务状态
            for (name, status, detail) in serviceList {
                syncServiceState(
                    serviceName: name,
                    statusText: status,
                    detail: detail,
                    content: content
                )
            }
            return
        }
        
        // 3. 单服务操作 - 识别服务名称
        if let serviceID = UnifiedServiceState.shared.findServiceID(byName: content) ??
                          ServiceStateParser().identifyService(in: content) {
            // 解析操作类型和结果
            let operation = detectOperationType(from: content)
            let parser = ServiceStateParser()
            let result = parser.parse(result: content, for: serviceID)
            
            // 同步到统一状态中心
            UnifiedServiceState.shared.handleMainSessionOperation(
                serviceName: serviceID,
                operation: operation,
                result: content
            )
            
            LogInfo("[CommandRunner] 同步服务状态: \(serviceID) -> \(result.status?.displayName ?? "unknown")")
        }
    }
    
    /// 检测操作类型
    private func detectOperationType(from content: String) -> ServiceOperation {
        let lowercased = content.lowercased()
        
        if lowercased.contains("启动") || lowercased.contains("start") {
            return .start
        } else if lowercased.contains("停止") || lowercased.contains("stop") {
            return .stop
        } else if lowercased.contains("重启") || lowercased.contains("restart") {
            return .restart
        } else {
            return .check
        }
    }
    
    /// 同步服务状态（从表格格式提取）
    @MainActor
    private func syncServiceState(
        serviceName: String,
        statusText: String,
        detail: String,
        content: String
    ) {
        guard let serviceID = UnifiedServiceState.shared.findServiceID(byName: serviceName) else {
            LogWarning("[CommandRunner] 无法找到服务: \(serviceName)")
            return
        }
        
        // 解析状态
        let status: ServiceRuntimeStatus
        if statusText.contains("运行中") || statusText.contains("✅") {
            status = .running
        } else if statusText.contains("停止") || statusText.contains("❌") {
            status = .stopped
        } else {
            status = .unknown
        }
        
        // 解析 PID 或端口
        var metadata: [String: String] = [:]
        if detail.contains("PID") {
            let pidPattern = try? NSRegularExpression(pattern: #"(\d+)"#, options: [])
            let matches = pidPattern?.matches(
                in: detail,
                options: [],
                range: NSRange(location: 0, length: detail.utf16.count)
            )
            if let match = matches?.first, match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                if let r = Range(range, in: detail) {
                    metadata["pid"] = String(detail[r])
                }
            }
        } else if detail.contains("port") {
            let portPattern = try? NSRegularExpression(pattern: #"(\d+)"#, options: [])
            let matches = portPattern?.matches(
                in: detail,
                options: [],
                range: NSRange(location: 0, length: detail.utf16.count)
            )
            if let match = matches?.first, match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                if let r = Range(range, in: detail) {
                    metadata["port"] = String(detail[r])
                }
            }
        }
        
        // 更新状态
        UnifiedServiceState.shared.updateServiceState(
            serviceID: serviceID,
            status: status,
            source: .aiOperation,
            metadata: metadata
        )
    }

    @MainActor
    private func startExecutionTrace(
        anchorMessageID: UUID,
        agentName: String,
        intentName: String,
        summary: String,
        state: ExecutionTraceState = .routing,
        transitionLabel: String? = nil,
        sessionID: String? = nil
    ) -> UUID {
        let trace = ExecutionTrace(
            anchorMessageID: anchorMessageID,
            agentName: agentName,
            intentName: intentName,
            transitionLabel: transitionLabel,
            summary: summary,
            state: state,
            sessionID: sessionID
        )
        traceDismissTasks[trace.id]?.cancel()
        traceDismissTasks[trace.id] = nil
        messageExecutionTraces[trace.id] = trace
        refreshCurrentExecutionTrace()
        return trace.id
    }

    @MainActor
    private func attachExecutionTrace(traceID: UUID, to assistantMessageID: UUID) {
        guard var trace = messageExecutionTraces[traceID] else { return }
        trace.assistantMessageID = assistantMessageID
        messageExecutionTraces[traceID] = trace
        refreshCurrentExecutionTrace()
    }

    @MainActor
    private func updateExecutionTrace(
        traceID: UUID,
        state: ExecutionTraceState? = nil,
        agentName: String? = nil,
        intentName: String? = nil,
        transitionLabel: String? = nil,
        summary: String? = nil,
        currentStep: String? = nil,
        stepDetails: String? = nil,
        partialOutput: String? = nil,
        progressPercent: Int? = nil,
        currentTool: String? = nil,
        addLog: (level: TraceLogEntry.LogLevel, message: String)? = nil
    ) {
        guard var trace = messageExecutionTraces[traceID] else { return }
        let oldState = trace.state
        traceDismissTasks[traceID]?.cancel()
        
        if let state = state {
            trace.state = state
        }
        if let agentName {
            trace.agentName = agentName
        }
        if let intentName {
            trace.intentName = intentName
        }
        if let transitionLabel = transitionLabel {
            trace.transitionLabel = transitionLabel
        }
        if let summary = summary {
            trace.summary = summary
        }
        if let currentStep = currentStep {
            trace.currentStep = currentStep
        }
        if let stepDetails = stepDetails {
            trace.stepDetails = stepDetails
        }
        if let partialOutput = partialOutput {
            trace.partialOutput = partialOutput
        }
        if let progressPercent = progressPercent {
            trace.progressPercent = progressPercent
        }
        if let currentTool = currentTool {
            trace.currentTool = currentTool
        }
        if let addLog = addLog {
            trace.executionLog.append(TraceLogEntry(level: addLog.level, message: addLog.message))
        }
        
        trace.lastUpdatedAt = Date()
        
        if let newState = state, !newState.isActive {
            trace.finishedAt = Date()
        }
        messageExecutionTraces[traceID] = trace
        refreshCurrentExecutionTrace()
        
        // 同步到主会话：关键状态变化时更新进展消息
        if let newState = state, oldState != newState && shouldSyncTraceStateToMainConversation(oldState: oldState, newState: newState) {
            syncTraceStateToMainConversation(trace: trace, previousState: oldState)
        }
    }
    
    /// 快速更新 Trace 步骤（用于 CLI 式详细进度）
    @MainActor
    private func updateTraceStep(
        traceID: UUID,
        step: String,
        details: String? = nil,
        progress: Int? = nil,
        log: String? = nil
    ) {
        updateExecutionTrace(
            traceID: traceID,
            currentStep: step,
            stepDetails: details,
            progressPercent: progress,
            addLog: log.map { (.info, $0) }
        )
    }
    
    /// 判断是否应该同步 Trace 状态到主会话
    private func shouldSyncTraceStateToMainConversation(oldState: ExecutionTraceState, newState: ExecutionTraceState) -> Bool {
        // 路由完成、开始执行、回退、完成、失败等关键节点同步
        switch (oldState, newState) {
        case (.routing, .running),      // 路由完成，开始执行
             (.routing, .fallback),     // 路由直接到回退
             (.running, .fallback),     // 执行中回退
             (.fallback, .running),     // 回退后继续执行
             (.running, .synthesizing), // 执行完成，开始整合
             (_, .completed),           // 任何状态到完成
             (_, .failed):              // 任何状态到失败
            return true
        default:
            return false
        }
    }
    
    /// 同步 Trace 状态到主会话进展消息
    @MainActor
    private func syncTraceStateToMainConversation(trace: ExecutionTrace, previousState: ExecutionTraceState) {
        let content: String
        let agentName = trace.agentName
        
        switch trace.state {
        case .running where previousState == .routing:
            content = "**\(agentName)** 已接管并开始处理..."
        case .running where previousState == .fallback:
            content = "**\(agentName)** 正在继续处理（已从回退恢复）..."
        case .fallback:
            content = "**\(agentName)** 执行遇到问题，正在切换到备用方案..."
        case .synthesizing:
            content = "**\(agentName)** 已生成初步结果，正在整合..."
        case .completed:
            content = "**\(agentName)** 已完成处理。"
        case .failed:
            content = "**\(agentName)** 处理失败。"
        default:
            return
        }
        
        upsertConversationProgressMessage(
            key: "trace_progress_\(trace.id)",
            content: content,
            agentID: nil,
            agentName: agentName,
            metadata: [
                "message_key": "trace_progress_\(trace.id)",
                "is_progress_update": "true",
                "progress_source": "execution_trace",
                "trace_id": trace.id.uuidString,
                "trace_state": trace.state.rawValue,
                "previous_state": previousState.rawValue
            ]
        )
    }

    @MainActor
    private func completeExecutionTrace(traceID: UUID, summary: String) {
        traceSettleTasks[traceID]?.cancel()
        traceSettleTasks[traceID] = nil
        updateExecutionTrace(traceID: traceID, state: .completed, summary: summary)
        scheduleExecutionTraceDismiss(traceID: traceID, after: 1.6)
        // 清理对应的进展消息
        scheduleProgressMessageCleanup(key: "trace_progress_\(traceID)", after: 3.0)
    }

    @MainActor
    private func failExecutionTrace(traceID: UUID, summary: String) {
        traceSettleTasks[traceID]?.cancel()
        traceSettleTasks[traceID] = nil
        updateExecutionTrace(traceID: traceID, state: .failed, summary: summary)
        scheduleExecutionTraceDismiss(traceID: traceID, after: 4)
        // 清理对应的进展消息
        scheduleProgressMessageCleanup(key: "trace_progress_\(traceID)", after: 6.0)
    }
    
    /// 调度清理进展消息
    @MainActor
    private func scheduleProgressMessageCleanup(key: String, after delay: TimeInterval) {
        Task { @MainActor [weak self] in
            let duration = UInt64(max(delay, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: duration)
            guard let self else { return }
            
            // 找到并删除对应的进展消息
            if let index = self.messages.firstIndex(where: { 
                $0.metadata?["message_key"] == key && $0.metadata?["is_progress_update"] == "true"
            }) {
                var updatedMessages = self.messages
                updatedMessages.remove(at: index)
                self.messages = updatedMessages
            }
        }
    }

    @MainActor
    private func clearFinishedExecutionTraces() {
        let finishedIDs = messageExecutionTraces.values
            .filter { !$0.state.isActive }
            .map(\.id)

        for traceID in finishedIDs {
            traceDismissTasks[traceID]?.cancel()
            traceDismissTasks[traceID] = nil
            traceSettleTasks[traceID]?.cancel()
            traceSettleTasks[traceID] = nil
            messageExecutionTraces.removeValue(forKey: traceID)
        }

        refreshCurrentExecutionTrace()
    }

    @MainActor
    private func scheduleExecutionTraceDismiss(traceID: UUID, after delay: TimeInterval) {
        traceDismissTasks[traceID]?.cancel()
        traceDismissTasks[traceID] = Task { @MainActor [weak self] in
            let duration = UInt64(max(delay, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: duration)
            guard let self else { return }
            self.messageExecutionTraces.removeValue(forKey: traceID)
            self.traceDismissTasks[traceID] = nil
            self.traceSettleTasks[traceID]?.cancel()
            self.traceSettleTasks[traceID] = nil
            self.refreshCurrentExecutionTrace()
        }
    }

    @MainActor
    private func scheduleTraceSettlementIfNeeded(forAssistantMessageID messageID: UUID, content: String) {
        guard let traceID = traceID(forAssistantMessageID: messageID),
              let trace = messageExecutionTraces[traceID],
              trace.state.isActive else {
            return
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProcessingPlaceholderContent(trimmed) else {
            traceSettleTasks[traceID]?.cancel()
            traceSettleTasks[traceID] = nil
            return
        }

        traceSettleTasks[traceID]?.cancel()
        traceSettleTasks[traceID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self,
                  let currentTrace = self.messageExecutionTraces[traceID],
                  currentTrace.state.isActive else {
                return
            }
            self.completeExecutionTrace(traceID: traceID, summary: "结果已经返回到聊天窗口")
            LogInfo("Trace quiet-settled after assistant content stabilized: \(traceID.uuidString)")
        }
    }

    @MainActor
    private func traceID(forAssistantMessageID messageID: UUID) -> UUID? {
        messageExecutionTraces.values.first { $0.assistantMessageID == messageID }?.id
    }

    private func isProcessingPlaceholderContent(_ content: String) -> Bool {
        guard content.hasPrefix("⏳ ") else { return false }
        return content.contains("正在思考") ||
            content.contains("正在继续处理") ||
            content.contains("正在连接") ||
            content.contains("正在直接调用")
    }

    @MainActor
    func executionTrace(forMessageID messageID: UUID) -> ExecutionTrace? {
        messageExecutionTraces.values
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

    @MainActor
    private func refreshCurrentExecutionTrace() {
        currentExecutionTrace = messageExecutionTraces.values
            .filter(\.state.isActive)
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }
    
    // MARK: - 辅助方法
    
    @MainActor
    private func ensureScreenRecordingAccessForScreenshot() -> Bool {
        if #available(macOS 10.15, *) {
            guard !isRestartingForScreenRecordingPermission else { return false }

            if CGPreflightScreenCaptureAccess() {
                isWaitingForScreenRecordingAuthorization = false
                return true
            }

            isWaitingForScreenRecordingAuthorization = true
            appendSystemMessage(
                """
                为了截图，我需要先获得 macOS 的“屏幕与系统音频录制”权限。

                我会打开系统设置。你授权后回到当前这个开发版应用，我会重新打开现在这份源码版实例，不会再跳到旧版 App。
                """
            )

            let granted = CGRequestScreenCaptureAccess()
            if granted {
                appendSystemMessage("已经检测到截图权限可用，正在重新打开当前源码版应用以让权限生效。")
                restartCurrentAppForScreenRecordingPermission()
            } else if let settingsURL = screenRecordingSettingsURL {
                NSWorkspace.shared.open(settingsURL)
            }

            return false
        }

        return true
    }

    @MainActor
    private func resumePendingScreenRecordingFlowIfNeeded() {
        guard isWaitingForScreenRecordingAuthorization, !isRestartingForScreenRecordingPermission else {
            return
        }

        if #available(macOS 10.15, *), CGPreflightScreenCaptureAccess() {
            isWaitingForScreenRecordingAuthorization = false
            appendSystemMessage("已检测到你刚刚授予了截图权限，正在重新打开当前源码版应用。")
            restartCurrentAppForScreenRecordingPermission()
        }
    }

    @MainActor
    private func resumePendingKimiCLILoginFlowIfNeeded() async {
        guard isWaitingForKimiCLILogin,
              let agentID = pendingKimiCLILoginAgentID,
              let agent = agentStore.agent(withId: agentID) else {
            return
        }

        let status = await agentStore.validateLocalCodingRuntimeStatus()
        guard status.isValid else {
            return
        }

        isWaitingForKimiCLILogin = false
        pendingKimiCLILoginAgentID = nil

        appendSystemMessage(
            "✅ 已检测到 \(agent.displayName) 的 Kimi CLI 登录恢复成功。你现在可以继续提问了。"
        )
        await reconcileInterruptedTaskSessions(trigger: "kimi-login-restored")
    }

    @MainActor
    private func restartCurrentAppForScreenRecordingPermission() {
        guard !isRestartingForScreenRecordingPermission else { return }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        isRestartingForScreenRecordingPermission = true

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    CommandRunner.shared.appendSystemMessage(
                        "我已经拿到截图权限，但重新打开当前源码版应用时失败了：\(error.localizedDescription)"
                    )
                    CommandRunner.shared.fallbackRelaunchCurrentApp(at: bundleURL)
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    @MainActor
    private func fallbackRelaunchCurrentApp(at bundleURL: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]

        do {
            try task.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        } catch {
            isRestartingForScreenRecordingPermission = false
            appendSystemMessage(
                "截图权限已经准备好了，但我没能重新拉起当前源码版应用。你可以手动重新打开这份开发版 App。"
            )
        }
    }

    @MainActor
    private func completeScreenshotFlow(with screenshotPath: String) {
        lastScreenshotPath = screenshotPath

        appendSystemMessage(
            "📸 截图已保存: \(screenshotPath)",
            images: [screenshotPath]
        )

        guard !agentStore.needsInitialSetup else {
            presentInitialSetupPrompt(for: "分析截图")
            return
        }

        if let currentAgent = orchestrator.currentAgent {
            if currentAgent.supportsImageAnalysis {
                Task {
                    await processInput("分析这张截图", images: [screenshotPath])
                }
            } else {
                handleVisionGap(screenshotPath: screenshotPath)
            }
        } else {
            handleVisionGap(screenshotPath: screenshotPath)
        }
    }

    @MainActor
    private func appendSystemMessage(_ content: String, images: [String] = []) {
        let systemMessage = ChatMessage(
            id: UUID(),
            role: .system,
            content: content,
            timestamp: Date(),
            images: images
        )
        messages.append(systemMessage)
    }

    @MainActor
    private func appendAssistantConversationMessage(
        _ content: String,
        metadata: [String: String]? = nil
    ) {
        let assistantMessage = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date(),
            metadata: metadata
        )
        messages.append(assistantMessage)
    }

    @MainActor
    private func upsertConversationProgressMessage(
        key: String,
        content: String,
        agentID: String? = nil,
        agentName: String? = nil,
        metadata: [String: String]
    ) {
        if let index = messages.firstIndex(where: { $0.metadata?["message_key"] == key && $0.linkedTaskSessionID == nil }) {
            let existing = messages[index]
            let mergedMetadata = (existing.metadata ?? [:]).merging(metadata) { _, new in new }
            guard existing.content != content ||
                    existing.agentId != agentID ||
                    existing.agentName != agentName ||
                    existing.metadata != mergedMetadata else {
                return
            }

            var updatedMessages = messages
            updatedMessages[index].content = content
            updatedMessages[index].agentId = agentID
            updatedMessages[index].agentName = agentName
            updatedMessages[index].metadata = mergedMetadata
            messages = updatedMessages
            return
        }

        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date(),
            agentId: agentID,
            agentName: agentName,
            metadata: metadata
        )
        messages.append(message)
    }

    @MainActor
    private func syncTaskSessionProgressFeed(with sessions: [AgentTaskSession]) {
        let nextSnapshots: [String: ConversationProgressSnapshot] = sessions.compactMap { session -> (String, ConversationProgressSnapshot)? in
            guard let snapshot = taskSessionProgressSnapshot(for: session) else { return nil }
            return (conversationProgressIdentity(for: session), snapshot)
        }.reduce(into: [:]) { dict, pair in
            dict[pair.0] = pair.1
        }

        for (identity, snapshot) in nextSnapshots {
            guard taskSessionProgressSnapshots[identity] != snapshot else { continue }
            upsertConversationProgressMessage(
                key: snapshot.messageKey,
                content: snapshot.content,
                agentID: snapshot.agentID,
                agentName: snapshot.agentName,
                metadata: snapshot.metadata
            )
        }

        taskSessionProgressSnapshots = nextSnapshots
    }

    @MainActor
    private func syncUnifiedTaskProgressFeed(with tasks: [UnifiedTask]) {
        let bridgedGatewayKeys = Set(taskSessions.compactMap(\.gatewaySessionKey))
        let nextSnapshots: [String: ConversationProgressSnapshot] = tasks.compactMap { task -> (String, ConversationProgressSnapshot)? in
            if let gatewaySessionKey = task.gatewaySessionKey,
               bridgedGatewayKeys.contains(gatewaySessionKey) {
                return nil
            }
            guard let snapshot = unifiedTaskProgressSnapshot(for: task) else { return nil }
            return (conversationProgressIdentity(for: task), snapshot)
        }.reduce(into: [:]) { dict, pair in
            dict[pair.0] = pair.1
        }

        for (identity, snapshot) in nextSnapshots {
            guard unifiedTaskProgressSnapshots[identity] != snapshot else { continue }
            upsertConversationProgressMessage(
                key: snapshot.messageKey,
                content: snapshot.content,
                agentID: snapshot.agentID,
                agentName: snapshot.agentName,
                metadata: snapshot.metadata
            )
        }

        unifiedTaskProgressSnapshots = nextSnapshots
    }

    private func conversationProgressIdentity(for session: AgentTaskSession) -> String {
        session.gatewaySessionKey.map { "gateway:\($0)" } ?? "task-session:\(session.id)"
    }

    private func conversationProgressIdentity(for task: UnifiedTask) -> String {
        task.gatewaySessionKey.map { "gateway:\($0)" } ?? "unified-task:\(task.id)"
    }

    private func taskSessionProgressSnapshot(for session: AgentTaskSession) -> ConversationProgressSnapshot? {
        let identity = conversationProgressIdentity(for: session)
        let phase = session.status.rawValue
        let detail = taskSessionProgressDetail(for: session)
        let content: String

        switch session.status {
        case .queued:
            content = """
            已收到「\(session.title)」，并转为独立任务。
            当前进展：\(detail)
            """
        case .running:
            content = """
            「\(session.title)」正在处理中。
            当前进展：\(detail)
            """
        case .partial:
            content = """
            「\(session.title)」暂时中断，已保留当前进度。
            当前情况：\(detail)
            """
        case .waitingUser:
            content = """
            「\(session.title)」需要你继续处理。
            当前情况：\(detail)
            """
        case .completed:
            content = """
            「\(session.title)」已完成。
            关键结果：\(detail)
            """
        case .failed:
            content = """
            「\(session.title)」执行失败。
            原因：\(detail)
            """
        }

        return ConversationProgressSnapshot(
            messageKey: "conversation_progress_\(identity)_\(phase)",
            content: content,
            agentID: session.delegateAgentID,
            agentName: session.delegateAgentName ?? session.mainAgentName,
            metadata: [
                "message_key": "conversation_progress_\(identity)_\(phase)",
                "is_progress_update": "true",
                "progress_source": "task_session",
                "progress_identity": identity,
                "progress_phase": phase,
                "task_session_id": session.id
            ]
        )
    }

    private func taskSessionProgressDetail(for session: AgentTaskSession) -> String {
        switch session.status {
        case .completed:
            if session.intentName != "独立处理" {
                return "执行已经结束，结果正在同步回主会话。"
            }
            return compactConversationProgressText(
                session.resultSummary ??
                session.latestAssistantText ??
                session.statusSummary
            )
        case .failed, .waitingUser, .partial:
            return compactConversationProgressText(
                session.errorMessage ??
                session.resultSummary ??
                session.latestAssistantText ??
                session.statusSummary
            )
        case .queued, .running:
            return compactConversationProgressText(session.statusSummary)
        }
    }

    private func unifiedTaskProgressSnapshot(for task: UnifiedTask) -> ConversationProgressSnapshot? {
        let identity = conversationProgressIdentity(for: task)
        let phase = taskProgressPhase(for: task)
        let detail = unifiedTaskProgressDetail(for: task)
        let content: String

        switch phase {
        case "scheduled":
            content = """
            「\(task.title)」已排期。
            当前进展：\(detail)
            """
        case UnifiedTaskStatus.pending.rawValue:
            content = """
            「\(task.title)」已进入任务中心，等待开始。
            当前进展：\(detail)
            """
        case UnifiedTaskStatus.running.rawValue:
            content = """
            「\(task.title)」正在执行。
            当前进展：\(detail)
            """
        case UnifiedTaskStatus.paused.rawValue:
            content = """
            「\(task.title)」等待继续处理。
            当前情况：\(detail)
            """
        case UnifiedTaskStatus.completed.rawValue:
            content = """
            「\(task.title)」已完成。
            关键结果：\(detail)
            """
        case UnifiedTaskStatus.failed.rawValue:
            content = """
            「\(task.title)」执行失败。
            原因：\(detail)
            """
        default:
            return nil
        }

        return ConversationProgressSnapshot(
            messageKey: "conversation_progress_\(identity)_\(phase)",
            content: content,
            agentID: task.assignedAgentID,
            agentName: task.assignedAgentName,
            metadata: [
                "message_key": "conversation_progress_\(identity)_\(phase)",
                "is_progress_update": "true",
                "progress_source": "unified_task",
                "progress_identity": identity,
                "progress_phase": phase,
                "task_id": task.id
            ]
        )
    }

    private func taskProgressPhase(for task: UnifiedTask) -> String {
        if task.status == .pending, let scheduledTime = task.scheduledTime, scheduledTime > Date() {
            return "scheduled"
        }
        return task.status.rawValue
    }

    private func unifiedTaskProgressDetail(for task: UnifiedTask) -> String {
        switch taskProgressPhase(for: task) {
        case "scheduled":
            if let scheduledTime = task.scheduledTime {
                return "计划于 \(scheduledTime.formatted(date: .abbreviated, time: .shortened)) 执行。"
            }
            return compactConversationProgressText(task.description)
        case UnifiedTaskStatus.completed.rawValue:
            return compactConversationProgressText(
                task.result ??
                task.messages.last?.content ??
                task.logs.last?.message ??
                task.description
            )
        case UnifiedTaskStatus.failed.rawValue, UnifiedTaskStatus.paused.rawValue:
            return compactConversationProgressText(
                task.errorMessage ??
                task.logs.last?.message ??
                task.description
            )
        case UnifiedTaskStatus.running.rawValue, UnifiedTaskStatus.pending.rawValue:
            return compactConversationProgressText(
                task.logs.last?.message ??
                task.messages.last?.content ??
                (task.description.isEmpty ? task.title : task.description)
            )
        default:
            return compactConversationProgressText(task.description)
        }
    }

    private func compactConversationProgressText(_ text: String?) -> String {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "处理中" }
        if trimmed.count <= 120 {
            return trimmed
        }
        return "\(trimmed.prefix(120))..."
    }

    @MainActor
    private func activeWorkflowDesignContext() -> WorkflowDesignContinuationContext? {
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

    private func restorePersistedState() {
        isRestoringPersistedState = true
        defer { isRestoringPersistedState = false }

        messages = StorageManager.shared.getRecentMessages(limit: 50)
        taskSessions = normalizeRestoredTaskSessions(executionJournal.loadTaskSessions())
        executionJournal.saveTaskSessions(taskSessions)
    }

    private func normalizeRestoredTaskSessions(_ sessions: [AgentTaskSession]) -> [AgentTaskSession] {
        let restoredAt = Date()
        return sessions.map { session in
            var normalized = session
            if normalized.gatewaySessionKey == nil {
                normalized.gatewaySessionKey = gatewaySessionKey(forTaskSessionID: normalized.id)
            }
            switch normalized.status {
            case .queued, .running:
                normalized.status = .partial
                normalized.statusSummary = "应用重新打开，正在回查上次中断的结果"
                normalized.canResume = true
                normalized.isExpanded = true
                normalized.updatedAt = restoredAt
            case .partial, .waitingUser:
                normalized.canResume = true
            case .completed, .failed:
                break
            }
            return normalized
        }
    }

    /// 保存截图到桌面
    private func saveScreenshotToDesktop() -> String? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let filename = "screenshot-\(dateFormatter.string(from: Date())).png"
        
        let desktopPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(filename)
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-x", desktopPath.path]

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        guard task.terminationStatus == 0,
              FileManager.default.fileExists(atPath: desktopPath.path) else {
            return nil
        }

        return desktopPath.path
    }
    
    /// 旧方法：通过通知显示能力缺口（保留弹窗选项）
    private func handleCapabilityGap(_ gap: CapabilityGap) {
        // 仍然发送通知，让 UI 层决定是否显示弹窗
        NotificationCenter.default.post(
            name: NSNotification.Name("ShowCapabilityWizard"),
            object: gap
        )
    }
    
    /// 清除对话历史
    func clearMessages() {
        messages.removeAll()
    }

    func loadHistory() {
        restorePersistedState()
    }

    func clearHistory() {
        messages.removeAll()
        taskSessions.removeAll()
        StorageManager.shared.clearHistory()
        executionJournal.clear()
        conversationControl.resetConversation()
    }

    func screenshotAndAsk() {
        handleScreenshot()
    }

    func clipboardAndAsk() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.isEmpty else { return }
        Task {
            await processInput(text)
        }
    }

    func showInitialSetupGuidance(for action: String? = nil) {
        if Thread.isMainThread {
            presentInitialSetupPrompt(for: action)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.presentInitialSetupPrompt(for: action)
            }
        }
    }

    private func presentInitialSetupPrompt(for action: String? = nil) {
        let actionText = action ?? "开始对话"
        let content = """
        ⚙️ 当前还没有可用的 LLM 或 CLI Agent

        在首次使用前，请先完成一次模型配置，然后再继续\(actionText)。
        你可以先配置本地 Kimi CLI，或者添加其他需要 API Key 的 Agent。
        """

        let isDuplicatePrompt = messages.last?.metadata?[initialSetupPromptKey] == "true"
        if !isDuplicatePrompt {
            let promptMessage = ChatMessage(
                id: UUID(),
                role: .system,
                content: content,
                timestamp: Date(),
                metadata: [initialSetupPromptKey: "true"]
            )
            messages.append(promptMessage)
        }

        NotificationCenter.default.post(
            name: NSNotification.Name("ShowInitialSetupWizard"),
            object: nil
        )
    }
}

// 注意: ChatMessage 定义在 ChatModels.swift 中共享使用

// MARK: - 异常处理函数（方案C）

extension CommandRunner {
    
    /// 处理流中断异常
    func handleStreamInterrupted(
        sessionID: String,
        originalRequest: String,
        partialResult: String?,
        images: [String]
    ) async {
        LogInfo("[CommandRunner] 处理流中断: session=\(sessionID)")
        
        // 触发后台恢复作为兜底
        await BackgroundTaskRecoveryService.shared.scheduleRecovery(
            sessionID: sessionID,
            originalRequest: originalRequest,
            delaySeconds: 10
        )
        
        await MainActor.run {
            messages.append(
                ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: """
                    🔄 已启动自动恢复流程
                    
                    检测到连接中断，已安排在10秒后自动尝试恢复。你也可以：
                    • 点击任务卡片「继续处理」立即恢复
                    • 发送「检查状态」查看当前进展
                    """,
                    timestamp: Date(),
                    agentId: "builtin-recovery",
                    agentName: "恢复助手"
                )
            )
            isProcessing = false
        }
    }
    
    /// 处理检查任务状态请求（方案B）
    func handleCheckTaskStatus(sessionID: String) async {
        LogInfo("[CommandRunner] 检查任务状态: session=\(sessionID)")
        
        let result = await TaskStatusChecker.shared.checkTaskStatus(sessionID: sessionID)
        
        let statusMessage: String
        switch result.status {
        case .running:
            statusMessage = "⏳ 任务仍在运行中..."
        case .completed:
            statusMessage = "✅ 任务已完成"
        case .stalled:
            statusMessage = "⚠️ 任务似乎卡住了"
        case .error:
            statusMessage = "❌ 任务执行出错"
        case .unknown:
            statusMessage = "❓ 任务状态未知"
        }
        
        await MainActor.run {
            messages.append(
                ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: """
                    \(statusMessage)
                    
                    \(result.hasNewOutput ? "发现新输出:\n\(result.latestOutput ?? "")" : "暂无新进展")
                    
                    建议: \(TaskStatusChecker.shared.getActionDescription(result.suggestedAction))
                    """,
                    timestamp: Date(),
                    agentId: "builtin-status-checker",
                    agentName: "状态检查"
                )
            )
            isProcessing = false
        }
    }
}

// MARK: - Service Task Management Public APIs

extension CommandRunner {
    
    /// 添加任务会话（Public API for ServiceTaskManager）
    @MainActor
    func addTaskSession(_ session: AgentTaskSession) {
        taskSessions.append(session)
    }
    
    /// 添加消息到主会话（Public API for ServiceTaskManager）
    @MainActor
    func appendMessage(_ message: ChatMessage) {
        messages.append(message)
    }
    
    /// 添加任务会话消息（Public API for ServiceTaskManager）
    @MainActor
    @discardableResult
    func appendTaskSessionMessage(
        sessionID: String,
        role: MessageRole,
        content: String,
        agentName: String? = nil
    ) -> UUID {
        let message = TaskSessionMessage(
            role: role,
            content: content,
            agentName: agentName
        )
        guard let index = taskSessions.firstIndex(where: { $0.id == sessionID }) else {
            LogWarning("[CommandRunner] 尝试向不存在的任务会话添加消息: \(sessionID)")
            return message.id
        }
        taskSessions[index].messages.append(message)
        taskSessions[index].updatedAt = Date()
        if role == .assistant {
            taskSessions[index].latestAssistantText = content
        }
        return message.id
    }
    
    /// 更新任务会话状态（Public API for ServiceTaskManager）
    @MainActor
    func updateTaskSessionStatus(
        sessionID: String,
        status: TaskSessionStatus,
        summary: String,
        isExpanded: Bool? = nil,
        resultSummary: String? = nil,
        errorMessage: String? = nil
    ) {
        guard let index = taskSessions.firstIndex(where: { $0.id == sessionID }) else {
            LogWarning("[CommandRunner] 尝试更新不存在的任务会话状态: \(sessionID)")
            return
        }
        
        var didChange = false
        
        if taskSessions[index].status != status {
            taskSessions[index].status = status
            didChange = true
        }
        if taskSessions[index].statusSummary != summary {
            taskSessions[index].statusSummary = summary
            didChange = true
        }
        if let isExpanded, taskSessions[index].isExpanded != isExpanded {
            taskSessions[index].isExpanded = isExpanded
            didChange = true
        }
        if let resultSummary, taskSessions[index].resultSummary != resultSummary {
            taskSessions[index].resultSummary = resultSummary
            didChange = true
        }
        if let errorMessage, taskSessions[index].errorMessage != errorMessage {
            taskSessions[index].errorMessage = errorMessage
            didChange = true
        }
        
        guard didChange else { return }
        taskSessions[index].updatedAt = Date()
        
        // 通知后台任务状态变化（插入主对话）
        notifyTaskSessionStatusChange(
            sessionID: sessionID,
            title: taskSessions[index].title,
            status: status,
            resultSummary: resultSummary,
            errorMessage: errorMessage
        )
    }
    
    /// 设置当前执行跟踪（Public API for ServiceTaskManager）
    func setCurrentExecutionTrace(_ trace: ExecutionTrace) {
        currentExecutionTrace = trace
    }
    
    // MARK: - Service Task Execution Public API
    
    /// 执行服务管理任务（Public API for ServiceTaskManager）
    /// 这个方法是 ServiceTaskManager 调用 AI 的入口
    @MainActor
    func executeServiceTask(
        taskSessionID: String,
        prompt: String,
        agent: Agent? = nil
    ) async throws -> String {
        // 获取 Agent
        let targetAgent = agent
            ?? orchestrator.currentAgent
            ?? agentStore.defaultAgent
            ?? agentStore.agents.first!
        
        // 生成 session key
        let sessionKey = gatewaySessionKey(forTaskSessionID: taskSessionID)
        
        // 添加初始消息到任务会话
        let assistantMessageID = appendTaskSessionMessage(
            sessionID: taskSessionID,
            role: .assistant,
            content: "⏳ \(targetAgent.name) 正在处理...",
            agentName: targetAgent.name
        )
        
        // 调用 Gateway 执行 AI 请求
        let result = try await sendViaGateway(
            agent: targetAgent,
            sessionKey: sessionKey,
            sessionLabel: "服务管理 - \(taskSessionID)",
            text: prompt,
            images: [],
            taskSessionID: taskSessionID,
            assistantMessageID: assistantMessageID
        )
        
        return result
    }
}

// MARK: - Health Monitor Integration

extension CommandRunner {
    
    /// 处理健康监控告警
    @MainActor
    private func handleHealthMonitorAlert(_ userInfo: [String: Any]) {
        guard let serviceID = userInfo["service_id"] as? String,
              let serviceName = userInfo["service_name"] as? String,
              let severityRaw = userInfo["severity"] as? String,
              let severity = HealthSeverity(rawValue: severityRaw),
              let message = userInfo["message"] as? String else {
            return
        }
        
        // 根据严重级别决定通知方式
        let icon: String
        let title: String
        let color: String
        
        switch severity {
        case .info:
            icon = "ℹ️"
            title = "服务状态"
            color = "blue"
        case .warning:
            icon = "⚠️"
            title = "服务警告"
            color = "orange"
        case .error:
            icon = "❌"
            title = "服务异常"
            color = "red"
        case .critical:
            icon = "🚨"
            title = "服务严重异常"
            color = "red"
        }
        
        // 发送到主会话
        let alertMessage = ChatMessage(
            id: UUID(),
            role: .system,
            content: """
            \(icon) **\(title)**
            
            服务：\(serviceName)
            级别：\(severity.displayName)
            详情：\(message)
            
            [查看详情] [AI 诊断] [忽略]
            """,
            timestamp: Date(),
            metadata: [
                "health_alert": "true",
                "service_id": serviceID,
                "severity": severityRaw,
                "message": message
            ]
        )
        
        messages.append(alertMessage)
        
        // 发送系统通知
        sendSystemNotification(
            title: title,
            body: "\(serviceName): \(message)"
        )
        
        LogInfo("[CommandRunner] 健康监控告警已发送到主会话: \(serviceName) - \(severity.displayName)")
    }
    
    /// 处理健康监控 AI 诊断请求
    @MainActor
    private func handleHealthMonitorAIDiagnosis(_ userInfo: [String: Any]) async {
        guard let serviceID = userInfo["service_id"] as? String,
              let serviceName = userInfo["service_name"] as? String else {
            return
        }
        
        // 获取服务信息
        guard ServiceManager.shared.services.contains(where: { $0.id == serviceID }) else {
            return
        }
        
        // 发送到主会话，询问用户是否进行 AI 诊断
        let diagnosisRequestMessage = ChatMessage(
            id: UUID(),
            role: .system,
            content: """
            🔍 **AI 诊断请求**
            
            服务「\(serviceName)」健康检查失败，是否让 AI 进行诊断分析？
            
            AI 将会：
            • 检查服务日志
            • 分析配置问题
            • 提供修复建议
            
            [立即诊断] [稍后处理] [忽略]
            """,
            timestamp: Date(),
            metadata: [
                "ai_diagnosis_request": "true",
                "service_id": serviceID,
                "service_name": serviceName
            ]
        )
        
        messages.append(diagnosisRequestMessage)
        
        LogInfo("[CommandRunner] AI 诊断请求已发送到主会话: \(serviceName)")
    }
    
    /// 发送系统通知
    private func sendSystemNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "macassistant-system-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                LogWarning("[CommandRunner] 发送系统通知失败: \(error.localizedDescription)")
            }
        }
    }
    
    /// 执行 AI 健康诊断（响应用户点击"立即诊断"）
    @MainActor
    func performAIHealthDiagnosis(serviceID: String) async {
        guard let service = ServiceManager.shared.services.first(where: { $0.id == serviceID }) else {
            return
        }
        
        isProcessing = true
        
        // 构建诊断提示词
        let prompt = """
        请帮我诊断服务「\(service.name)」的健康问题。
        
        服务配置：
        - 服务 ID: \(service.id)
        - 工作目录: \(service.metadata["path"] ?? "未指定")
        - 端口: \(service.port?.description ?? "无")
        - 启动命令: \(service.metadata["startCommand"] ?? "未配置")
        
        请按以下步骤执行诊断：
        1. 检查服务进程是否存在
        2. 检查端口是否监听
        3. 查看最近的日志文件（最近 100 行）
        4. 检查配置文件是否有错误
        5. 分析可能的原因并提供修复建议
        
        请以清晰的格式输出诊断报告。
        """
        
        // 发送到 AI
        let message = ChatMessage(
            id: UUID(),
            role: .user,
            content: prompt,
            timestamp: Date()
        )
        
        await MainActor.run {
            messages.append(message)
        }
        
        // 调用 AI 处理
        await processInput(prompt)
    }
    
    // MARK: - Context Injection Helpers
    
    /// 构建基础系统提示词
    private func buildBaseSystemPrompt() -> String {
        return """
        你是 MacAssistant，一个运行在 macOS 上的智能助手。
        
        重要能力：
        1. 你可以管理 MacAssistant 应用内部的服务（通过服务面板或命令）
        2. 你有记忆能力，可以记住对话历史
        3. 你可以帮助用户分析代码、文件、执行任务
        
        当用户询问"服务"时，通常指的是 MacAssistant 应用内部的服务状态，而不是系统级服务。
        """
    }
    
    /// 注入服务状态上下文到系统提示词
    @MainActor
    private func injectServiceContext(into basePrompt: String?) -> String {
        let serviceManager = ServiceManager.shared
        let stateStore = ServiceStateStore.shared
        
        // 获取所有服务状态
        let allServices = serviceManager.services
        let runningServices = stateStore.runningServices()
        
        guard !allServices.isEmpty else {
            return basePrompt ?? ""
        }
        
        // 构建服务状态描述
        var serviceContext = """
        
        【MacAssistant 服务状态】
        当前共有 \(allServices.count) 个服务，其中 \(runningServices.count) 个正在运行：
        
        """
        
        // 列出所有服务及其状态
        for service in allServices.sorted(by: { $0.name < $1.name }) {
            let state = stateStore.state(for: service.id)?.state
            let statusIcon: String
            let statusText: String
            
            switch state {
            case .running:
                statusIcon = "🟢"
                statusText = "运行中"
            case .starting:
                statusIcon = "🟡"
                statusText = "启动中"
            case .stopping:
                statusIcon = "🟠"
                statusText = "停止中"
            case .stopped, .notInstalled:
                statusIcon = "⚪"
                statusText = "已停止"
            case .error:
                statusIcon = "🔴"
                statusText = "错误"
            default:
                statusIcon = "⚪"
                statusText = "未启动"
            }
            
            serviceContext += "- \(statusIcon) \(service.name) (\(statusText))\n"
        }
        
        if !runningServices.isEmpty {
            serviceContext += "\n运行中的服务详情：\n"
            for service in runningServices {
                let port = service.port.map { ":\($0)" } ?? ""
                serviceContext += "- \(service.name)\(port)"
                if let adapter = service.adapter {
                    serviceContext += " [\(adapter)]"
                }
                serviceContext += "\n"
            }
        }
        
        serviceContext += "\n当用户询问服务状态时，请基于上述信息回答。"
        
        if let base = basePrompt, !base.isEmpty {
            return base + serviceContext
        } else {
            return "你是 MacAssistant 智能助手。" + serviceContext
        }
    }
}
