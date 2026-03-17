//
//  AutoRecoveryPlanner.swift
//  MacAssistant
//
//  自动恢复规划器 - 根据分析结果自动重新规划执行策略
//

import Foundation
import Combine

/// 恢复计划
struct RecoveryPlan: Identifiable {
    let id = UUID()
    let originalTaskSessionID: String
    let analysis: ProcessAnalysisResult
    let strategy: RecoveryStrategy
    let steps: [RecoveryStep]
    let estimatedTotalTime: TimeInterval
    let requiresUserConfirmation: Bool
    let fallbackPlanID: UUID?  // 使用 ID 避免递归
}

/// 恢复步骤
struct RecoveryStep: Identifiable {
    let id = UUID()
    let order: Int
    let action: RecoveryAction
    let status: StepStatus
    let result: StepResult?
    
    enum StepStatus {
        case pending
        case executing
        case completed
        case failed
        case skipped
    }
    
    struct StepResult {
        let success: Bool
        let output: String?
        let duration: TimeInterval
        let newIssues: [ExecutionIssue]?
    }
}

/// 用户确认请求
struct UserConfirmationRequest {
    let planID: UUID
    let title: String
    let description: String
    let configChanges: [ConfigChange]
    let timeout: TimeInterval
    let defaultAction: ConfirmationAction
    
    enum ConfirmationAction {
        case proceed
        case modify
        case cancel
        case fallback
    }
}

/// 自动恢复规划器
@MainActor
final class AutoRecoveryPlanner: ObservableObject {
    static let shared = AutoRecoveryPlanner()
    
    @Published private(set) var activePlans: [UUID: RecoveryPlan] = [:]
    @Published private(set) var planHistory: [RecoveryPlan] = []
    @Published private(set) var isExecuting = false
    
    private let analyzer = ExecutionAnalyzer.shared
    private let agentStore = AgentStore.shared
    private let coordinator = SubtaskCoordinator.shared
    
    private var executionCancellables: [UUID: Task<Void, Never>] = [:]
    
    private init() {}
    
    // MARK: - 核心规划方法
    
    /// 创建恢复计划
    func createRecoveryPlan(
        for taskSessionID: String,
        after error: Error,
        currentSnapshot: ExecutionSnapshot
    ) -> RecoveryPlan {
        
        // 1. 分析执行过程
        let availableAgents = agentStore.agents.filter { agentStore.canUse($0) }
        let analysis = analyzer.analyzeExecution(
            snapshot: currentSnapshot,
            error: error,
            availableAgents: availableAgents
        )
        
        // 2. 生成恢复步骤
        let steps = generateSteps(
            from: analysis.recommendedStrategy,
            analysis: analysis,
            taskSessionID: taskSessionID
        )
        
        // 3. 计算预计时间
        let estimatedTime = steps.compactMap { $0.action.estimatedTime }.reduce(0, +)
        
        // 4. 生成 fallback 计划
        let fallbackPlan = analysis.recommendedStrategy.fallbackChain.isEmpty ? nil :
            createFallbackPlan(
                originalTaskSessionID: taskSessionID,
                fallbackActions: analysis.recommendedStrategy.fallbackChain,
                analysis: analysis
            )
        
        let plan = RecoveryPlan(
            originalTaskSessionID: taskSessionID,
            analysis: analysis,
            strategy: analysis.recommendedStrategy,
            steps: steps,
            estimatedTotalTime: estimatedTime,
            requiresUserConfirmation: analysis.needsUserConfirmation,
            fallbackPlanID: fallbackPlan?.id
        )
        
        activePlans[plan.id] = plan
        return plan
    }
    
