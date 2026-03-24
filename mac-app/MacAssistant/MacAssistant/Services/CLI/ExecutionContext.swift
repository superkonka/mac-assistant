//
//  ExecutionContext.swift
//  MacAssistant
//
//  Planner 构建的执行上下文，包含 CLI 需要的所有信息
//

import Foundation

/// 执行上下文 - Planner 构建，传递给 CLI
struct ExecutionContext: Codable {
    // 任务标识
    let taskId: String
    let operation: String           // "start", "stop", "install", "check"
    let serviceId: String
    
    // 对话上下文（CLI 可以据此调整输出风格）
    var conversationSummary: String?  // "用户正在开发 Web 应用，需要数据库"
    var userIntent: String?           // "我想启动 PostgreSQL 用于本地开发"
    
    // 前置条件（Planner 已验证）
    var prerequisites: Prerequisites
    
    // 环境配置
    var environment: [String: String]  // 环境变量
    var workingDirectory: String?      // 工作目录
    var timeout: TimeInterval
    
    // 历史上下文
    var previousAttempts: [PreviousAttempt]?  // 之前失败的重试记录
    var relatedServices: [String]?            // 相关服务（如依赖的 Redis）
    
    // 用户偏好
    var userPreferences: UserPreferences
    
    // 回传通道（CLI 可以实时上报进度）
    var progressCallbackURL: String?   // 本地 HTTP/WebSocket 地址
}

// MARK: - 子结构

struct Prerequisites: Codable {
    let isInstalled: Bool
    let isRunning: Bool
    let portAvailable: Int?
    let diskSpaceMB: Int?
    let detectedAdapter: String?       // Planner 检测到的最佳适配器
}

struct PreviousAttempt: Codable {
    let timestamp: Date
    let error: String
    let exitCode: Int
}

struct UserPreferences: Codable {
    let verboseOutput: Bool            // 是否显示详细输出
    let autoConfirm: Bool              // 是否自动确认危险操作
    let preferredAdapter: String?      // 用户偏好的工具
    let notificationEnabled: Bool      // 是否发送通知
}

// MARK: - 构建器

extension ExecutionContext {
    /// Builder 模式，Planner 使用
    static func builder(taskId: String, operation: String, serviceId: String) -> Builder {
        Builder(taskId: taskId, operation: operation, serviceId: serviceId)
    }
    
    struct Builder {
        private var context: ExecutionContext
        
        init(taskId: String, operation: String, serviceId: String) {
            self.context = ExecutionContext(
                taskId: taskId,
                operation: operation,
                serviceId: serviceId,
                conversationSummary: nil,
                userIntent: nil,
                prerequisites: Prerequisites(
                    isInstalled: false,
                    isRunning: false,
                    portAvailable: nil,
                    diskSpaceMB: nil,
                    detectedAdapter: nil
                ),
                environment: [:],
                workingDirectory: nil,
                timeout: 60,
                previousAttempts: nil,
                relatedServices: nil,
                userPreferences: UserPreferences(
                    verboseOutput: false,
                    autoConfirm: false,
                    preferredAdapter: nil,
                    notificationEnabled: true
                ),
                progressCallbackURL: nil
            )
        }
        
        func withConversation(_ summary: String, intent: String? = nil) -> Builder {
            var builder = self
            builder.context.conversationSummary = summary
            builder.context.userIntent = intent
            return builder
        }
        
        func withPrerequisites(_ prerequisites: Prerequisites) -> Builder {
            var builder = self
            builder.context.prerequisites = prerequisites
            return builder
        }
        
        func withEnvironment(_ env: [String: String]) -> Builder {
            var builder = self
            builder.context.environment = env
            return builder
        }
        
        func withTimeout(_ timeout: TimeInterval) -> Builder {
            var builder = self
            builder.context.timeout = timeout
            return builder
        }
        
        func withPreferences(_ preferences: UserPreferences) -> Builder {
            var builder = self
            builder.context.userPreferences = preferences
            return builder
        }
        
        func withProgressCallback(_ url: String) -> Builder {
            var builder = self
            builder.context.progressCallbackURL = url
            return builder
        }
        
        func build() -> ExecutionContext {
            return context
        }
    }
}
