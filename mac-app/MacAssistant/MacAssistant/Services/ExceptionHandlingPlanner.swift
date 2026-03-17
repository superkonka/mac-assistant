//
//  ExceptionHandlingPlanner.swift
//  MacAssistant
//
//  方案C：异常处理规划器 - 让Planner驱动异常后的决策
//

import Foundation

/// 异常场景分析结果
struct ExceptionScenario {
    let type: ExceptionType
    let sessionID: String
    let originalRequest: String
    let partialResult: String?
    let error: Error
    let context: ExceptionContext
    
    enum ExceptionType {
        case streamInterrupted       // 流中断
        case timeout                 // 超时
        case agentFailure            // Agent失败
        case networkError            // 网络错误
        case serviceUnavailable      // 服务不可用
    }
    
    struct ExceptionContext {
        let hasPartialResult: Bool
        let isLongRunningTask: Bool  // 是否是长任务（部署、授权等）
        let hasBackgroundRecoveryScheduled: Bool
        let userIntent: UserContinuationIntent
    }
    
    enum UserContinuationIntent {
        case explicitContinue        // 用户明确说"继续"
        case implicitContinue        // 隐含继续意图
        case checkStatus             // 想检查状态
        case newRequest              // 新请求
        case unknown                 // 未知
    }
}

/// 异常处理决策
struct ExceptionHandlingDecision {
    let action: ExceptionHandlingAction
    let reasoning: String
    let confidence: Double
    let requiresUserConfirmation: Bool
    let estimatedTimeToResolution: TimeInterval?
    
    enum ExceptionHandlingAction {
        /// 立即自动恢复（高置信度场景）
        case autoRecoverNow
        /// 安排后台恢复（兜底）
        case scheduleBackgroundRecovery(delaySeconds: Int)
        /// 转为后台任务继续执行
        case convertToBackgroundTask
        /// 提示用户检查状态
        case promptCheckStatus
        /// 等待用户明确指令
        case waitForUserInput
        /// 提供恢复选项菜单
        case offerRecoveryOptions
    }
}

@MainActor
final class ExceptionHandlingPlanner {
    static let shared = ExceptionHandlingPlanner()
    
    private let backgroundRecovery = BackgroundTaskRecoveryService.shared
    private let statusChecker = TaskStatusChecker.shared
    private let executionAnalyzer = ExecutionAnalyzer.shared
    
    private init() {}
    
    // MARK: - 核心API
    
    /// 分析异常场景并决策（Planner驱动）
    func planExceptionHandling(
        error: Error,
        sessionID: String,
        originalRequest: String,
        partialResult: String?,
        recentUserInput: String?,
        taskCharacteristics: TaskCharacteristics
    ) -> ExceptionHandlingDecision {
        
        LogInfo("[ExceptionPlanner] 分析异常场景: session=\(sessionID), error=\(error.localizedDescription)")
        
        // 1. 识别异常类型
        let exceptionType = classifyException(error)
        
        // 2. 分析用户意图
        let userIntent = analyzeUserIntent(recentUserInput)
        
        // 3. 构建异常场景
        let scenario = ExceptionScenario(
            type: exceptionType,
            sessionID: sessionID,
            originalRequest: originalRequest,
            partialResult: partialResult,
            error: error,
            context: ExceptionScenario.ExceptionContext(
                hasPartialResult: partialResult != nil && !partialResult!.isEmpty,
                isLongRunningTask: taskCharacteristics.isLongRunning,
                hasBackgroundRecoveryScheduled: backgroundRecovery.getTaskStatus(sessionID: sessionID) != nil,
                userIntent: userIntent
            )
        )
        
        // 4. 根据场景决策
        return makeDecision(for: scenario)
    }
    
    // MARK: - 场景决策逻辑
    
    private func makeDecision(for scenario: ExceptionScenario) -> ExceptionHandlingDecision {
        switch scenario.type {
        case .streamInterrupted:
            return handleStreamInterrupted(scenario)
        case .timeout:
            return handleTimeout(scenario)
        case .agentFailure:
            return handleAgentFailure(scenario)
        case .networkError:
            return handleNetworkError(scenario)
        case .serviceUnavailable:
            return handleServiceUnavailable(scenario)
        }
    }
    
