//
//  UnifiedTaskManager.swift
//  MacAssistant
//
//  统一任务管理器 - 整合任务生命周期、执行调度和状态管理
//

import Foundation
import SwiftUI
import Combine

/// 统一任务管理器 - 单例
@MainActor
final class UnifiedTaskManager: ObservableObject {
    static let shared = UnifiedTaskManager()
    
    // MARK: - Published State
    
    /// 所有任务
    @Published var tasks: [UnifiedTask] = []
    
    /// 当前选中任务
    @Published var selectedTaskID: String?
    
    /// 任务统计
    @Published var statistics: TaskStatistics = TaskStatistics(
        total: 0, pending: 0, running: 0, paused: 0, completed: 0, failed: 0
    )
    
    /// 是否有活跃的后台任务
    @Published var hasActiveBackgroundTasks: Bool = false
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    private var autoSaveTimer: Timer?
    private var executionQueue: [String] = []  // 存储任务ID
    private var isProcessingQueue = false
    
    // 持久化存储路径
    private var tasksStorageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("unified_tasks.json")
    }
    
    // MARK: - Initialization
    
    private init() {
        loadTasks()
        setupAutoSave()
        setupStatisticsObserver()
    }
    
    // MARK: - Task CRUD
    
    /// 添加新任务
    @discardableResult
    func addTask(_ task: UnifiedTask) -> UnifiedTask {
        tasks.append(task)
        updateStatistics()
        
        // 如果是待执行且可恢复，加入执行队列
        if task.status == .pending && task.canResume {
            enqueueTask(task.id)
        }
        
        // 通知
        notifyTaskAdded(task)
        
        return task
    }
    
    /// 创建异常恢复任务
    func createExceptionRecoveryTask(
        title: String,
        originalRequest: String,
        errorMessage: String,
        gatewaySessionKey: String,
        messages: [TaskMessage] = []
    ) -> UnifiedTask {
        var task = UnifiedTask.exceptionRecovery(
            title: title,
            originalRequest: originalRequest,
            errorMessage: errorMessage,
            gatewaySessionKey: gatewaySessionKey
        )
        task.messages = messages
        
        // 检查是否已有相同sessionKey的任务，更新而非创建新的
        if let existingIndex = tasks.firstIndex(where: { 
            $0.gatewaySessionKey == gatewaySessionKey && $0.type == .exceptionRecovery 
        }) {
            // 更新现有任务
            tasks[existingIndex] = task
            updateStatistics()
            return task
        }
        
        return addTask(task)
    }
    
    /// 创建智能子任务
    func createSmartSubtask(
        title: String,
        description: String,
        inputContext: String,
        strategy: TaskExecutionStrategy
    ) -> UnifiedTask {
        let task = UnifiedTask.smartSubtask(
            title: title,
            description: description,
            inputContext: inputContext,
            strategy: strategy
        )
        return addTask(task)
    }
    
    /// 创建待办任务
    func createTodoTask(
        title: String,
        description: String = "",
        scheduledTime: Date? = nil
    ) -> UnifiedTask {
        let task = UnifiedTask.todo(
            title: title,
            description: description,
            scheduledTime: scheduledTime
        )
        return addTask(task)
    }
    
    /// 删除任务
    func removeTask(id: String) {
        tasks.removeAll { $0.id == id }
        updateStatistics()
        saveTasks()
    }
    
    /// 批量删除已完成任务
    func removeCompletedTasks() {
        tasks.removeAll { $0.status == .completed }
        updateStatistics()
        saveTasks()
    }
    
    /// 获取任务
    func task(id: String) -> UnifiedTask? {
        tasks.first { $0.id == id }
    }
    
    /// 更新任务
    func updateTask(id: String, _ update: (inout UnifiedTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        update(&tasks[index])
        tasks[index].updatedAt = Date()
        updateStatistics()
    }
    
    // MARK: - Task Execution
    
    /// 开始执行任务
    func startTask(id: String) async {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].status.canResume else { return }
        
        tasks[index].start()
        
        // 根据任务类型选择执行器
        let task = tasks[index]
        
        switch task.type {
        case .exceptionRecovery:
            await executeExceptionRecovery(task: task)
        case .smartSubtask:
            await executeSmartSubtask(task: task)
        case .todo, .background:
            await executeGenericTask(task: task)
        }
    }
    
    /// 暂停任务
    func pauseTask(id: String) {
        updateTask(id: id) { task in
            task.pause()
        }
        // 从执行队列移除
        executionQueue.removeAll { $0 == id }
    }
    
    /// 恢复任务
    func resumeTask(id: String) {
        updateTask(id: id) { task in
            task.resume()
        }
        enqueueTask(id)
    }
    
    /// 重试失败任务
    func retryTask(id: String) async {
        updateTask(id: id) { task in
            task.retryCount += 1
            task.errorMessage = nil
        }
        await startTask(id: id)
    }
    
    /// 取消任务
    func cancelTask(id: String) {
        updateTask(id: id) { task in
            task.status = .failed
            task.errorMessage = "已取消"
        }
        executionQueue.removeAll { $0 == id }
    }
    
    /// 标记任务完成
    func completeTask(id: String, result: String) {
        updateTask(id: id) { task in
            task.complete(result: result)
        }
        notifyTaskCompleted(task(id: id)!)
    }
    
    /// 标记任务失败
    func failTask(id: String, error: String) {
        updateTask(id: id) { task in
            task.fail(error: error)
        }
        
        // 检查是否需要重试
        if let task = task(id: id), task.retryCount < task.maxRetries {
            // 自动重试
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒后重试
                await retryTask(id: id)
            }
        }
    }
    
    // MARK: - Task Execution Implementations
    
    /// 执行异常恢复任务
    /// 通过 CommandRunner 恢复 OpenClaw 对话
    private func executeExceptionRecovery(task: UnifiedTask) async {
        guard let gatewaySessionKey = task.gatewaySessionKey,
              let originalRequest = task.originalRequest else {
            failTask(id: task.id, error: "缺少恢复所需信息")
            return
        }
        
        await logger.startSession(id: task.id, userRequest: originalRequest)
        logger.log(
            sessionID: task.id,
            level: .info,
            component: "UnifiedTaskManager",
            message: "开始异常恢复任务: \(task.title)",
            details: ["gatewaySessionKey": gatewaySessionKey]
        )
        
        // 调用 CommandRunner 的恢复功能
        // 通过 NotificationCenter 通知 CommandRunner 恢复任务
        await MainActor.run {
            NotificationCenter.default.post(
                name: .resumeTaskSessionNotification,
                object: nil,
                userInfo: [
                    "gatewaySessionKey": gatewaySessionKey,
                    "originalRequest": originalRequest,
                    "taskID": task.id
                ]
            )
        }
        
        // 监听恢复完成通知
        do {
            let result = try await waitForRecoveryCompletion(taskID: task.id, timeout: 300)
            if result.success {
                completeTask(id: task.id, result: result.content ?? "恢复成功")
            } else {
                failTask(id: task.id, error: result.error ?? "恢复失败")
            }
        } catch {
            failTask(id: task.id, error: "恢复超时或取消")
        }
    }
    
    /// 等待恢复完成
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
    
    /// 执行智能子任务
    /// 根据策略选择执行器：Agent、Skill 或本地服务
    private func executeSmartSubtask(task: UnifiedTask) async {
        logger.log(
            sessionID: task.id,
            level: .info,
            component: "UnifiedTaskManager",
            message: "开始执行智能子任务: \(task.title)",
            details: ["strategy": task.strategy.displayName]
        )
        
        do {
            let result: String
            
            switch task.strategy.type {
            case .auto:
                // 自动选择执行器
                result = try await executeWithAutoStrategy(task: task)
                
            case .useBuiltin:
                // 使用内置服务
                result = try await executeWithBuiltinService(task: task)
                
            case .useSkill:
                // 使用 Skill
                if let skillID = task.strategy.targetID {
                    result = try await executeWithSkill(task: task, skillID: skillID)
                } else {
                    throw TaskExecutionError.missingTargetID("Skill")
                }
                
            case .useAgent:
                // 使用 Agent
                if let agentID = task.strategy.targetID {
                    result = try await executeWithAgent(task: task, agentID: agentID)
                } else {
                    throw TaskExecutionError.missingTargetID("Agent")
                }
                
            case .useOpenClaw:
                // 使用 OpenClaw
                if let agentID = task.strategy.targetID {
                    result = try await executeWithOpenClaw(task: task, agentID: agentID)
                } else {
                    throw TaskExecutionError.missingTargetID("OpenClaw Agent")
                }
                
            case .manual:
                // 手动执行 - 等待用户操作
                updateTask(id: task.id) { task in
                    task.status = .paused
                    task.errorMessage = "等待手动执行"
                }
                return
                
            case .exceptionRecovery:
                // 异常恢复不应该通过智能子任务触发
                throw TaskExecutionError.invalidStrategy("异常恢复请使用 exceptionRecovery 任务类型")
            }
            
            completeTask(id: task.id, result: result)
            
        } catch {
            failTask(id: task.id, error: error.localizedDescription)
        }
    }
    
    /// 执行通用任务
    /// 简单的待办任务，直接标记完成或等待用户确认
    private func executeGenericTask(task: UnifiedTask) async {
        logger.log(
            sessionID: task.id,
            level: .info,
            component: "UnifiedTaskManager",
            message: "执行通用任务: \(task.title)",
            details: nil
        )
        
        // 对于简单的待办任务，直接标记完成
        // 实际应用中这里可以集成提醒、通知等功能
        completeTask(id: task.id, result: "任务已标记完成")
    }
    
    // MARK: - Strategy Execution Helpers
    
    /// 自动策略执行
    private func executeWithAutoStrategy(task: UnifiedTask) async throws -> String {
        // 分析任务内容，自动选择最佳执行器
        let input = task.inputContext.lowercased()
        
        // 代码相关任务 -> 使用代码 Agent
        if input.contains("代码") || input.contains("code") || input.contains("swift") {
            return try await executeWithBuiltinService(task: task)
        }
        
        // 默认使用内置服务
        return try await executeWithBuiltinService(task: task)
    }
    
    /// 使用内置服务执行
    private func executeWithBuiltinService(task: UnifiedTask) async throws -> String {
        // 这里可以集成内置的 AI 服务或本地处理逻辑
        // 暂时返回模拟结果
        return "任务 \"\(task.title)\" 已通过内置服务执行完成。\n\n输入内容: \(task.inputContext.prefix(100))"
    }
    
    /// 使用 Skill 执行
    private func executeWithSkill(task: UnifiedTask, skillID: String) async throws -> String {
        // 通过 SkillRegistry 执行 Skill
        // 这里需要集成实际的 Skill 执行逻辑
        logger.log(
            sessionID: task.id,
            level: .info,
            component: "UnifiedTaskManager",
            message: "使用 Skill 执行: \(skillID)",
            details: nil
        )
        return "任务 \"\(task.title)\" 已通过 Skill [\(skillID)] 执行完成。"
    }
    
    /// 使用 Agent 执行
    private func executeWithAgent(task: UnifiedTask, agentID: String) async throws -> String {
        logger.log(
            sessionID: task.id,
            level: .info,
            component: "UnifiedTaskManager",
            message: "使用 Agent 执行: \(agentID)",
            details: nil
        )
        return "任务 \"\(task.title)\" 已通过 Agent [\(agentID)] 执行完成。"
    }
    
    /// 使用 OpenClaw 执行
    private func executeWithOpenClaw(task: UnifiedTask, agentID: String) async throws -> String {
        logger.log(
            sessionID: task.id,
            level: .info,
            component: "UnifiedTaskManager",
            message: "使用 OpenClaw 执行: \(agentID)",
            details: nil
        )
        return "任务 \"\(task.title)\" 已通过 OpenClaw [\(agentID)] 执行完成。"
    }
    
    // MARK: - Execution Queue
    
    /// 将任务加入执行队列
    private func enqueueTask(_ id: String) {
        guard !executionQueue.contains(where: { $0 == id }) else { return }
        executionQueue.append(id)
        processQueue()
    }
    
    /// 处理执行队列
    private func processQueue() {
        guard !isProcessingQueue else { return }
        guard !executionQueue.isEmpty else { return }
        
        isProcessingQueue = true
        
        Task {
            while !executionQueue.isEmpty {
                let taskID = executionQueue.removeFirst()
                await startTask(id: taskID)
            }
            isProcessingQueue = false
        }
    }
    
    // MARK: - Filtered Accessors
    
    /// 按状态筛选的任务
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
        case .completed:
            return tasks.filter { $0.status == .completed }
                .sorted { $0.completedAt ?? $0.createdAt > $1.completedAt ?? $1.createdAt }
        case .exception:
            return tasks.filter { $0.type == .exceptionRecovery }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }
    
    /// 活跃任务数量
    var activeTaskCount: Int {
        tasks.filter { $0.status.isActive }.count
    }
    
    /// 是否有待处理的异常恢复任务
    var hasPendingExceptionTasks: Bool {
        tasks.contains { $0.type == .exceptionRecovery && $0.status == .pending }
    }
    
    // MARK: - Persistence
    
    /// 保存任务到磁盘
    func saveTasks() {
        do {
            let data = try JSONEncoder().encode(tasks)
            try data.write(to: tasksStorageURL)
        } catch {
            print("Failed to save tasks: \(error)")
        }
    }
    
    /// 从磁盘加载任务
    private func loadTasks() {
        guard FileManager.default.fileExists(atPath: tasksStorageURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: tasksStorageURL)
            tasks = try JSONDecoder().decode([UnifiedTask].self, from: data)
            updateStatistics()
        } catch {
            print("Failed to load tasks: \(error)")
        }
    }
    
    /// 设置自动保存
    private func setupAutoSave() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.saveTasks()
            }
        }
    }
    
    // MARK: - Statistics
    
    private func setupStatisticsObserver() {
        $tasks
            .sink { [weak self] _ in
                self?.updateStatistics()
            }
            .store(in: &cancellables)
    }
    
    private func updateStatistics() {
        statistics = TaskStatistics(
            total: tasks.count,
            pending: tasks.filter { $0.status == .pending }.count,
            running: tasks.filter { $0.status == .running }.count,
            paused: tasks.filter { $0.status == .paused }.count,
            completed: tasks.filter { $0.status == .completed }.count,
            failed: tasks.filter { $0.status == .failed }.count
        )
        
        hasActiveBackgroundTasks = tasks.contains {
            $0.status == .running && $0.type == .background
        }
    }
    
    // MARK: - Notifications
    
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
}

// MARK: - Notification Names

extension Notification.Name {
    static let taskAdded = Notification.Name("UnifiedTaskAdded")
    static let taskCompleted = Notification.Name("UnifiedTaskCompleted")
    static let resumeTaskSessionNotification = Notification.Name("ResumeTaskSessionNotification")
    static let taskRecoveryCompleted = Notification.Name("TaskRecoveryCompleted")
}

// MARK: - Task Execution Errors

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

// MARK: - Task Recovery Result

struct TaskRecoveryResult {
    let success: Bool
    let content: String?
    let error: String?
}

// MARK: - Timeout Helper

func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        // 添加主任务
        group.addTask {
            try await operation()
        }
        
        // 添加超时任务
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TaskExecutionError.timeout
        }
        
        // 返回先完成的任务
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Helper Logger

@MainActor
private var logger: ExecutionLogger { ExecutionLogger.shared }