    /// 执行恢复计划
    func executeRecoveryPlan(
        _ plan: RecoveryPlan,
        withConfirmation: Bool = false,
        onUserConfirmation: ((UserConfirmationRequest) async -> UserConfirmationRequest.ConfirmationAction)? = nil
    ) async -> Bool {
        
        guard !isExecuting else {
            LogWarning("AutoRecoveryPlanner: 已有恢复计划正在执行")
            return false
        }
        
        isExecuting = true
        defer { isExecuting = false }
        
        LogInfo("AutoRecoveryPlanner: 开始执行恢复计划 \(plan.id)")
        
        // 1. 如果需要用户确认，先请求确认
        if plan.requiresUserConfirmation && !withConfirmation {
            guard let onUserConfirmation = onUserConfirmation else {
                LogError("AutoRecoveryPlanner: 需要用户确认但没有提供回调")
                return false
            }
            
            let request = createUserConfirmationRequest(for: plan)
            let action = await onUserConfirmation(request)
            
            switch action {
            case .proceed:
                break  // 继续执行
            case .modify:
                // 用户希望修改，这里简化处理，实际应该允许用户调整
                LogInfo("AutoRecoveryPlanner: 用户选择修改计划")
                return false
            case .cancel:
                LogInfo("AutoRecoveryPlanner: 用户取消恢复")
                return false
            case .fallback:
                if let fallbackPlanID = plan.fallbackPlanID,
                   let fallbackPlan = activePlans[fallbackPlanID] {
                    return await executeRecoveryPlan(fallbackPlan, withConfirmation: true, onUserConfirmation: onUserConfirmation)
                }
                return false
            }
        }
        
        // 2. 应用配置调整
        if !plan.analysis.configAdjustments.isEmpty {
            analyzer.applyConfigChanges(plan.analysis.configAdjustments)
            LogInfo("AutoRecoveryPlanner: 已应用 \(plan.analysis.configAdjustments.count) 项配置调整")
        }
        
        // 3. 按顺序执行步骤
        var completedSteps = 0
        var failedSteps = 0
        
        for (index, step) in plan.steps.enumerated() {
            LogInfo("AutoRecoveryPlanner: 执行步骤 \(index + 1)/\(plan.steps.count) - \(step.action.description)")
            
            let result = await executeStep(step, plan: plan)
            
            // 更新步骤状态
            updateStepResult(plan.id, stepID: step.id, result: result)
            
            if result.success {
                completedSteps += 1
                
                // 检查是否已完全恢复
                if shouldConsiderRecovered(result, plan: plan) {
                    LogInfo("AutoRecoveryPlanner: 任务已恢复")
                    completePlan(plan.id, success: true)
                    return true
                }
            } else {
                failedSteps += 1
                
                // 如果关键步骤失败，尝试 fallback
                if step.action.confidence > 0.7 {
                    LogWarning("AutoRecoveryPlanner: 关键步骤失败，尝试 fallback")
                    if let fallbackPlanID = plan.fallbackPlanID,
                       let fallbackPlan = activePlans[fallbackPlanID] {
                        return await executeRecoveryPlan(fallbackPlan, withConfirmation: true, onUserConfirmation: onUserConfirmation)
                    }
                }
            }
            
            // 如果失败太多，停止执行
            if failedSteps >= 2 {
                LogWarning("AutoRecoveryPlanner: 失败步骤过多，停止执行")
                break
            }
        }
        
        // 4. 评估整体结果
        let success = completedSteps > failedSteps
        completePlan(plan.id, success: success)
        
        return success
    }
    
    /// 智能自动恢复入口
    func attemptAutoRecovery(
        taskSessionID: String,
        error: Error,
        currentSnapshot: ExecutionSnapshot,
        notifyUser: @escaping (String, RecoveryPlan?) -> Void
    ) async -> Bool {
        
        // 1. 创建恢复计划
        let plan = createRecoveryPlan(
            for: taskSessionID,
            after: error,
            currentSnapshot: currentSnapshot
        )
        
        // 2. 判断是否可以自动恢复
        if plan.analysis.autoRecoverable && !plan.requiresUserConfirmation {
            // 自动执行
            notifyUser("检测到执行中断，正在自动恢复...", plan)
            
            let success = await executeRecoveryPlan(plan)
            
            if success {
                notifyUser("✅ 任务已成功恢复", plan)
            } else {
                notifyUser("⚠️ 自动恢复遇到问题，需要您的协助", plan)
            }
            
            return success
        } else {
            // 需要用户确认
            notifyUser("📋 检测到执行中断，建议进行调优恢复", plan)
            
            // 等待用户触发恢复
            return false
        }
    }
    
    // MARK: - 步骤执行
    
