//
//  ContinueIntentAnalyzer.swift
//  MacAssistant
//
//  "继续处理"意图分析器 - 分析用户可继续处理的所有事项
//

import Foundation

/// 可继续处理的选项
struct ContinueOption: Identifiable {
    let id: String
    let type: OptionType
    let title: String
    let description: String
    let priority: Priority
    let timestamp: Date
    let action: ContinueAction
    
    enum OptionType {
        case resumableTask      // 可恢复的任务会话
        case pendingService     // 待处理的服务管理
        case incompleteRequest  // 未完成的主会话请求
        case suggestedAction    // 建议的新操作
    }
    
    enum Priority: Int, Comparable {
        case urgent = 0     // 紧急：等待用户输入、失败需重试
        case high = 1       // 高：服务异常、最近中断
        case medium = 2     // 中：服务停止、可以优化
        case low = 3        // 低：历史对话、可选操作
        
        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
    
    enum ContinueAction {
        case resumeTask(sessionID: String)
        case startService(serviceID: String, serviceName: String)
        case stopService(serviceID: String, serviceName: String)
        case restartService(serviceID: String, serviceName: String)
        case handleMainRequest(messageID: UUID)
        case newRequest(prompt: String)
    }
}

/// 继续处理意图分析结果
struct ContinueIntentAnalysis {
    let options: [ContinueOption]
    let timestamp: Date
    
    /// 是否有明确唯一的选项
    var hasClearSingleOption: Bool {
        let urgentAndHigh = options.filter { $0.priority <= .high }
        return urgentAndHigh.count == 1
    }
    
    /// 获取排序后的选项
    var sortedOptions: [ContinueOption] {
        options.sorted { (a, b) in
            if a.priority != b.priority {
                return a.priority < b.priority
            }
            return a.timestamp > b.timestamp
        }
    }
    
    /// 最高优先级的选项
    var highestPriorityOption: ContinueOption? {
        sortedOptions.first
    }
    
    /// 按类型分组
    var optionsByType: [ContinueOption.OptionType: [ContinueOption]] {
        Dictionary(grouping: options) { $0.type }
    }
}

/// "继续处理"意图分析器
/// 分析所有可继续处理的事项
final class ContinueIntentAnalyzer {
    static let shared = ContinueIntentAnalyzer()
    
    private init() {}
    
    /// 分析"继续处理"意图
    /// 返回所有可继续处理的选项
    func analyze(
        taskSessions: [AgentTaskSession],
        services: [ServiceDefinition],
        serviceRuntimes: [String: ServiceRuntimeInfo],
        messages: [ChatMessage],
        activeServiceTasks: Set<String> = []  // 活跃的服务任务ID
    ) -> ContinueIntentAnalysis {
        var options: [ContinueOption] = []
        let now = Date()
        
        // 1. 分析可恢复的任务会话（最高优先级）
        let resumableOptions = analyzeResumableTasks(taskSessions)
        options.append(contentsOf: resumableOptions)
        
        // 2. 分析服务管理中待处理的事项（简化逻辑，只检查已停止的服务）
        for service in services.prefix(10) {  // 限制检查数量
            guard !activeServiceTasks.contains(service.id) else { continue }
            
            let status = serviceRuntimes[service.id]?.status ?? .unknown
            if status == .stopped && service.category == .mcp {
                options.append(ContinueOption(
                    id: "service-start-\(service.id)",
                    type: .pendingService,
                    title: "启动「\(service.name)」",
                    description: service.description ?? "MCP 服务",
                    priority: .medium,
                    timestamp: now,
                    action: .startService(serviceID: service.id, serviceName: service.name)
                ))
            }
        }
        
        return ContinueIntentAnalysis(
            options: options,
            timestamp: now
        )
    }
    
    // MARK: - 私有分析方法
    
    /// 分析可恢复的任务会话
    private func analyzeResumableTasks(_ sessions: [AgentTaskSession]) -> [ContinueOption] {
        let resumableStatuses: [TaskSessionStatus] = [.failed, .waitingUser, .partial]
        
        return sessions
            .filter { session in
                resumableStatuses.contains(session.status) &&
                session.canResume &&
                !session.isHiddenFromTabs
            }
            .map { session in
                let priority: ContinueOption.Priority
                switch session.status {
                case .waitingUser:
                    priority = .urgent  // 等待用户输入最紧急
                case .failed:
                    priority = .high    // 失败需重试
                case .partial:
                    priority = .high    // 部分完成
                default:
                    priority = .medium
                }
                
                return ContinueOption(
                    id: "task-\(session.id)",
                    type: .resumableTask,
                    title: session.title,
                    description: session.statusSummary,
                    priority: priority,
                    timestamp: session.updatedAt,
                    action: .resumeTask(sessionID: session.id)
                )
            }
    }
    
