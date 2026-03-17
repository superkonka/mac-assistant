//
//  BackgroundTaskNotifier.swift
//  MacAssistant
//
//  后台任务通知管理器 - 确保后台执行任务的状态同步到对话列表
//

import Foundation
import Combine

/// 后台任务状态变化通知
struct BackgroundTaskStatusChange {
    let sessionID: String
    let title: String
    let status: TaskSessionStatus
    let resultSummary: String?
    let errorMessage: String?
    let timestamp: Date
}

/// 后台任务通知管理器
@MainActor
final class BackgroundTaskNotifier: ObservableObject {
    static let shared = BackgroundTaskNotifier()
    
    /// 通知中心
    let taskStatusPublisher = PassthroughSubject<BackgroundTaskStatusChange, Never>()
    
    /// 已处理过的任务完成状态（避免重复通知）
    private var processedCompletions: Set<String> = []
    
    /// 最后处理时间
    private var lastProcessTime: [String: Date] = [:]
    
    private init() {}
    
    /// 通知任务状态变化
    func notifyStatusChange(
        sessionID: String,
        title: String,
        status: TaskSessionStatus,
        resultSummary: String? = nil,
        errorMessage: String? = nil
    ) {
        // 防止重复处理已完成的任务（5分钟内不重复）
        if status == .completed || status == .failed {
            let key = "\(sessionID)_\(status.rawValue)"
            if let lastTime = lastProcessTime[key],
               Date().timeIntervalSince(lastTime) < 300 {
                return
            }
            lastProcessTime[key] = Date()
        }
        
        let change = BackgroundTaskStatusChange(
            sessionID: sessionID,
            title: title,
            status: status,
            resultSummary: resultSummary,
            errorMessage: errorMessage,
            timestamp: Date()
        )
        
        taskStatusPublisher.send(change)
        
        LogInfo("[BackgroundTaskNotifier] 状态变化: \(sessionID) -> \(status.rawValue)")
    }
    
    /// 检查是否应该插入主对话
    func shouldInsertToMainConversation(status: TaskSessionStatus) -> Bool {
        switch status {
        case .completed, .failed, .partial:
            // 完成、失败、部分完成时插入主对话
            return true
        case .waitingUser:
            // 等待用户输入时也插入（需要用户处理）
            return true
        case .queued, .running:
            // 运行中不插入（只更新任务标签）
            return false
        }
    }
    
    /// 生成主对话消息内容
    func generateMainConversationMessage(
        title: String,
        status: TaskSessionStatus,
        resultSummary: String?,
        errorMessage: String?
    ) -> String {
        switch status {
        case .completed:
            let summary = resultSummary ?? "任务已完成"
            return """
            ✅ **\(title)** 已完成
            
            \(summary)
            """
            
        case .failed:
            let error = errorMessage ?? "执行失败"
            return """
            ❌ **\(title)** 执行失败
            
            \(error)
            """
            
        case .partial:
            let partial = resultSummary ?? errorMessage ?? "部分完成，需要继续处理"
            return """
            ⚠️ **\(title)** 部分完成
            
            \(partial)
            
            💡 点击任务卡片中的「继续处理」可继续执行
            """
            
        case .waitingUser:
            let prompt = errorMessage ?? "需要更多信息"
            return """
            ⏸️ **\(title)** 等待输入
            
            \(prompt)
            """
            
        default:
            return ""
        }
    }
}

// MARK: - CommandRunner 扩展

extension CommandRunner {
    
    /// 在 TaskSession 状态变化时调用此方法
    @MainActor
    func notifyTaskSessionStatusChange(
        sessionID: String,
        title: String,
        status: TaskSessionStatus,
        resultSummary: String? = nil,
        errorMessage: String? = nil
    ) {
        let notifier = BackgroundTaskNotifier.shared
        
        // 发送状态变化通知
        notifier.notifyStatusChange(
            sessionID: sessionID,
            title: title,
            status: status,
            resultSummary: resultSummary,
            errorMessage: errorMessage
        )
        
        // 检查是否需要插入主对话
        guard notifier.shouldInsertToMainConversation(status: status) else {
            return
        }
        
        // 检查是否已经为这个状态插入过消息（避免重复）
        let messageKey = "task_session_\(sessionID)_\(status.rawValue)"
        if hasMessageWithKey(messageKey) {
            return
        }
        
        // 生成并插入主对话消息
        let messageContent = notifier.generateMainConversationMessage(
            title: title,
            status: status,
            resultSummary: resultSummary,
            errorMessage: errorMessage
        )
        
        guard !messageContent.isEmpty else { return }
        
        // 插入主对话
        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: messageContent,
            timestamp: Date(),
            metadata: [
                "task_session_id": sessionID,
                "task_status": status.rawValue,
                "message_key": messageKey,
                "is_task_notification": "true"
            ]
        )
        
        messages.append(message)
        
        // 发送通知让 UI 刷新
        NotificationCenter.default.post(
            name: NSNotification.Name("TaskSessionStatusChanged"),
            object: sessionID,
            userInfo: [
                "status": status.rawValue,
                "title": title
            ]
        )
        
        LogInfo("[CommandRunner] 任务状态消息已插入主对话: \(sessionID) -> \(status.rawValue)")
    }
    
    /// 检查是否已有特定 key 的消息
    @MainActor
    private func hasMessageWithKey(_ key: String) -> Bool {
        return messages.contains { msg in
            msg.metadata?["message_key"] == key
        }
    }
}