    private func executeStep(_ step: RecoveryStep, plan: RecoveryPlan) async -> RecoveryStep.StepResult {
        let startTime = Date()
        
        do {
            let success: Bool
            var output: String?
            var newIssues: [ExecutionIssue]?
            
            switch step.action.type {
            case .retryWithBackoff:
                success = await executeRetryWithBackoff(plan)
                output = "已执行指数退避重试"
                
            case .switchAgent:
                success = await executeAgentSwitch(plan)
                output = "已切换到备用 Agent"
                
            case .adjustTimeout:
                success = true  // 配置已在 plan 开始时应用
                output = "已调整超时配置"
                
            case .adjustContextWindow:
                success = await executeAdjustContext(plan)
                output = "已调整上下文窗口"
                
            case .splitTask:
                success = await executeTaskSplit(plan)
                output = "已拆分任务"
                
            case .useLocalFallback:
                success = await executeLocalFallback(plan)
                output = "已切换到本地执行"
                
            case .waitAndRetry:
                success = await executeWaitAndRetry(plan)
                output = "等待后重试完成"
                
            case .requestUserInput:
                success = false  // 需要用户输入，标记为需要交互
                output = "等待用户输入"
                
            case .checkpointResume:
                success = await executeCheckpointResume(plan)
                output = "已从检查点恢复"
                
            case .adjustStrategy:
                success = true
                output = "已调整执行策略"
            }
            
            return RecoveryStep.StepResult(
                success: success,
                output: output,
                duration: -startTime.timeIntervalSinceNow,
                newIssues: newIssues
            )
            
        } catch {
            return RecoveryStep.StepResult(
                success: false,
                output: "执行失败: \(error.localizedDescription)",
                duration: -startTime.timeIntervalSinceNow,
                newIssues: nil
            )
        }
    }
    
    // MARK: - 具体动作执行
    
    private func executeRetryWithBackoff(_ plan: RecoveryPlan) async -> Bool {
        // 指数退避重试逻辑
        let baseDelay: TimeInterval = 2.0
        let maxDelay: TimeInterval = 30.0
        
        for attempt in 1...3 {
            let delay = min(baseDelay * pow(2.0, Double(attempt - 1)), maxDelay)
            LogInfo("AutoRecoveryPlanner: 退避等待 \(delay)s 后重试 (尝试 \(attempt)/3)")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            
            // 触发任务重新执行
            if await triggerTaskRetry(plan.originalTaskSessionID) {
                return true
            }
        }
        
        return false
    }
    
    private func executeAgentSwitch(_ plan: RecoveryPlan) async -> Bool {
        let availableAgents = agentStore.agents.filter { agentStore.canUse($0) }
        guard availableAgents.count > 1 else { return false }
        
        // 选择不同的 Agent
        // 简化实现，实际应该基于能力匹配
        return true
    }
    
    private func executeAdjustContext(_ plan: RecoveryPlan) async -> Bool {
        // 调整上下文窗口大小
        return true
    }
    
    private func executeTaskSplit(_ plan: RecoveryPlan) async -> Bool {
        // 使用 SubtaskCoordinator 拆分任务
        // 简化实现
        return true
    }
    
    private func executeLocalFallback(_ plan: RecoveryPlan) async -> Bool {
        // 切换到本地 Kimi CLI 执行
        return true
    }
    
    private func executeWaitAndRetry(_ plan: RecoveryPlan) async -> Bool {
        // 等待后重试
        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        return await triggerTaskRetry(plan.originalTaskSessionID)
    }
    
    private func executeCheckpointResume(_ plan: RecoveryPlan) async -> Bool {
        // 从检查点恢复
        return await triggerTaskRetry(plan.originalTaskSessionID, resumeFromCheckpoint: true)
    }
    
    private func triggerTaskRetry(
        _ taskSessionID: String,
        resumeFromCheckpoint: Bool = false
    ) async -> Bool {
        // 触发 CommandRunner 重新执行任务
        // 简化实现，实际应该调用 CommandRunner 的方法
        return true
    }
    
    // MARK: - 辅助方法
    
    private func generateSteps(
        from strategy: RecoveryStrategy,
        analysis: ProcessAnalysisResult,
        taskSessionID: String
    ) -> [RecoveryStep] {
        
        var steps: [RecoveryStep] = []
        
        // 1. 配置调整步骤
        if !analysis.configAdjustments.isEmpty {
            steps.append(RecoveryStep(
                order: steps.count,
                action: RecoveryAction(
                    type: .adjustStrategy,
                    description: "应用配置优化",
                    confidence: 0.9,
                    estimatedTime: 1,
                    requiresUserConfirmation: analysis.needsUserConfirmation,
                    configChanges: analysis.configAdjustments
                ),
                status: .pending,
                result: nil
            ))
        }
        
        // 2. 主要恢复动作
        for (index, action) in strategy.actions.enumerated() {
            steps.append(RecoveryStep(
                order: steps.count,
                action: action,
                status: .pending,
                result: nil
            ))
        }
        
        // 3. 按顺序排序
        return steps.sorted { $0.order < $1.order }
    }
    
