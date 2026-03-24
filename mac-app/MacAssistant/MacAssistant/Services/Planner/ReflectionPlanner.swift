//
//  ReflectionPlanner.swift
//  MacAssistant
//
//  反思规划器 - 定时复盘 workflow 状态并决策
//

import Foundation

@MainActor
final class ReflectionPlanner {
    static let shared = ReflectionPlanner()
    
    private let coordinator = WorkflowRunCoordinator.shared
    private let checkpointStore = PlannerCheckpointStore.shared
    
    // 配置阈值
    private let lowConfidenceThreshold = 0.6
    private let longBlockedThreshold: TimeInterval = 300  // 5分钟
    private let highValueThreshold = 0.8
    
    private init() {}
    
    // MARK: - 主入口
    
    /// 对指定 workflow run 进行反思
    func reflect(
        runID: String,
        trigger: PlannerCheckpoint.WakeUpTrigger,
        context: ReflectionContext
    ) async -> ReflectionDecision {
        LogInfo("[ReflectionPlanner] 开始反思 Run: \(runID), Trigger: \(trigger.rawValue)")
        
        guard let runState = coordinator.runState(runID: runID) else {
            LogError("[ReflectionPlanner] 找不到 Run: \(runID)")
            return .noop
        }
        
        // 收集上下文
        let reflectionContext = buildReflectionContext(runID: runID, runState: runState, additionalContext: context)
        
        // 根据触发器类型选择决策策略
        let decision: ReflectionDecision
        
        switch trigger {
        case .browserPageChanged, .newMessageReceived, .taskFailed, .serviceStatusChanged, .userAction:
            decision = await handleEventDriven(trigger: trigger, context: reflectionContext)
            
        case .periodicLightCheck:
            decision = await handlePeriodicCheck(context: reflectionContext)
            
        case .lowConfidence:
            decision = await handleLowConfidence(context: reflectionContext)
            
        case .highRiskAction:
            decision = await handleHighRiskAction(context: reflectionContext)
            
        case .longBlocked:
            decision = await handleLongBlocked(context: reflectionContext)
            
        case .highValueOpportunity:
            decision = await handleHighValueOpportunity(context: reflectionContext)
            
        case .manual:
            decision = await handleManualTrigger(context: reflectionContext)
        }
        
        // 记录检查点
        let checkpoint = PlannerCheckpoint(
            plannerType: .reflection,
            workflowRunID: runID,
            previousDecision: runState.blockingReason?.displayMessage,
            newDecision: decision.actionDescription,
            reason: "Trigger: \(trigger.rawValue)",
            confidence: estimateConfidence(for: decision),
            trigger: trigger,
            contextSummary: reflectionContext.summary,
            modelUsed: "reflection-heuristic",  // 实际应使用 LLM
            tokensConsumed: 0,
            latencyMs: 0
        )
        checkpointStore.record(checkpoint)
        
        LogInfo("[ReflectionPlanner] 反思完成: \(decision.actionDescription)")
        
        return decision
    }
    
    // MARK: - 决策策略
    
    private func handleEventDriven(
        trigger: PlannerCheckpoint.WakeUpTrigger,
        context: ReflectionContext
    ) async -> ReflectionDecision {
        LogInfo("[ReflectionPlanner] 处理事件驱动: \(trigger.rawValue)")
        
        // 事件驱动通常需要立即响应
        switch trigger {
        case .taskFailed:
            if let error = context.lastError, error.isRetryable {
                return .resume("任务失败但可重试")
            } else {
                return .escalate("任务失败且不可重试")
            }
            
        case .browserPageChanged:
            // 检查是否需要用户关注
            if context.isWaitingUser {
                return .remind("浏览器页面已更新，请检查", .medium)
            }
            return .noop
            
        case .newMessageReceived:
            return .remind("收到新消息，可能需要处理", .medium)
            
        case .serviceStatusChanged:
            return .replan("服务状态变化，需要重新规划")
            
        default:
            return .noop
        }
    }
    
    private func handlePeriodicCheck(context: ReflectionContext) async -> ReflectionDecision {
        LogInfo("[ReflectionPlanner] 处理周期巡检")
        
        // 检查阻塞状态
        if context.isBlocked {
            if let blockedDuration = context.blockedDuration, blockedDuration > longBlockedThreshold {
                return .remind("Workflow 已阻塞 \(Int(blockedDuration/60)) 分钟", .high)
            }
            return .noop
        }
        
        // 检查进度
        if context.progress < 0.3 && context.elapsedTime > 600 {
            // 进度缓慢
            return .remind("Workflow 进度较慢，请关注", .low)
        }
        
        return .noop
    }
    
    private func handleLowConfidence(context: ReflectionContext) async -> ReflectionDecision {
        LogInfo("[ReflectionPlanner] 处理低置信度")
        return .escalate("AI 对当前决策置信度较低，建议人工确认")
    }
    
    private func handleHighRiskAction(context: ReflectionContext) async -> ReflectionDecision {
        LogInfo("[ReflectionPlanner] 处理高风险操作")
        
        // 高风险操作需要确认
        if let pendingApproval = context.pendingApproval {
            return .remind("高风险操作等待审批: \(pendingApproval.stepName)", .critical)
        }
        
        return .escalate("检测到高风险操作，建议人工审核")
    }
    
