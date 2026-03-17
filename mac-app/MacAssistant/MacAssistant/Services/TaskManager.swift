//
//  TaskManager.swift
//  MacAssistant
//
//  任务管理器 - 管理所有任务的完整生命周期
//

import Foundation
import Combine

@MainActor
final class TaskManager: ObservableObject {
    static let shared = TaskManager()
    
    // MARK: - Published Properties
    
    /// 待执行任务
    @Published private(set) var pendingTasks: [TaskItem] = []
    
    /// 执行中任务
    @Published private(set) var runningTasks: [TaskItem] = []
    
    /// 已完成任务
    @Published private(set) var completedTasks: [TaskItem] = []
    
    /// 当前选中的任务（用于对话界面）
    @Published var selectedTask: TaskItem?
    
    /// 是否需要选择Agent
    @Published var showAgentSelectionAlert: Bool = false
    
    /// 待分配Agent的任务ID
    var pendingAgentAssignmentTaskID: String?
    
    // MARK: - Private Properties
    
    private let agentStore = AgentStore.shared
    private let logsDirectory: URL
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    private init() {
        // 初始化日志目录
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.logsDirectory = appSupport.appendingPathComponent("MacAssistant/TaskLogs", isDirectory: true)
        
        try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        
        // 加载持久化的任务
        loadTasks()
    }
    
    // MARK: - 任务CRUD
    
    /// 添加新任务
    func addTask(_ task: TaskItem) {
        // 检查是否需要分配Agent
        guard let agentID = task.assignedAgentID,
              agentStore.agent(withId: agentID) != nil else {
            // 需要选择Agent
            pendingAgentAssignmentTaskID = task.id
            showAgentSelectionAlert = true
            return
        }
        
        pendingTasks.append(task)
        saveTasks()
        
        LogInfo("[TaskManager] 添加任务: \(task.title)")
    }
    
    /// 从Subtask创建任务
    func createTask(from subtask: Subtask) {
        var task = TaskItem(from: subtask)
        
        // 尝试使用默认Agent
        if let defaultAgent = agentStore.usableAgents.first {
            task.assignAgent(id: defaultAgent.id, name: defaultAgent.name)
            addTask(task)
        } else {
            // 没有可用Agent，显示提醒
            pendingAgentAssignmentTaskID = task.id
            showAgentSelectionAlert = true
            
            // 先保存到pending，等选择Agent后再正式添加
            pendingTasks.append(task)
            saveTasks()
        }
    }
    
    /// 为任务分配Agent
    func assignAgentToTask(taskID: String, agent: Agent) {
        if let index = pendingTasks.firstIndex(where: { $0.id == taskID }) {
            pendingTasks[index].assignAgent(id: agent.id, name: agent.name)
            saveTasks()
            LogInfo("[TaskManager] 任务 \(pendingTasks[index].title) 分配Agent: \(agent.name)")
        }
        pendingAgentAssignmentTaskID = nil
    }
    
    /// 开始执行任务
    func startTask(_ taskID: String) {
        guard let index = pendingTasks.firstIndex(where: { $0.id == taskID }) else { return }
        
        var task = pendingTasks.remove(at: index)
        task.updateStatus(.running)
        task.addLog(TaskLogEntry(
            id: UUID(),
            timestamp: Date(),
            level: .info,
            message: "任务开始执行",
            source: "TaskManager"
        ))
        
        runningTasks.append(task)
        saveTasks()
        
        // 发送通知
        NotificationCenter.default.post(
            name: NSNotification.Name("TaskStatusChanged"),
            object: taskID,
            userInfo: ["status": TaskStatus.running.rawValue]
        )
        
        LogInfo("[TaskManager] 开始执行任务: \(task.title)")
    }
    
    /// 完成任务
    func completeTask(_ taskID: String, result: String) {
        guard let index = runningTasks.firstIndex(where: { $0.id == taskID }) else { return }
        
        var task = runningTasks.remove(at: index)
        task.updateStatus(.completed)
        task.result = result
        task.addLog(TaskLogEntry(
            id: UUID(),
            timestamp: Date(),
            level: .info,
            message: "任务完成: \(result.prefix(100))...",
            source: "TaskManager"
        ))
        
        completedTasks.append(task)
        saveTasks()
        
        // 发送通知
        NotificationCenter.default.post(
            name: NSNotification.Name("TaskStatusChanged"),
            object: taskID,
            userInfo: ["status": TaskStatus.completed.rawValue]
        )
        
        LogInfo("[TaskManager] 任务完成: \(task.title)")
    }
    
    /// 任务失败
    func failTask(_ taskID: String, error: String) {
        guard let index = runningTasks.firstIndex(where: { $0.id == taskID }) else { return }
        
        var task = runningTasks.remove(at: index)
        task.updateStatus(.failed)
        task.addLog(TaskLogEntry(
            id: UUID(),
            timestamp: Date(),
            level: .error,
            message: "任务失败: \(error)",
            source: "TaskManager"
        ))
        
        completedTasks.append(task)
        saveTasks()
        
        NotificationCenter.default.post(
            name: NSNotification.Name("TaskStatusChanged"),
            object: taskID,
            userInfo: ["status": TaskStatus.failed.rawValue]
        )
        
        LogInfo("[TaskManager] 任务失败: \(task.title) - \(error)")
    }
    
    /// 暂停任务
    func pauseTask(_ taskID: String) {
        if let index = pendingTasks.firstIndex(where: { $0.id == taskID }) {
            pendingTasks[index].togglePause()
            saveTasks()
        } else if let index = runningTasks.firstIndex(where: { $0.id == taskID }) {
            var task = runningTasks.remove(at: index)
            task.togglePause()
            pendingTasks.append(task)
            saveTasks()
        }
    }
    