    /// 流中断处理策略
    private func handleStreamInterrupted(_ scenario: ExceptionScenario) -> ExceptionHandlingDecision {
        let ctx = scenario.context
        
        // 场景1：用户明确说"继续" → 立即恢复
        if ctx.userIntent == .explicitContinue {
            return ExceptionHandlingDecision(
                action: .autoRecoverNow,
                reasoning: "用户明确要求继续，且流中断通常可以恢复",
                confidence: 0.9,
                requiresUserConfirmation: false,
                estimatedTimeToResolution: 5
            )
        }
        
        // 场景2：有部分内容且是长任务 → 转为后台任务
        if ctx.hasPartialResult && ctx.isLongRunningTask {
            return ExceptionHandlingDecision(
                action: .convertToBackgroundTask,
                reasoning: "长任务已部分执行，转为后台继续不阻塞用户",
                confidence: 0.85,
                requiresUserConfirmation: false,
                estimatedTimeToResolution: 60
            )
        }
        
        // 场景3：用户想检查状态 → 提示检查
        if ctx.userIntent == .checkStatus {
            return ExceptionHandlingDecision(
                action: .promptCheckStatus,
                reasoning: "用户意图是检查状态而非立即继续",
                confidence: 0.8,
                requiresUserConfirmation: false,
                estimatedTimeToResolution: nil
            )
        }
        
        // 场景4：默认兜底 → 后台自动恢复 + 提供选项
        if !ctx.hasBackgroundRecoveryScheduled {
            return ExceptionHandlingDecision(
                action: .scheduleBackgroundRecovery(delaySeconds: 10),
                reasoning: "自动安排后台恢复作为兜底，同时提示用户可以手动继续",
                confidence: 0.75,
                requiresUserConfirmation: false,
                estimatedTimeToResolution: 15
            )
        }
        
        // 场景5：已有后台恢复 → 提供选项菜单
        return ExceptionHandlingDecision(
            action: .offerRecoveryOptions,
            reasoning: "后台恢复已安排，提供多种恢复选项供用户选择",
            confidence: 0.7,
            requiresUserConfirmation: true,
            estimatedTimeToResolution: nil
        )
    }
    
    /// 超时处理策略
    private func handleTimeout(_ scenario: ExceptionScenario) -> ExceptionHandlingDecision {
        if scenario.context.isLongRunningTask {
            return ExceptionHandlingDecision(
                action: .convertToBackgroundTask,
                reasoning: "长任务超时，转为后台执行避免阻塞",
                confidence: 0.8,
                requiresUserConfirmation: false,
                estimatedTimeToResolution: 120
            )
        }
        
        return ExceptionHandlingDecision(
            action: .autoRecoverNow,
            reasoning: "普通任务超时，尝试立即重试",
            confidence: 0.6,
            requiresUserConfirmation: false,
            estimatedTimeToResolution: 10
        )
    }
    
    /// Agent失败处理
    private func handleAgentFailure(_ scenario: ExceptionScenario) -> ExceptionHandlingDecision {
        ExceptionHandlingDecision(
            action: .offerRecoveryOptions,
            reasoning: "Agent失败，建议切换Agent或检查配置",
            confidence: 0.7,
            requiresUserConfirmation: true,
            estimatedTimeToResolution: nil
        )
    }
    
    /// 网络错误处理
    private func handleNetworkError(_ scenario: ExceptionScenario) -> ExceptionHandlingDecision {
        ExceptionHandlingDecision(
            action: .scheduleBackgroundRecovery(delaySeconds: 30),
            reasoning: "网络错误，稍后自动重试",
            confidence: 0.6,
            requiresUserConfirmation: false,
            estimatedTimeToResolution: 35
        )
    }
    
    /// 服务不可用处理
    private func handleServiceUnavailable(_ scenario: ExceptionScenario) -> ExceptionHandlingDecision {
        ExceptionHandlingDecision(
            action: .waitForUserInput,
            reasoning: "服务不可用，需要用户决定是否重试或切换服务",
            confidence: 0.5,
            requiresUserConfirmation: true,
            estimatedTimeToResolution: nil
        )
    }
    
    // MARK: - 执行决策
    
    func executeDecision(
        _ decision: ExceptionHandlingDecision,
        scenario: ExceptionScenario,
        runner: CommandRunner
    ) async {
        LogInfo("[ExceptionPlanner] 执行决策: \(decision.action), 理由: \(decision.reasoning)")
        
        switch decision.action {
        case .autoRecoverNow:
            await executeAutoRecover(scenario, runner: runner)
            
        case .scheduleBackgroundRecovery(let delay):
            backgroundRecovery.scheduleRecovery(
                sessionID: scenario.sessionID,
                originalRequest: scenario.originalRequest,
                delaySeconds: delay
            )
            notifyUserBackgroundRecoveryScheduled(scenario, delay: delay)
            
        case .convertToBackgroundTask:
            await convertToBackgroundTask(scenario, runner: runner)
            
        case .promptCheckStatus:
            notifyUserCheckStatusPrompt(scenario)
            
        case .waitForUserInput:
            notifyUserWaitingForInput(scenario)
            
        case .offerRecoveryOptions:
            presentRecoveryOptions(scenario)
        }
    }
    