    private func handleLongBlocked(context: ReflectionContext) async -> ReflectionDecision {
        LogInfo("[ReflectionPlanner] 处理长期阻塞")
        
        guard let reason = context.blockingReason else {
            return .resume("阻塞已解除")
        }
        
        switch reason {
        case .waitingUser:
            return .remind("Workflow 等待用户输入", .high)
        case .waitingExternal:
            return .replan("外部依赖超时，尝试替代方案")
        case .waitingApproval:
            return .remind("Workflow 等待审批", .critical)
        case .error(let message, let retryable):
            if retryable {
                return .resume("错误已恢复，继续执行")
            } else {
                return .escalate("不可恢复错误: \(message)")
            }
        default:
            return .noop
        }
    }
    
    private func handleHighValueOpportunity(context: ReflectionContext) async -> ReflectionDecision {
        LogInfo("[ReflectionPlanner] 处理高价值机会")
        return .replan("发现高价值机会，优化执行策略")
    }
    
    private func handleManualTrigger(context: ReflectionContext) async -> ReflectionDecision {
        LogInfo("[ReflectionPlanner] 处理手动触发")
        return .replan("用户手动触发反思")
    }
    
    // MARK: - 上下文构建
    
    private func buildReflectionContext(
        runID: String,
        runState: WorkflowRunState,
        additionalContext: ReflectionContext
    ) -> ReflectionContext {
        var context = additionalContext
        context.runID = runID
        context.definitionID = runState.definitionID
        context.isBlocked = runState.isBlocked
        context.blockingReason = runState.blockingReason
        context.progress = runState.progress
        context.pendingApproval = runState.pendingApproval
        context.elapsedTime = elapsedTime(for: runState)
        context.blockedDuration = blockedDuration(for: runState)
        context.isWaitingUser = isWaitingUser(runState.blockingReason) || runState.pendingApproval != nil
        context.lastError = runState.stepRuns.last(where: { $0.error != nil })?.error
        
        if let lastCheckpoint = runState.checkpoints.last {
            context.lastCheckpoint = lastCheckpoint
        }

        if context.summary.isEmpty {
            context.summary = summary(for: runState)
        }
        
        return context
    }
    
    // MARK: - 辅助方法
    
    private func estimateConfidence(for decision: ReflectionDecision) -> Double {
        switch decision {
        case .noop:
            return 0.9
        case .resume:
            return 0.8
        case .replan:
            return 0.7
        case .remind(_, let priority):
            switch priority {
            case .low: return 0.7
            case .medium: return 0.8
            case .high: return 0.9
            case .critical: return 0.95
            }
        case .escalate:
            return 0.6
        }
    }

    private func elapsedTime(for runState: WorkflowRunState) -> TimeInterval {
        let startDate = runState.checkpoints.first?.timestamp
            ?? runState.stepRuns.first?.startedAt
            ?? Date()
        return Date().timeIntervalSince(startDate)
    }

    private func blockedDuration(for runState: WorkflowRunState) -> TimeInterval? {
        guard runState.isBlocked else { return nil }

        if let blockingCheckpoint = runState.checkpoints.last(where: {
            switch $0.kind {
            case .approvalRequested, .stepFailed, .replanRequested, .replanExecuted:
                return true
            case .stepStarted, .stepCompleted, .approvalGranted, .approvalDenied, .reflectionTriggered, .reminderSent, .escalated:
                return false
            }
        }) {
            return Date().timeIntervalSince(blockingCheckpoint.timestamp)
        }

        if let currentStepStart = runState.currentStepRun?.startedAt {
            return Date().timeIntervalSince(currentStepStart)
        }

        return nil
    }

    private func isWaitingUser(_ reason: WorkflowBlockingReason?) -> Bool {
        guard let reason else { return false }

        switch reason {
        case .waitingUser, .waitingApproval:
            return true
        case .waitingExternal, .error, .maxRetriesExceeded, .paused:
            return false
        }
    }

    private func summary(for runState: WorkflowRunState) -> String {
        let activeStep = runState.activeStepID ?? "无活动步骤"
        let progress = Int((runState.progress * 100).rounded())

        if let blockingReason = runState.blockingReason {
            return "当前步骤: \(activeStep)，进度 \(progress)%，状态: \(blockingReason.displayMessage)"
        }

        return "当前步骤: \(activeStep)，进度 \(progress)%"
    }
}

// MARK: - Reflection Context

/// 反思上下文
struct ReflectionContext {
    var runID: String?
    var definitionID: String?
    var isBlocked: Bool = false
    var blockingReason: WorkflowBlockingReason?
    var progress: Double = 0
    var elapsedTime: TimeInterval = 0
    var blockedDuration: TimeInterval?
    var isWaitingUser: Bool = false
    var pendingApproval: PendingApproval?
    var lastError: StepRunError?
    var lastCheckpoint: WorkflowCheckpoint?
    var summary: String = ""
    
    init() {}
    
    init(runID: String, summary: String) {
        self.runID = runID
        self.summary = summary
    }
}
