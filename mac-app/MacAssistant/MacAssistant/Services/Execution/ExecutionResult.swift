//
//  ExecutionResult.swift
//  MacAssistant
//
//  统一的执行结果类型 - 所有执行器（Agent、Skill、Service、Task）都返回此类型
//

import Foundation

/// 执行来源类型
enum ExecutionSource: String, Codable {
    case agent        // LLM Agent 回复
    case skill        // Skill 执行结果
    case service      // 服务管理操作
    case task         // 任务/子任务执行
    case system       // 系统消息
}

/// 统一的执行结果
struct ExecutionResult: Codable {
    let source: ExecutionSource
    let success: Bool
    let message: String              // 主要消息（用于主会话显示）
    let detail: String?              // 详细内容（可选）
    let metadata: [String: String]   // 扩展信息
    let timestamp: Date
    
    // 进度信息（用于流式更新）
    let isProgress: Bool
    let progressPercent: Int?
    
    // 关联ID
    let taskId: String?              // 任务ID
    let serviceId: String?           // 服务ID
    
    init(
        source: ExecutionSource,
        success: Bool,
        message: String,
        detail: String? = nil,
        metadata: [String: String] = [:],
        isProgress: Bool = false,
        progressPercent: Int? = nil,
        taskId: String? = nil,
        serviceId: String? = nil
    ) {
        self.source = source
        self.success = success
        self.message = message
        self.detail = detail
        self.metadata = metadata
        self.timestamp = Date()
        self.isProgress = isProgress
        self.progressPercent = progressPercent
        self.taskId = taskId
        self.serviceId = serviceId
    }
}

// MARK: - 便捷构造器

extension ExecutionResult {
    /// Agent 回复
    static func agentReply(_ message: String, taskId: String? = nil) -> ExecutionResult {
        ExecutionResult(source: .agent, success: true, message: message, taskId: taskId)
    }
    
    /// Skill 执行结果
    static func skillOutput(_ output: String, success: Bool = true) -> ExecutionResult {
        ExecutionResult(source: .skill, success: success, message: output)
    }
    
    /// 服务操作结果
    static func serviceStatus(serviceId: String, status: String, success: Bool) -> ExecutionResult {
        ExecutionResult(
            source: .service,
            success: success,
            message: status,
            serviceId: serviceId
        )
    }
    
    /// 任务进度更新
    static func taskProgress(taskId: String, percent: Int, message: String) -> ExecutionResult {
        ExecutionResult(
            source: .task,
            success: true,
            message: message,
            isProgress: true,
            progressPercent: percent,
            taskId: taskId
        )
    }
    
    /// 系统消息
    static func systemMessage(_ message: String) -> ExecutionResult {
        ExecutionResult(source: .system, success: true, message: message)
    }
    
    /// 错误结果
    static func error(_ error: String, source: ExecutionSource = .system) -> ExecutionResult {
        ExecutionResult(source: source, success: false, message: error)
    }
}