    /// 分析服务管理中待处理的事项
    private func analyzePendingServices(
        _ services: [ServiceDefinition],
        runtimes: [String: ServiceRuntimeInfo],
        activeServiceTasks: Set<String>
    ) -> [ContinueOption] {
        var options: [ContinueOption] = []
        
        for service in services {
            let runtime = runtimes[service.id]
            let status = runtime?.status ?? .unknown
            
            // 检查是否有活跃任务正在处理
            let hasActiveTask = activeServiceTasks.contains(service.id)
            guard !hasActiveTask else { continue }
            
            switch status {
            case .stopped:
                // 已停止的服务，建议启动
                if service.autoStart || service.category == .mcp {
                    options.append(ContinueOption(
                        id: "service-start-\(service.id)",
                        type: .pendingService,
                        title: "启动「\(service.name)」",
                        description: "\(service.description ?? "服务")当前已停止",
                        priority: .medium,
                        timestamp: runtime?.lastCheckedAt ?? Date(),
                        action: .startService(serviceID: service.id, serviceName: service.name)
                    ))
                }
                
            case .error:
                // 异常的服务，建议重启或查看
                options.append(ContinueOption(
                    id: "service-restart-\(service.id)",
                    type: .pendingService,
                    title: "重启「\(service.name)」",
                    description: runtime?.errorMessage ?? "服务运行异常",
                    priority: .high,
                    timestamp: runtime?.lastCheckedAt ?? Date(),
                    action: .restartService(serviceID: service.id, serviceName: service.name)
                ))
                
            case .running where service.port != nil:
                // 检查健康状态，如果最近检查失败建议处理
                if let lastCheck = runtime?.lastCheckedAt,
                   Date().timeIntervalSince(lastCheck) > 300,  // 5分钟未检查
                   runtime?.healthCheckResult?.isHealthy == false {
                    options.append(ContinueOption(
                        id: "service-check-\(service.id)",
                        type: .pendingService,
                        title: "检查「\(service.name)」状态",
                        description: "健康检查未通过",
                        priority: .high,
                        timestamp: lastCheck,
                        action: .restartService(serviceID: service.id, serviceName: service.name)
                    ))
                }
                
            default:
                break
            }
        }
        
        return options
    }
    
    /// 分析主会话中的未完成请求
    private func analyzeIncompleteMainRequests(_ messages: [ChatMessage]) -> [ContinueOption] {
        // 获取最近20条消息
        let recentMessages = messages.suffix(20)
        var options: [ContinueOption] = []
        
        // 查找最近的助手询问消息
        for message in recentMessages.reversed() {
            if message.role == .assistant {
                let content = message.content.lowercased()
                
                // 检测是否是询问或等待用户回复
                if content.contains("请") && 
                   (content.contains("选择") || content.contains("确认") || content.contains("提供")) {
                    options.append(ContinueOption(
                        id: "main-request-\(message.id)",
                        type: .incompleteRequest,
                        title: "回复之前的询问",
                        description: message.content.prefix(50).description + "...",
                        priority: .medium,
                        timestamp: message.timestamp,
                        action: .handleMainRequest(messageID: message.id)
                    ))
                    break  // 只取最近的一个
                }
            }
        }
        
        return options
    }
    
    /// 根据上下文生成建议
    private func generateSuggestions(
        from existingOptions: [ContinueOption],
        services: [ServiceDefinition],
        runtimes: [String: ServiceRuntimeInfo]
    ) -> [ContinueOption] {
        var suggestions: [ContinueOption] = []
        
        // 如果有服务未运行，建议整体检查
        let stoppedServices = services.filter {
            runtimes[$0.id]?.status == .stopped && $0.category == .mcp
        }
        
        if stoppedServices.count > 1 {
            suggestions.append(ContinueOption(
                id: "suggestion-check-all-services",
                type: .suggestedAction,
                title: "检查所有 MCP 服务",
                description: "发现 \(stoppedServices.count) 个 MCP 服务已停止",
                priority: .low,
                timestamp: Date(),
                action: .newRequest(prompt: "帮我检查所有 MCP 服务的状态，启动已停止的服务")
            ))
        }
        
        return suggestions
    }
}

// MARK: - 消息格式化

extension ContinueIntentAnalysis {
    /// 生成用户展示的消息
    func formatAsUserMessage() -> String {
        var message = "🤔 发现以下可以继续处理的事项：\n\n"
        
        // 按优先级分组
        let grouped = Dictionary(grouping: sortedOptions) { $0.priority }
        let sortedPriorities = grouped.keys.sorted()
        
        for priority in sortedPriorities {
            let options = grouped[priority]!
            
            // 优先级标题
            switch priority {
            case .urgent:
                message += "**🔴 紧急**\n"
            case .high:
                message += "**🟠 高优先级**\n"
            case .medium:
                message += "**🟡 待处理**\n"
            case .low:
                message += "**🔵 其他**\n"
            }
            
            // 列出选项
            for (index, option) in options.enumerated() {
                let number = index + 1
                let icon = iconForType(option.type)
                message += "\(number). \(icon) \(option.title)\n"
                message += "   \(option.description)\n"
            }
            
            message += "\n"
        }
        
        message += "请回复数字选择，或告诉我具体要做什么。"
        
        return message
    }
    
    /// 生成"其他可能需要处理"的简洁消息
    func formatAsOtherOptionsMessage(excluding excludedID: String) -> String {
        let otherOptions = sortedOptions.filter { $0.id != excludedID }.prefix(3)
        
        guard !otherOptions.isEmpty else { return "" }
        
        var message = "💡 您可能还需要处理：\n"
        for option in otherOptions {
            message += "• \(option.title) [处理]\n"
        }
        
        return message
    }
    
    private func iconForType(_ type: ContinueOption.OptionType) -> String {
        switch type {
        case .resumableTask:
            return "🔄"
        case .pendingService:
            return "🚀"
        case .incompleteRequest:
            return "💬"
        case .suggestedAction:
            return "💡"
        }
    }
}