    // MARK: - 执行具体策略
    
    private func executeAutoRecover(_ scenario: ExceptionScenario, runner: CommandRunner) async {
        // 触发智能恢复 - 简化实现
        LogInfo("[ExceptionPlanner] 执行自动恢复: \(scenario.sessionID)")
        // 实际恢复逻辑通过Notification通知外部处理
        NotificationCenter.default.post(
            name: NSNotification.Name("ExceptionAutoRecoverRequested"),
            object: scenario.sessionID,
            userInfo: ["originalRequest": scenario.originalRequest]
        )
    }
    
    private func convertToBackgroundTask(_ scenario: ExceptionScenario, runner: CommandRunner) async {
        // 安排后台恢复
        backgroundRecovery.scheduleRecovery(
            sessionID: scenario.sessionID,
            originalRequest: scenario.originalRequest,
            delaySeconds: 5
        )
        
        // 通知用户
        NotificationCenter.default.post(
            name: NSNotification.Name("ExceptionConvertedToBackground"),
            object: scenario.sessionID,
            userInfo: ["message": "任务已转为后台继续执行"]
        )
    }
    
    // MARK: - 用户通知
    
    private func notifyUserBackgroundRecoveryScheduled(_ scenario: ExceptionScenario, delay: Int) {
        NotificationCenter.default.post(
            name: NSNotification.Name("ExceptionRecoveryScheduled"),
            object: scenario.sessionID,
            userInfo: [
                "delay": delay,
                "message": "任务将在\(delay)秒后自动尝试恢复"
            ]
        )
    }
    
    private func notifyUserCheckStatusPrompt(_ scenario: ExceptionScenario) {
        NotificationCenter.default.post(
            name: NSNotification.Name("ExceptionCheckStatusPrompt"),
            object: scenario.sessionID,
            userInfo: [
                "message": "任务已暂停，点击「检查状态」查看当前进展"
            ]
        )
    }
    
    private func notifyUserWaitingForInput(_ scenario: ExceptionScenario) {
        NotificationCenter.default.post(
            name: NSNotification.Name("ExceptionWaitForInput"),
            object: scenario.sessionID,
            userInfo: [
                "message": "请告诉我你希望如何处理这个问题"
            ]
        )
    }
    
    private func presentRecoveryOptions(_ scenario: ExceptionScenario) {
        NotificationCenter.default.post(
            name: NSNotification.Name("ExceptionRecoveryOptions"),
            object: scenario.sessionID,
            userInfo: [
                "options": [
                    "立即继续",
                    "后台自动恢复",
                    "检查状态",
                    "重新开始"
                ]
            ]
        )
    }
    
    // MARK: - 辅助方法
    
    private func classifyException(_ error: Error) -> ExceptionScenario.ExceptionType {
        if UserFacingErrorFormatter.isStreamInterruptedError(error) {
            return .streamInterrupted
        } else if UserFacingErrorFormatter.isTransientServiceError(error) {
            return .serviceUnavailable
        }
        
        let description = error.localizedDescription.lowercased()
        if description.contains("timeout") {
            return .timeout
        } else if description.contains("network") || description.contains("connection") {
            return .networkError
        }
        
        return .agentFailure
    }
    
    private func analyzeUserIntent(_ input: String?) -> ExceptionScenario.UserContinuationIntent {
        guard let input = input else { return .unknown }
        
        let normalized = input.lowercased()
        
        let continueKeywords = ["继续", "接着", "跟进", "完成", "恢复"]
        if continueKeywords.contains(where: normalized.contains) {
            return .explicitContinue
        }
        
        let checkKeywords = ["状态", "进度", "怎么样了", "如何"]
        if checkKeywords.contains(where: normalized.contains) {
            return .checkStatus
        }
        
        return .unknown
    }
}

// MARK: - 任务特征

struct TaskCharacteristics {
    let isLongRunning: Bool
    let estimatedDuration: TimeInterval?
    let requiresUserInteraction: Bool
    let hasSideEffects: Bool  // 是否有副作用（如部署、文件操作等）
}
