//
//  BackgroundTaskRecoveryService.swift
//  MacAssistant
//
//  方案A：后台任务自动恢复服务 - 兜底机制
//

import Foundation

/// 后台恢复任务状态
enum BackgroundRecoveryState: String {
    case scheduled = "scheduled"       // 已安排
    case checking = "checking"         // 正在检查
    case recovered = "recovered"       // 已恢复
    case failed = "failed"             // 恢复失败
    case cancelled = "cancelled"       // 已取消
}

/// 后台恢复任务
struct BackgroundRecoveryTask: Identifiable, Codable {
    let id: String
    let sessionID: String
    let originalRequest: String
    let scheduledAt: Date
    var checkAt: Date
    var state: String
    var attempts: Int
    let maxAttempts: Int
    var lastError: String?
    var recoveredResult: String?
}

@MainActor
final class BackgroundTaskRecoveryService: ObservableObject {
    static let shared = BackgroundTaskRecoveryService()
    
    /// 默认延迟检查时间（秒）
    private let defaultDelaySeconds = 10
    
    /// 最大重试次数
    private let maxAttempts = 3
    
    /// 重试间隔（秒）
    private let retryInterval: TimeInterval = 30
    
    /// 待处理任务队列
    @Published private(set) var pendingTasks: [BackgroundRecoveryTask] = []
    
    /// 已完成任务
    @Published private(set) var completedTasks: [BackgroundRecoveryTask] = []
    
    /// 任务会话管理器
    private var taskSessionManager: CommandRunner?
    
    /// OpenClaw客户端
    private let openClawClient = OpenClawGatewayClient.shared
    
    /// 智能恢复执行器
    private let smartRecovery = SmartRecoveryExecutor.shared
    
    /// 后台任务定时器
    private var checkTimer: Timer?
    
    private init() {
        loadPersistedTasks()
        startBackgroundChecker()
    }
    
    // MARK: - 公共API
    
    /// 安排一个后台恢复任务（方案A：自动兜底）
    func scheduleRecovery(
        sessionID: String,
        originalRequest: String,
        delaySeconds: Int? = nil
    ) {
        let delay = delaySeconds ?? defaultDelaySeconds
        let now = Date()
        
        // 检查是否已存在相同session的任务
        if pendingTasks.contains(where: { $0.sessionID == sessionID }) {
            LogInfo("[BackgroundRecovery] Session \(sessionID) 已有待处理恢复任务，跳过")
            return
        }
        
        let task = BackgroundRecoveryTask(
            id: UUID().uuidString,
            sessionID: sessionID,
            originalRequest: originalRequest,
            scheduledAt: now,
            checkAt: now.addingTimeInterval(TimeInterval(delay)),
            state: BackgroundRecoveryState.scheduled.rawValue,
            attempts: 0,
            maxAttempts: maxAttempts,
            lastError: nil,
            recoveredResult: nil
        )
        
        pendingTasks.append(task)
        persistTasks()
        
        LogInfo("[BackgroundRecovery] 安排恢复任务: session=\(sessionID), 将在\(delay)秒后检查")
        
        // 立即发送系统通知告知用户
        notifyUserTaskScheduled(sessionID: sessionID, checkAt: task.checkAt)
    }
    
    /// 取消指定session的恢复任务
    func cancelRecovery(sessionID: String) {
        if let index = pendingTasks.firstIndex(where: { $0.sessionID == sessionID }) {
            var task = pendingTasks[index]
            task.state = BackgroundRecoveryState.cancelled.rawValue
            completedTasks.append(task)
            pendingTasks.remove(at: index)
            persistTasks()
            LogInfo("[BackgroundRecovery] 取消恢复任务: session=\(sessionID)")
        }
    }
    
    /// 获取任务状态
    func getTaskStatus(sessionID: String) -> BackgroundRecoveryTask? {
        pendingTasks.first { $0.sessionID == sessionID }
            ?? completedTasks.first { $0.sessionID == sessionID }
    }
    
    // MARK: - 后台检查逻辑
    
