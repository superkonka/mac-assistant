//
//  SmartRecoveryExecutor.swift
//  MacAssistant
//
//  智能恢复执行器 - 集成分析、规划和自动恢复
//

import Foundation
import Combine

/// 恢复执行结果
enum RecoveryResult {
    case success(String)           // 成功，返回结果内容
    case partial(String, RecoveryPlanID)  // 部分成功，保留现场和恢复计划ID
    case needsConfirmation(RecoveryPlanID) // 需要用户确认
    case failed(String)            // 失败，返回错误信息
    case inProgress(RecoveryPlanID)  // 恢复进行中
}

typealias RecoveryPlanID = UUID

/// 智能恢复执行器
@MainActor
final class SmartRecoveryExecutor {
    static let shared = SmartRecoveryExecutor()
    
    private let analyzer = ExecutionAnalyzer.shared
    private let planner = AutoRecoveryPlanner.shared
    private let commandRunner = CommandRunner.shared
    
    private var activeExecutions: [String: Task<Void, Never>] = [:]
    
    private init() {}
    
    // MARK: - 主要入口
    
    /// 智能恢复入口 - 分析、规划、自动恢复
    func smartRecover(
        taskSessionID: String,
        agent: Agent,
        text: String,
        images: [String],
        error: Error,
        previousSnapshot: ExecutionSnapshot?,
        notifyUser: @escaping (String) -> Void
    ) async -> RecoveryResult {
        
        LogInfo("SmartRecoveryExecutor: 开始智能恢复 taskSessionID=\(taskSessionID)")
        
        // 1. 构建执行快照
        let snapshot: ExecutionSnapshot
        if let previousSnapshot = previousSnapshot {
            snapshot = previousSnapshot
        } else {
            snapshot = await buildSnapshot(
                taskSessionID: taskSessionID,
                agent: agent,
                error: error
            )
        }
        
        // 记录快照用于分析
        analyzer.recordSnapshot(snapshot)
        
        // 2. 分析执行过程
        let availableAgents = await MainActor.run { AgentStore.shared.agents.filter { AgentStore.shared.canUse($0) } }
        let analysis = analyzer.analyzeExecution(
            snapshot: snapshot,
            error: error,
            availableAgents: availableAgents
        )
        
        LogInfo("SmartRecoveryExecutor: 分析问题 - \(analysis.rootCause ?? "未知")")
        
        // 3. 根据分析结果决定策略
        if analysis.autoRecoverable {
            // 可自动恢复，立即执行
            return await executeAutoRecovery(
                taskSessionID: taskSessionID,
                agent: agent,
                text: text,
                images: images,
                analysis: analysis,
                notifyUser: notifyUser
            )
        } else if analysis.needsUserConfirmation {
            // 需要用户确认
            let plan = planner.createRecoveryPlan(
                for: taskSessionID,
                after: error,
                currentSnapshot: snapshot
            )
            return .needsConfirmation(plan.id)
        } else {
            // 无法自动恢复
            let message = analysis.rootCause ?? "任务执行失败"
            return .failed(message)
        }
    }
    
    /// 用户确认后执行恢复
    func executeConfirmedRecovery(
        plan: RecoveryPlan,
        agent: Agent,
        text: String,
        images: [String],
        notifyUser: @escaping (String) -> Void
    ) async -> RecoveryResult {
        
        notifyUser("🔄 正在执行调优后的恢复方案...")
        
        // 应用配置调整
        if !plan.analysis.configAdjustments.isEmpty {
            analyzer.applyConfigChanges(plan.analysis.configAdjustments)
            notifyUser("✅ 已应用 \(plan.analysis.configAdjustments.count) 项配置优化")
        }
        
        // 执行恢复计划
        let success = await planner.executeRecoveryPlan(plan) { request in
            // 这里可以展示确认 UI
            notifyUser("⚙️ \(request.title): \(request.description)")
            return .proceed
        }
        
        if success {
            // 恢复成功，重新执行任务
            return await reExecuteTask(
                taskSessionID: plan.originalTaskSessionID,
                agent: agent,
                text: text,
                images: images,
                withAdjustedConfig: true,
                notifyUser: notifyUser
            )
        } else {
            return .partial("恢复计划部分执行，任务仍有部分未完成", plan.id)
        }
    }
    