    /// 销毁任务
    func destroyTask(_ taskID: String) {
        pendingTasks.removeAll { $0.id == taskID }
        runningTasks.removeAll { $0.id == taskID }
        saveTasks()
        
        LogInfo("[TaskManager] 销毁任务: \(taskID)")
    }
    
    /// 重新激活已完成任务（用于追加提问）
    func reactivateTask(_ taskID: String) -> TaskItem? {
        guard let index = completedTasks.firstIndex(where: { $0.id == taskID }) else { return nil }
        
        var task = completedTasks.remove(at: index)
        task.updateStatus(.pending)
        task.addMessage(TaskMessage(
            id: UUID(),
            role: .system,
            content: "任务已重新激活，等待继续处理",
            timestamp: Date(),
            agentID: nil,
            agentName: nil
        ))
        
        pendingTasks.append(task)
        saveTasks()
        
        LogInfo("[TaskManager] 重新激活任务: \(task.title)")
        return task
    }
    
    /// 清空所有已完成任务
    func clearCompletedTasks() {
        completedTasks.removeAll()
        saveTasks()
        
        LogInfo("[TaskManager] 清空已完成任务")
    }
    
    /// 添加CLI输出到任务日志
    func addCLIOutput(to taskID: String, output: String, source: String = "CLI") {
        let entry = TaskLogEntry(
            id: UUID(),
            timestamp: Date(),
            level: .output,
            message: output,
            source: source
        )
        
        // 更新对应任务的日志
        if let index = runningTasks.firstIndex(where: { $0.id == taskID }) {
            runningTasks[index].addLog(entry)
            // 同时添加到消息中
            let message = TaskMessage(
                id: UUID(),
                role: .cli,
                content: output,
                timestamp: Date(),
                agentID: nil,
                agentName: source
            )
            runningTasks[index].addMessage(message)
            saveTasks()
        }
        
        // 写入日志文件
        writeLogToFile(taskID: taskID, entry: entry)
    }
    
    /// 添加用户消息到任务对话
    func addUserMessage(to taskID: String, content: String) {
        let message = TaskMessage(
            id: UUID(),
            role: .user,
            content: content,
            timestamp: Date(),
            agentID: nil,
            agentName: nil
        )
        
        if let index = pendingTasks.firstIndex(where: { $0.id == taskID }) {
            pendingTasks[index].addMessage(message)
            saveTasks()
        } else if let index = completedTasks.firstIndex(where: { $0.id == taskID }) {
            completedTasks[index].addMessage(message)
            saveTasks()
        }
    }
    
    /// 添加助手消息到任务对话
    func addAssistantMessage(to taskID: String, content: String, agent: Agent) {
        let message = TaskMessage(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date(),
            agentID: agent.id,
            agentName: agent.name
        )
        
        if let index = runningTasks.firstIndex(where: { $0.id == taskID }) {
            runningTasks[index].addMessage(message)
            saveTasks()
        } else if let index = pendingTasks.firstIndex(where: { $0.id == taskID }) {
            pendingTasks[index].addMessage(message)
            saveTasks()
        } else if let index = completedTasks.firstIndex(where: { $0.id == taskID }) {
            completedTasks[index].addMessage(message)
            saveTasks()
        }
    }
    
    /// 获取任务的所有消息
    func getTaskMessages(_ taskID: String) -> [TaskMessage] {
        if let task = pendingTasks.first(where: { $0.id == taskID }) {
            return task.messages
        } else if let task = runningTasks.first(where: { $0.id == taskID }) {
            return task.messages
        } else if let task = completedTasks.first(where: { $0.id == taskID }) {
            return task.messages
        }
        return []
    }
    
    /// 获取任务
    func getTask(_ taskID: String) -> TaskItem? {
        if let task = pendingTasks.first(where: { $0.id == taskID }) {
            return task
        } else if let task = runningTasks.first(where: { $0.id == taskID }) {
            return task
        } else if let task = completedTasks.first(where: { $0.id == taskID }) {
            return task
        }
        return nil
    }
    
    // MARK: - 持久化
    
    private func saveTasks() {
        do {
            let allTasks = [
                "pending": pendingTasks,
                "running": runningTasks,
                "completed": completedTasks
            ]
            let data = try JSONEncoder().encode(allTasks)
            UserDefaults.standard.set(data, forKey: "task_manager_tasks")
        } catch {
            LogError("[TaskManager] 保存任务失败: \(error)")
        }
    }
    
    private func loadTasks() {
        guard let data = UserDefaults.standard.data(forKey: "task_manager_tasks") else { return }
        
        do {
            let decoder = JSONDecoder()
            let allTasks = try decoder.decode([String: [TaskItem]].self, from: data)
            
            self.pendingTasks = allTasks["pending"] ?? []
            self.runningTasks = allTasks["running"] ?? []
            self.completedTasks = allTasks["completed"] ?? []
            
            LogInfo("[TaskManager] 加载任务: 待执行 \(pendingTasks.count), 执行中 \(runningTasks.count), 已完成 \(completedTasks.count)")
        } catch {
            LogError("[TaskManager] 加载任务失败: \(error)")
        }
    }
    
    // MARK: - 日志文件
    
    private func writeLogToFile(taskID: String, entry: TaskLogEntry) {
        let logFileURL = logsDirectory.appendingPathComponent("\(taskID).log")
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        
        let logLine = "[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue.uppercased())] \(entry.message)\n"
        
        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
    
    /// 获取任务日志文件内容
    func getTaskLogContent(_ taskID: String) -> String {
        let logFileURL = logsDirectory.appendingPathComponent("\(taskID).log")
        return (try? String(contentsOf: logFileURL)) ?? ""
    }
}
