//
//  PlannerWakeService.swift
//  MacAssistant
//
//  Planner 唤醒服务 - 定时和事件驱动唤醒 Reflection Planner
//

import Foundation
import Combine
#if canImport(UserNotifications)
import UserNotifications
#endif

@MainActor
final class PlannerWakeService: ObservableObject {
    static let shared = PlannerWakeService()
    
    // MARK: - Dependencies
    
    private let reflectionPlanner = ReflectionPlanner.shared
    private let workflowCoordinator = WorkflowRunCoordinator.shared
    private let checkpointStore = PlannerCheckpointStore.shared
    
    // MARK: - Configuration
    
    private let defaultInterval: TimeInterval = 900  // 15分钟
    private let minInterval: TimeInterval = 60       // 1分钟
    private let maxInterval: TimeInterval = 3600     // 1小时
    
    // MARK: - State
    
    private var timer: Timer?
    private var isRunning = false
    private var lastWakeTime: Date?
    
    // 节流控制
    private var recentWakes: [Date] = []
    private let maxWakesPerMinute = 5
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupEventObservers()
    }
    
    // MARK: - 服务控制
    
    func start() {
        guard !isRunning else { return }
        
        isRunning = true
        LogInfo("[PlannerWakeService] 启动")
        
        // 立即执行一次
        Task {
            await performPeriodicWake()
        }
        
        // 设置定时器
        timer = Timer.scheduledTimer(withTimeInterval: defaultInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performPeriodicWake()
            }
        }
    }
    
    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        LogInfo("[PlannerWakeService] 停止")
    }
    
    // MARK: - 事件监听
    
    private func setupEventObservers() {
        // 监听浏览器页面变化
        NotificationCenter.default.publisher(for: .browserPageChanged)
            .sink { [weak self] notification in
                Task { @MainActor in
                    if let runID = notification.userInfo?["runID"] as? String {
                        await self?.wake(
                            trigger: .browserPageChanged,
                            runID: runID,
                            reason: "浏览器页面变化"
                        )
                    }
                }
            }
            .store(in: &cancellables)
        
        // 监听新消息
        NotificationCenter.default.publisher(for: .newMessageReceived)
            .sink { [weak self] notification in
                Task { @MainActor in
                    if let runID = notification.userInfo?["runID"] as? String {
                        await self?.wake(
                            trigger: .newMessageReceived,
                            runID: runID,
                            reason: "收到新消息"
                        )
                    }
                }
            }
            .store(in: &cancellables)
        
        // 监听 workflow 失败
        NotificationCenter.default.publisher(for: .workflowFailed)
            .sink { [weak self] notification in
                Task { @MainActor in
                    if let runID = notification.userInfo?["runID"] as? String {
                        await self?.wake(
                            trigger: .taskFailed,
                            runID: runID,
                            reason: "Workflow 失败"
                        )
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 唤醒入口
    
    /// 唤醒服务（统一入口）
    func wake(
        trigger: PlannerCheckpoint.WakeUpTrigger,
        runID: String? = nil,
        reason: String
    ) async {
        // 节流检查
        if isThrottled {
            LogWarning("[PlannerWakeService] 唤醒被节流: \(trigger.rawValue)")
            return
        }
        
        recordWake()
        
        LogInfo("[PlannerWakeService] 唤醒触发: \(trigger.rawValue), 原因: \(reason)")
        
        // 收集上下文
        let context = await collectContext(trigger: trigger, runID: runID)
        
        // 轻量筛选
        guard shouldWakeReflection(trigger: trigger, context: context) else {
            LogInfo("[PlannerWakeService] 轻量筛选通过，无需唤醒 Reflection")
            return
        }
        
        // 唤醒 Reflection Planner
        if let targetRunID = runID ?? findMostImportantRunID() {
            let decision = await reflectionPlanner.reflect(
                runID: targetRunID,
                trigger: trigger,
                context: ReflectionContext(runID: targetRunID, summary: reason)
            )
            
            // 执行决策
            await executeDecision(decision, runID: targetRunID)
        }
        
        lastWakeTime = Date()
    }
    
    // MARK: - 定时唤醒
    
    private func performPeriodicWake() async {
        LogInfo("[PlannerWakeService] 执行周期巡检")
        
        // 清理过期检查点
        checkpointStore.clearOldCheckpoints(olderThan: 7)
        
        // 获取所有活跃的 workflow
        let activeRunIDs = workflowCoordinator.allActiveRunIDs()
        
        for runID in activeRunIDs {
            await wake(
                trigger: .periodicLightCheck,
                runID: runID,
                reason: "周期巡检"
            )
        }
        
        // 检查审批超时
        ApprovalStepExecutor.shared.checkExpiredApprovals(autoDeny: true)
    }
    
    // MARK: - 轻量筛选
    
    private func shouldWakeReflection(
        trigger: PlannerCheckpoint.WakeUpTrigger,
        context: WakeContext
    ) -> Bool {
        switch trigger {
        case .browserPageChanged, .newMessageReceived:
            // 检查相关 workflow 是否在等待
            return context.hasWaitingWorkflow
            
        case .taskFailed:
            // 总是唤醒
            return true
            
        case .serviceStatusChanged:
            // 检查是否有 workflow 依赖此服务
            return context.hasDependentWorkflow
            
        case .periodicLightCheck:
            // 检查是否有阻塞或需要提醒的 workflow
            return context.hasBlockedWorkflow || context.hasSlowProgressWorkflow
            
        case .lowConfidence, .highRiskAction, .longBlocked, .highValueOpportunity:
            // 这些触发器已经经过筛选
            return true
            
        case .userAction, .manual:
            return true
        }
    }
    
    // MARK: - 决策执行
    
    private func executeDecision(_ decision: ReflectionDecision, runID: String) async {
        switch decision {
        case .noop:
            // 无需操作
            break
            
        case .remind(let reason, let priority):
            await notifyUser(runID: runID, message: reason, priority: priority)
            
        case .replan(let reason):
            LogInfo("[PlannerWakeService] 重新规划 Workflow: \(runID), 原因: \(reason)")
            workflowCoordinator.markNeedsReplan(runID: runID, reason: reason)
            await notifyUser(runID: runID, message: "Workflow 需要重新规划：\(reason)", priority: .medium)
            
        case .resume(let reason):
            LogInfo("[PlannerWakeService] 恢复 Workflow: \(runID), 原因: \(reason)")
            workflowCoordinator.resumeWorkflow(runID: runID)
            
        case .escalate(let reason):
            LogWarning("[PlannerWakeService] 升级 Workflow: \(runID), 原因: \(reason)")
            await escalateToUser(runID: runID, reason: reason)
        }
    }
    
    // MARK: - 通知
    
    private func notifyUser(runID: String, message: String, priority: Priority) async {
        let notification = AgentNotification(
            timestamp: Date(),
            title: "Workflow 提醒",
            message: message,
            type: priority == .critical ? .alert : .suggestion,
            priority: priority,
            actions: [
                NotificationAction(title: "查看", action: {})
            ],
            metadata: ["runID": runID]
        )
        
        await MainActor.run {
            AutoAgent.shared.notifications.append(notification)
        }
        
        // 发送本地通知
        if priority == .high || priority == .critical {
            await sendLocalNotification(title: "Workflow 提醒", body: message)
        }
    }
    
    private func escalateToUser(runID: String, reason: String) async {
        await notifyUser(runID: runID, message: "需要人工处理: \(reason)", priority: .critical)
        
        // 暂停 workflow
        workflowCoordinator.pauseWorkflow(runID: runID)
    }
    
    private func sendLocalNotification(title: String, body: String) async {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "planner-wake-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        try? await UNUserNotificationCenter.current().add(request)
        #endif
    }
    
    // MARK: - 辅助方法
    
    private func collectContext(
        trigger: PlannerCheckpoint.WakeUpTrigger,
        runID: String?
    ) async -> WakeContext {
        var context = WakeContext()
        
        if let rid = runID, let runState = workflowCoordinator.runState(runID: rid) {
            context.runState = runState
            context.isBlocked = runState.isBlocked
            context.progress = runState.progress
        }
        
        let allRuns = workflowCoordinator.allActiveRunIDs()
        context.hasWaitingWorkflow = allRuns.contains { id in
            workflowCoordinator.runState(runID: id)?.blockingReason != nil
        }
        context.hasBlockedWorkflow = allRuns.contains { id in
            workflowCoordinator.isBlocked(runID: id)
        }
        context.hasSlowProgressWorkflow = allRuns.contains { id in
            guard let runState = workflowCoordinator.runState(runID: id) else { return false }
            let lastActivity = runState.checkpoints.last?.timestamp ?? runState.stepRuns.last?.startedAt ?? .distantPast
            return runState.progress < 0.3 && lastActivity < Date().addingTimeInterval(-600)
        }
        
        return context
    }
    
    private func findMostImportantRunID() -> String? {
        // 找到最重要的 workflow run（如阻塞时间最长的）
        let activeRuns = workflowCoordinator.allActiveRunIDs()
        
        // 优先返回阻塞的 run
        if let blockedRun = activeRuns.first(where: { workflowCoordinator.isBlocked(runID: $0) }) {
            return blockedRun
        }
        
        return activeRuns.first
    }
    
    // MARK: - 节流控制
    
    private var isThrottled: Bool {
        let now = Date()
        // 清理1分钟前的记录
        recentWakes.removeAll { $0 < now.addingTimeInterval(-60) }
        return recentWakes.count >= maxWakesPerMinute
    }
    
    private func recordWake() {
        recentWakes.append(Date())
    }
}

// MARK: - Wake Context

private struct WakeContext {
    var runState: WorkflowRunState?
    var isBlocked: Bool = false
    var progress: Double = 0
    var hasWaitingWorkflow: Bool = false
    var hasBlockedWorkflow: Bool = false
    var hasSlowProgressWorkflow: Bool = false
    var hasDependentWorkflow: Bool = false
}

// MARK: - Notification Names

extension Notification.Name {
    static let browserPageChanged = Notification.Name("BrowserPageChanged")
    static let newMessageReceived = Notification.Name("NewMessageReceived")
}