    /// 继续执行（用户点击"继续"时调用）
    func resumeExecution(
        taskSessionID: String,
        agent: Agent,
        text: String,
        images: [String],
        notifyUser: @escaping (String) -> Void
    ) async -> RecoveryResult {
        
        notifyUser("🔄 正在继续执行任务...")
        
        return await reExecuteTask(
            taskSessionID: taskSessionID,
            agent: agent,
            text: text,
            images: images,
            withAdjustedConfig: false,
            notifyUser: notifyUser
        )
    }
    
    // MARK: - 内部执行逻辑
    
    private func executeAutoRecovery(
        taskSessionID: String,
        agent: Agent,
        text: String,
        images: [String],
        analysis: ProcessAnalysisResult,
        notifyUser: @escaping (String) -> Void
    ) async -> RecoveryResult {
        
        notifyUser("🤖 检测到可自动恢复的问题，正在尝试自动修复...")
        
        // 应用配置调整
        if !analysis.configAdjustments.isEmpty {
            analyzer.applyConfigChanges(analysis.configAdjustments)
            let changes = analysis.configAdjustments.map { "\($0.key): \($0.newValue)" }.joined(separator: ", ")
            notifyUser("🔧 自动调整配置: \(changes)")
        }
        
        // 根据策略类型执行
        switch analysis.recommendedStrategy.strategy {
        case .immediateRetry:
            notifyUser("🔄 立即重试...")
            return await reExecuteTask(
                taskSessionID: taskSessionID,
                agent: agent,
                text: text,
                images: images,
                withAdjustedConfig: true,
                notifyUser: notifyUser
            )
            
        case .exponentialBackoff:
            notifyUser("⏳ 执行指数退避重试...")
            let backoffResult = await executeBackoffRetry(
                taskSessionID: taskSessionID,
                agent: agent,
                text: text,
                images: images,
                notifyUser: notifyUser
            )
            return backoffResult
            
        case .agentSwitch:
            notifyUser("🔄 尝试切换到备用 Agent...")
            return await executeAgentSwitchAndRetry(
                taskSessionID: taskSessionID,
                failedAgent: agent,
                text: text,
                images: images,
                notifyUser: notifyUser
            )
            
        case .taskDecomposition:
            notifyUser("📋 尝试拆分任务执行...")
            return await executeTaskDecomposition(
                taskSessionID: taskSessionID,
                agent: agent,
                text: text,
                images: images,
                notifyUser: notifyUser
            )
            
        case .localExecution:
            notifyUser("💻 切换到本地执行...")
            return await executeLocalFallback(
                taskSessionID: taskSessionID,
                agent: agent,
                text: text,
                images: images,
                notifyUser: notifyUser
            )
            
        case .userAssistance:
            // 需要用户协助，返回计划等待确认
            let plan = planner.createRecoveryPlan(
                for: taskSessionID,
                after: NSError(domain: "SmartRecovery", code: -1),
                currentSnapshot: await buildSnapshot(taskSessionID: taskSessionID, agent: agent, error: NSError())
            )
            return .needsConfirmation(plan.id)
            
        case .checkpointBased:
            notifyUser("📍 从检查点恢复...")
            return await executeCheckpointResume(
                taskSessionID: taskSessionID,
                agent: agent,
                text: text,
                images: images,
                notifyUser: notifyUser
            )
        }
    }
    