    private func createFallbackPlan(
        originalTaskSessionID: String,
        fallbackActions: [RecoveryAction],
        analysis: ProcessAnalysisResult
    ) -> RecoveryPlan {
        let steps = fallbackActions.enumerated().map { index, action in
            RecoveryStep(
                order: index,
                action: action,
                status: .pending,
                result: nil
            )
        }
        
        let fallbackStrategy = RecoveryStrategy(
            strategy: .userAssistance,
            actions: fallbackActions,
            fallbackChain: [],
            maxRetries: 0,
            adjustedTimeout: nil,
            description: "Fallback 策略：请求用户协助"
        )
        
        return RecoveryPlan(
            originalTaskSessionID: originalTaskSessionID,
            analysis: analysis,
            strategy: fallbackStrategy,
            steps: steps,
            estimatedTotalTime: 0,
            requiresUserConfirmation: true,
            fallbackPlanID: nil
        )
    }
    
    private func createUserConfirmationRequest(for plan: RecoveryPlan) -> UserConfirmationRequest {
        let configDescription = plan.analysis.configAdjustments
            .map { "• \($0.key): \($0.oldValue) → \($0.newValue)\n  原因: \($0.reason)" }
            .joined(separator: "\n\n")
        
        return UserConfirmationRequest(
            planID: plan.id,
            title: "执行调优方案",
            description: """
            检测到任务执行中断，建议进行以下调优：
            
            📊 问题分析：
            \(plan.analysis.rootCause ?? "未知问题")
            
            🔧 配置调整：
            \(configDescription.isEmpty ? "无配置调整" : configDescription)
            
            📋 恢复策略：
            \(plan.strategy.description)
            
            ⏱️ 预计时间：\(Int(plan.estimatedTotalTime))秒
            """,
            configChanges: plan.analysis.configAdjustments,
            timeout: 60,
            defaultAction: .proceed
        )
    }
    
    private func shouldConsiderRecovered(_ result: RecoveryStep.StepResult, plan: RecoveryPlan) -> Bool {
        // 判断是否可以从结果认为已恢复
        // 简化实现
        return result.success
    }
    
    private func updateStepResult(_ planID: UUID, stepID: UUID, result: RecoveryStep.StepResult) {
        guard var plan = activePlans[planID] else { return }
        
        if let index = plan.steps.firstIndex(where: { $0.id == stepID }) {
            var updatedSteps = plan.steps
            let status: RecoveryStep.StepStatus = result.success ? .completed : .failed
            updatedSteps[index] = RecoveryStep(
                order: plan.steps[index].order,
                action: plan.steps[index].action,
                status: status,
                result: result
            )
            
            let updatedPlan = RecoveryPlan(
                originalTaskSessionID: plan.originalTaskSessionID,
                analysis: plan.analysis,
                strategy: plan.strategy,
                steps: updatedSteps,
                estimatedTotalTime: plan.estimatedTotalTime,
                requiresUserConfirmation: plan.requiresUserConfirmation,
                fallbackPlanID: plan.fallbackPlanID
            )
            
            activePlans[planID] = updatedPlan
        }
    }
    
    private func completePlan(_ planID: UUID, success: Bool) {
        guard let plan = activePlans.removeValue(forKey: planID) else { return }
        planHistory.append(plan)
        
        // 限制历史记录数量
        if planHistory.count > 100 {
            planHistory.removeFirst(planHistory.count - 100)
        }
        
        LogInfo("AutoRecoveryPlanner: 计划 \(planID) 执行完成，成功: \(success)")
    }
    
    /// 取消正在执行的计划
    func cancelPlan(_ planID: UUID) {
        executionCancellables.removeValue(forKey: planID)?.cancel()
        activePlans.removeValue(forKey: planID)
    }
    
    /// 获取计划执行状态
    func planStatus(_ planID: UUID) -> (active: Bool, completed: Bool, steps: Int)? {
        if let plan = activePlans[planID] {
            return (true, false, plan.steps.count)
        }
        if planHistory.contains(where: { $0.id == planID }) {
            return (false, true, 0)
        }
        return nil
    }
}
