//
//  SubtaskResultAggregator.swift
//  MacAssistant
//
//  子任务结果聚合器 - 统一收口所有子任务反馈
//  所有子任务结果交给 Planner 统一分析，避免零散消息打扰用户
//

import Foundation

/// 子任务执行结果
struct SubtaskExecutionResult {
    let subtaskID: String
    let title: String
    let description: String
    let status: SubtaskStatus
    let result: String?
    let executedAt: Date
    let duration: TimeInterval?
}

/// 父任务的所有子任务结果
struct ParentTaskResults {
    let parentTaskID: String
    let originalRequest: String
    var subtaskResults: [SubtaskExecutionResult]
    let createdAt: Date
    var completedAt: Date?
    
    var isComplete: Bool {
        completedAt != nil
    }
    
    var allSuccessful: Bool {
        subtaskResults.allSatisfy { $0.status == .completed }
    }
    
    var summary: String {
        let total = subtaskResults.count
        let success = subtaskResults.filter { $0.status == .completed }.count
        let failed = subtaskResults.filter { $0.status == .failed }.count
        return "共 \(total) 个子任务，成功 \(success)，失败 \(failed)"
    }
}

/// 子任务结果聚合器
/// 
/// 职责：
/// 1. 收集所有子任务的执行结果（不直接展示给用户）
/// 2. 当父任务的所有子任务完成时，统一交给 Planner 分析
/// 3. 提供统一的、有价值的回复给用户
@MainActor
final class SubtaskResultAggregator {
    static let shared = SubtaskResultAggregator()
    
    private var pendingResults: [String: ParentTaskResults] = [:]  // parentTaskID -> results
    private let coordinator = SubtaskCoordinator.shared
    
    private init() {
        setupNotificationObserver()
    }
    
    // MARK: - 通知监听
    
    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSubtaskStatusChange),
            name: NSNotification.Name("SubtaskStatusChanged"),
            object: nil
        )
    }
    
    @objc private func handleSubtaskStatusChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let subtaskID = notification.object as? String,
              let title = userInfo["title"] as? String,
              let description = userInfo["description"] as? String,
              let statusString = userInfo["status"] as? String,
              let parentTaskID = userInfo["parentTaskID"] as? String,
              let status = SubtaskStatus(rawValue: statusString) else {
            return
        }
        
        let result = userInfo["result"] as? String
        
        // 只处理 completed 和 failed 状态
        guard status == .completed || status == .failed else { return }
        
        // 收集结果
        let executionResult = SubtaskExecutionResult(
            subtaskID: subtaskID,
            title: title,
            description: description,
            status: status,
            result: result,
            executedAt: Date(),
            duration: nil
        )
        
        collectResult(parentTaskID: parentTaskID, result: executionResult)
    }
    
    // MARK: - 结果收集
    
    /// 注册父任务（在开始拆解前调用）
    func registerParentTask(id: String, originalRequest: String) {
        pendingResults[id] = ParentTaskResults(
            parentTaskID: id,
            originalRequest: originalRequest,
            subtaskResults: [],
            createdAt: Date(),
            completedAt: nil
        )
        LogInfo("[SubtaskResultAggregator] 注册父任务: \(id)")
    }
    
    /// 收集子任务结果
    private func collectResult(parentTaskID: String, result: SubtaskExecutionResult) {
        guard pendingResults[parentTaskID] != nil else {
            // 如果没有注册，可能是单任务（非拆解），忽略
            return
        }
        
        pendingResults[parentTaskID]?.subtaskResults.append(result)
        LogInfo("[SubtaskResultAggregator] 收集结果: \(result.title) -> \(result.status.rawValue)")
        
        // 检查是否所有子任务都完成了
        checkCompletion(parentTaskID: parentTaskID)
    }
    
    /// 检查父任务是否完成
    private func checkCompletion(parentTaskID: String) {
        guard var parentResults = pendingResults[parentTaskID] else { return }
        
        // 获取该父任务下的所有子任务
        let allSubtasks = coordinator.getSubtasks(forParent: parentTaskID)
        let completedSubtasks = Set(parentResults.subtaskResults.map { $0.subtaskID })
        
        // 检查是否全部完成
        let allCompleted = allSubtasks.allSatisfy { subtask in
            completedSubtasks.contains(subtask.id) || subtask.status == .completed || subtask.status == .failed
        }
        
        guard allCompleted else { return }
        
        // 标记完成
        parentResults.completedAt = Date()
        pendingResults[parentTaskID] = parentResults
        
        // 交给 Planner 统一处理
        Task {
            await processWithPlanner(parentTaskID: parentTaskID, results: parentResults)
        }
    }
    
    // MARK: - Planner 统一处理
    
    /// 交给 Planner 统一分析所有子任务结果
    private func processWithPlanner(parentTaskID: String, results: ParentTaskResults) async {
        LogInfo("[SubtaskResultAggregator] 交给 Planner 处理父任务: \(parentTaskID)")
        
        // 构建上下文给 Planner
        let context = buildPlannerContext(results: results)
        
        // 发送给 Planner（通过通知中心，由 CommandRunner 接收）
        NotificationCenter.default.post(
            name: NSNotification.Name("PlannerProcessSubtaskResults"),
            object: parentTaskID,
            userInfo: [
                "originalRequest": results.originalRequest,
                "context": context,
                "summary": results.summary,
                "subtaskCount": results.subtaskResults.count
            ]
        )
        
        // 清理
        pendingResults.removeValue(forKey: parentTaskID)
    }
    
    /// 构建 Planner 上下文
    private func buildPlannerContext(results: ParentTaskResults) -> String {
        var context = ""
        
        context += "## 用户原始请求\n"
        context += "\(results.originalRequest)\n\n"
        
        context += "## 子任务执行结果汇总\n"
        context += "\(results.summary)\n\n"
        
        for (index, subtask) in results.subtaskResults.enumerated() {
            context += "### \(index + 1). \(subtask.title)\n"
            context += "- 描述: \(subtask.description)\n"
            context += "- 状态: \(subtask.status == .completed ? "✅ 成功" : "❌ 失败")\n"
            if let result = subtask.result, !result.isEmpty {
                // 截断过长的结果
                let truncatedResult = result.count > 500 ? String(result.prefix(500)) + "..." : result
                context += "- 结果: \(truncatedResult)\n"
            }
            context += "\n"
        }
        
        context += "## 请给出统一的回复\n"
        context += "基于以上子任务执行结果，请给用户一个简洁、有价值的总结，不要罗列每个子任务的细节。重点说明：\n"
        context += "1. 整体完成情况\n"
        context += "2. 关键发现或结果\n"
        context += "3. 如果有优化建议或下一步行动，请简明扼要地说明\n"
        
        return context
    }
}

// MARK: - SubtaskCoordinator 扩展

extension SubtaskCoordinator {
    /// 获取指定父任务的所有子任务
    func getSubtasks(forParent parentTaskID: String) -> [Subtask] {
        return (pendingSubtasks + runningSubtasks + completedSubtasks)
            .filter { $0.parentTaskID == parentTaskID }
    }
}