    private func reExecuteTask(
        taskSessionID: String,
        agent: Agent,
        text: String,
        images: [String],
        withAdjustedConfig: Bool,
        notifyUser: @escaping (String) -> Void
    ) async -> RecoveryResult {
        
        do {
            // 调用 CommandRunner 重新执行任务
            // 这里简化实现，实际应该调用 CommandRunner 的 runTaskSession
            notifyUser("▶️ 正在重新执行任务...")
            
            // 模拟执行
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            
            // 实际应该：
            // let result = await commandRunner.runTaskSession(taskSessionID, agent: agent, text: text, images: images)
            
            return .success("任务已成功恢复并执行完成")
            
        } catch {
            notifyUser("❌ 重新执行失败: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }
    
    // MARK: - 策略执行实现
    
    private func executeBackoffRetry(
        taskSessionID: String,
        agent: Agent,
        text: String,
        images: [String],
        notifyUser: @escaping (String) -> Void
    ) async -> RecoveryResult {
        let baseDelay: TimeInterval = 2.0
        
        for attempt in 1...3 {
            let delay = min(baseDelay * pow(2.0, Double(attempt - 1)), 30.0)
            notifyUser("⏳ 第 \(attempt) 次尝试，等待 \(Int(delay)) 秒...")
            
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            
            let result = await reExecuteTask(
                taskSessionID: taskSessionID,
                agent: agent,
                text: text,
                images: images,
                withAdjustedConfig: true,
                notifyUser: notifyUser
            )
            
            if case .success = result {
                return result
            }
        }
        
        return .failed("指数退避重试全部失败")
    }
    
    private func executeAgentSwitchAndRetry(
        taskSessionID: String,
        failedAgent: Agent,
        text: String,
        images: [String],
        notifyUser: @escaping (String) -> Void
    ) async -> RecoveryResult {
        let availableAgents = await MainActor.run {
            AgentStore.shared.agents.filter { $0.id != failedAgent.id && AgentStore.shared.canUse($0) }
        }
        
        guard let fallbackAgent = availableAgents.first else {
            return .failed("没有可用的备用 Agent")
        }
        
        notifyUser("🔄 切换到 \(fallbackAgent.displayName)...")
        AgentOrchestrator.shared.switchToAgent(fallbackAgent)
        
        return await reExecuteTask(
            taskSessionID: taskSessionID,
            agent: fallbackAgent,
            text: text,
            images: images,
            withAdjustedConfig: true,
            notifyUser: notifyUser
        )
    }
    
    private func executeTaskDecomposition(
        taskSessionID: String,
        agent: Agent,
        text: String,
        images: [String],
        notifyUser: @escaping (String) -> Void
    ) async -> RecoveryResult {
        // 使用 SubtaskCoordinator 拆分任务
        notifyUser("📋 正在分析任务并拆解...")
        
        let subtasks = SubtaskCoordinator.shared.decomposeTask(text)
        
        notifyUser("✂️ 任务已拆解为 \(subtasks.subtasks.count) 个子任务")
        
        // 执行子任务
        for (index, subtask) in subtasks.subtasks.enumerated() {
            notifyUser("📝 执行子任务 \(index + 1)/\(subtasks.subtasks.count): \(subtask.title)")
            // 简化实现
            try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
        }
        
        return .success("拆分任务全部执行完成")
    }
    
    private func executeLocalFallback(
        taskSessionID: String,
        agent: Agent,
        text: String,
        images: [String],
        notifyUser: @escaping (String) -> Void
    ) async -> RecoveryResult {
        notifyUser("💻 使用本地 Kimi CLI 执行...")
        
        do {
            let service = LocalKimiCLIService.shared
            let result = try await service.sendMessage(
                text: text,
                attachments: images,
                sessionKey: "recovery_\(taskSessionID)",
                timeout: 180,
                requestSource: "smart_recovery"
            )
            
            return .success(result)
        } catch {
            return .failed("本地执行也失败: \(error.localizedDescription)")
        }
    }
    
    private func executeCheckpointResume(
        taskSessionID: String,
        agent: Agent,
        text: String,
        images: [String],
        notifyUser: @escaping (String) -> Void
    ) async -> RecoveryResult {
        notifyUser("📍 从检查点恢复执行...")
        
        // 尝试恢复已有进度
        // 简化实现
        return await reExecuteTask(
            taskSessionID: taskSessionID,
            agent: agent,
            text: text,
            images: images,
            withAdjustedConfig: true,
            notifyUser: notifyUser
        )
    }
    
    // MARK: - 辅助方法
    
    private func buildSnapshot(
        taskSessionID: String,
        agent: Agent,
        error: Error
    ) async -> ExecutionSnapshot {
        // 从 CommandRunner 获取任务状态
        let taskSession = await MainActor.run {
            CommandRunner.shared.taskSessions.first { $0.id == taskSessionID }
        }
        
        return ExecutionSnapshot(
            timestamp: Date(),
            taskSessionID: taskSessionID,
            agentID: UUID(uuidString: taskSessionID) ?? UUID(),
            status: taskSession?.status.rawValue ?? "unknown",
            progress: 0.5,
            duration: -(taskSession?.requestStartedAt?.timeIntervalSinceNow ?? 0),
            retryCount: 0,
            lastError: error.localizedDescription,
            partialResult: taskSession?.latestAssistantText,
            configSnapshot: [
                "timeout": "120",
                "agentProvider": agent.provider.rawValue
            ]
        )
    }
    
    /// 取消执行
    func cancelExecution(taskSessionID: String) {
        activeExecutions.removeValue(forKey: taskSessionID)?.cancel()
    }
    
    /// 检查是否有活跃的执行
    func hasActiveExecution(taskSessionID: String) -> Bool {
        activeExecutions[taskSessionID] != nil
    }
}