    private func startBackgroundChecker() {
        // 每5秒检查一次待处理任务
        checkTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.processScheduledTasks()
            }
        }
    }
    
    private func processScheduledTasks() async {
        let now = Date()
        
        for index in pendingTasks.indices where pendingTasks[index].checkAt <= now {
            var task = pendingTasks[index]
            
            // 检查是否已手动恢复
            if await isTaskAlreadyRecovered(sessionID: task.sessionID) {
                task.state = BackgroundRecoveryState.recovered.rawValue
                task.recoveredResult = "已在其他地方恢复"
                moveToCompleted(task, at: index)
                continue
            }
            
            // 执行恢复检查
            task.state = BackgroundRecoveryState.checking.rawValue
            pendingTasks[index] = task
            
            let result = await performRecoveryCheck(task: &task)
            
            switch result {
            case .success(let recoveredText):
                task.state = BackgroundRecoveryState.recovered.rawValue
                task.recoveredResult = recoveredText
                moveToCompleted(task, at: index)
                notifyUserRecoverySuccess(task: task, result: recoveredText)
                
            case .failure(let error):
                task.attempts += 1
                task.lastError = error.localizedDescription
                
                if task.attempts >= task.maxAttempts {
                    task.state = BackgroundRecoveryState.failed.rawValue
                    moveToCompleted(task, at: index)
                    notifyUserRecoveryFailed(task: task)
                } else {
                    // 安排下次重试
                    task.checkAt = now.addingTimeInterval(retryInterval)
                    task.state = BackgroundRecoveryState.scheduled.rawValue
                    pendingTasks[index] = task
                    LogInfo("[BackgroundRecovery] 任务 \(task.sessionID) 第\(task.attempts)次尝试失败，将在\(retryInterval)秒后重试")
                }
            }
        }
        
        persistTasks()
    }
    
    private func performRecoveryCheck(task: inout BackgroundRecoveryTask) async -> Result<String, Error> {
        LogInfo("[BackgroundRecovery] 执行恢复检查: session=\(task.sessionID), 尝试次数=\(task.attempts + 1)")
        
        // 1. 尝试从OpenClaw历史恢复
        if let recovered = await recoverFromOpenClawHistory(sessionID: task.sessionID) {
            return .success(recovered)
        }
        
        // 2. 发送恢复请求通知，由外部处理
        NotificationCenter.default.post(
            name: NSNotification.Name("BackgroundRecoveryCheckRequested"),
            object: task.sessionID,
            userInfo: [
                "originalRequest": task.originalRequest,
                "attempt": task.attempts + 1
            ]
        )
        
        // 后台恢复服务不直接执行恢复，而是通知外部
        // 返回失败，等待外部介入或下次重试
        return .failure(NSError(domain: "BackgroundRecovery", code: -1, userInfo: [NSLocalizedDescriptionKey: "已发送恢复检查请求，等待外部处理"]))
    }
    
    // MARK: - 恢复策略实现
    
    private func recoverFromOpenClawHistory(sessionID: String) async -> String? {
        // 构造sessionKey
        let sessionKey = "agent:desktop:\(sessionID)"
        
        // 尝试从历史记录恢复
        // 这里简化处理，实际应该调用OpenClaw的history API
        return nil
    }
    
    private func isTaskAlreadyRecovered(sessionID: String) async -> Bool {
        // 检查任务会话状态
        guard let runner = taskSessionManager else { return false }
        // 这里需要检查任务是否已经有新消息或状态变化
        return false
    }
    
    private func findAgentForSession(_ sessionID: String) async -> Agent? {
        // 尝试找到合适的Agent进行恢复
        let agentStore = AgentStore.shared
        return agentStore.usableAgents.first
    }
    
    // MARK: - 用户通知
    
    private func notifyUserTaskScheduled(sessionID: String, checkAt: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeString = formatter.string(from: checkAt)
        
        NotificationCenter.default.post(
            name: NSNotification.Name("BackgroundRecoveryScheduled"),
            object: sessionID,
            userInfo: [
                "message": "任务将在 \(timeString) 自动检查恢复",
                "checkAt": checkAt
            ]
        )
    }
    
    private func notifyUserRecoverySuccess(task: BackgroundRecoveryTask, result: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name("BackgroundRecoverySuccess"),
            object: task.sessionID,
            userInfo: [
                "taskID": task.id,
                "result": result,
                "message": "后台自动恢复成功！"
            ]
        )
    }
    
    private func notifyUserRecoveryFailed(task: BackgroundRecoveryTask) {
        NotificationCenter.default.post(
            name: NSNotification.Name("BackgroundRecoveryFailed"),
            object: task.sessionID,
            userInfo: [
                "taskID": task.id,
                "attempts": task.attempts,
                "message": "自动恢复失败，请手动点击「继续处理」"
            ]
        )
    }
    
    // MARK: - 辅助方法
    
    private func moveToCompleted(_ task: BackgroundRecoveryTask, at index: Int) {
        completedTasks.append(task)
        pendingTasks.remove(at: index)
        LogInfo("[BackgroundRecovery] 任务完成: session=\(task.sessionID), state=\(task.state)")
    }
    
    // MARK: - 持久化
    
    private func persistTasks() {
        do {
            let pendingData = try JSONEncoder().encode(pendingTasks)
            let completedData = try JSONEncoder().encode(completedTasks)
            UserDefaults.standard.set(pendingData, forKey: "bg_recovery_pending")
            UserDefaults.standard.set(completedData, forKey: "bg_recovery_completed")
        } catch {
            LogError("[BackgroundRecovery] 持久化失败: \(error)")
        }
    }
    
    private func loadPersistedTasks() {
        if let pendingData = UserDefaults.standard.data(forKey: "bg_recovery_pending"),
           let tasks = try? JSONDecoder().decode([BackgroundRecoveryTask].self, from: pendingData) {
            pendingTasks = tasks.filter { $0.state != BackgroundRecoveryState.cancelled.rawValue }
        }
        
        if let completedData = UserDefaults.standard.data(forKey: "bg_recovery_completed"),
           let tasks = try? JSONDecoder().decode([BackgroundRecoveryTask].self, from: completedData) {
            completedTasks = tasks
        }
        
        LogInfo("[BackgroundRecovery] 加载了 \(pendingTasks.count) 个待处理任务, \(completedTasks.count) 个已完成任务")
    }
    
    deinit {
        checkTimer?.invalidate()
    }
}

// MARK: - 恢复结果

enum RecoveryCheckResult {
    case success(String)
    case partialSuccess(String, String?)  // 文本 + 错误
    case failed(String)
    case needsConfirmation(String, String)  // 计划ID + 错误
}
