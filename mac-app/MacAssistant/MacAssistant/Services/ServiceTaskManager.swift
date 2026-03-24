//
//  ServiceTaskManager.swift
//  MacAssistant
//
//  服务任务管理器 - 将服务操作转换为任务会话
//

import Foundation
import Combine

/// 服务任务管理器
/// 负责将服务管理操作（启动/停止/重启）转换为后台任务会话
@MainActor
final class ServiceTaskManager: ObservableObject {
    static let shared = ServiceTaskManager()
    
    // MARK: - Published State
    @Published var activeServiceTasks: [String: String] = [:]  // serviceID -> taskSessionID
    
    // MARK: - Dependencies
    private let commandRunner = CommandRunner.shared
    private let serviceManager = ServiceManager.shared
    
    private init() {}
    
    // MARK: - 公共服务操作
    
    /// 启动服务（创建任务会话）
    func startService(_ service: ServiceDefinition) {
        guard activeServiceTasks[service.id] == nil else {
            LogWarning("[ServiceTaskManager] 服务 \(service.id) 已有任务在进行中")
            return
        }
        
        let taskSessionID = createServiceTaskSession(
            service: service,
            action: .start,
            prompt: buildStartServicePrompt(service)
        )
        
        activeServiceTasks[service.id] = taskSessionID
        
        // 启动 AI 执行
        Task {
            await executeServiceTask(
                taskSessionID: taskSessionID,
                service: service,
                action: .start
            )
        }
        
        LogInfo("[ServiceTaskManager] 已创建启动服务任务: \(service.id) -> \(taskSessionID)")
    }
    
    /// 停止服务（创建任务会话）
    func stopService(_ service: ServiceDefinition) {
        guard activeServiceTasks[service.id] == nil else {
            LogWarning("[ServiceTaskManager] 服务 \(service.id) 已有任务在进行中")
            return
        }
        
        let currentPid = serviceManager.runtimeInfo(for: service.id)?.pid
        
        let taskSessionID = createServiceTaskSession(
            service: service,
            action: .stop,
            prompt: buildStopServicePrompt(service, pid: currentPid)
        )
        
        activeServiceTasks[service.id] = taskSessionID
        
        Task {
            await executeServiceTask(
                taskSessionID: taskSessionID,
                service: service,
                action: .stop
            )
        }
        
        LogInfo("[ServiceTaskManager] 已创建停止服务任务: \(service.id) -> \(taskSessionID)")
    }
    
    /// 重启服务（创建任务会话）
    func restartService(_ service: ServiceDefinition) {
        guard activeServiceTasks[service.id] == nil else {
            LogWarning("[ServiceTaskManager] 服务 \(service.id) 已有任务在进行中")
            return
        }
        
        let taskSessionID = createServiceTaskSession(
            service: service,
            action: .restart,
            prompt: buildRestartServicePrompt(service)
        )
        
        activeServiceTasks[service.id] = taskSessionID
        
        Task {
            await executeServiceTask(
                taskSessionID: taskSessionID,
                service: service,
                action: .restart
            )
        }
        
        LogInfo("[ServiceTaskManager] 已创建重启服务任务: \(service.id) -> \(taskSessionID)")
    }
    
    /// 检查服务状态
    func checkServiceStatus(_ service: ServiceDefinition) {
        let taskSessionID = createServiceTaskSession(
            service: service,
            action: .checkStatus,
            prompt: buildCheckStatusPrompt(service)
        )
        
        Task {
            await executeServiceTask(
                taskSessionID: taskSessionID,
                service: service,
                action: .checkStatus
            )
        }
    }
    
    // MARK: - 任务会话管理
    
    /// 创建服务管理任务会话
    private func createServiceTaskSession(
        service: ServiceDefinition,
        action: AgentTaskSession.ServiceAction,
        prompt: String
    ) -> String {
        let actionEmoji: String
        let actionName: String
        switch action {
        case .start:
            actionEmoji = "🚀"
            actionName = "启动"
        case .stop:
            actionEmoji = "🛑"
            actionName = "停止"
        case .restart:
            actionEmoji = "🔄"
            actionName = "重启"
        case .checkStatus:
            actionEmoji = "🔍"
            actionName = "检查"
        }
        
        let session = AgentTaskSession(
            title: "\(actionEmoji) \(actionName)「\(service.name)」",
            originalRequest: prompt,
            status: .queued,
            statusSummary: "等待 AI 接手 \(actionName) 服务...",
            mainAgentName: nil,
            delegateAgentID: "service-management",
            delegateAgentName: "服务管理",
            intentName: "服务管理",
            isExpanded: true,
            messages: [
                TaskSessionMessage(
                    role: .system,
                    content: "服务管理任务已创建，正在等待 AI 执行..."
                ),
                TaskSessionMessage(
                    role: .user,
                    content: prompt,
                    agentName: "用户"
                )
            ],
            serviceID: service.id,
            serviceAction: action
        )
        
        // 添加到 CommandRunner 的任务会话列表
        commandRunner.addTaskSession(session)
        
        // 发送系统消息到主会话（关联任务）
        let linkedMessage = ChatMessage(
            id: UUID(),
            role: .system,
            content: "\(actionEmoji) 服务「\(service.name)」\(actionName)任务已创建，在任务标签页查看进度",
            timestamp: Date(),
            linkedTaskSessionID: session.id
        )
        commandRunner.appendMessage(linkedMessage)
        
        return session.id
    }
    
    /// 执行任务
    private func executeServiceTask(
        taskSessionID: String,
        service: ServiceDefinition,
        action: AgentTaskSession.ServiceAction
    ) async {
        // 更新任务状态为运行中
        await MainActor.run {
            commandRunner.updateTaskSessionStatus(
                sessionID: taskSessionID,
                status: .running,
                summary: "AI 正在执行 \(actionDisplayName(action)) 操作..."
            )
            commandRunner.appendTaskSessionMessage(
                sessionID: taskSessionID,
                role: .assistant,
                content: "开始 \(actionDisplayName(action)) 服务「\(service.name)」",
                agentName: "服务管理"
            )
        }
        
        // 构建 AI 请求
        let prompt = buildPrompt(for: service, action: action)
        
        // 调用 AI 执行（复用 CommandRunner 的能力）
        await executeWithAI(
            taskSessionID: taskSessionID,
            service: service,
            action: action,
            prompt: prompt
        )
    }
    
    /// 使用 AI 执行任务（真正调用 OpenClaw）
    private func executeWithAI(
        taskSessionID: String,
        service: ServiceDefinition,
        action: AgentTaskSession.ServiceAction,
        prompt: String
    ) async {
        let startTime = Date()
        
        do {
            // 通过 CommandRunner 执行 AI 请求
            // 这会调用 OpenClaw gateway，AI 可以使用浏览器等工具
            let result = try await executeServiceTaskViaAI(
                taskSessionID: taskSessionID,
                prompt: prompt
            )
            
            // 解析 AI 返回的结果
            await processAIResult(
                taskSessionID: taskSessionID,
                service: service,
                action: action,
                result: result
            )
            
        } catch {
            await handleExecutionError(
                taskSessionID: taskSessionID,
                service: service,
                error: error
            )
        }
        
        // 清理活跃任务
        await MainActor.run {
            activeServiceTasks.removeValue(forKey: service.id)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        LogInfo("[ServiceTaskManager] 服务任务完成: \(service.id), 耗时: \(String(format: "%.1f", duration))s")
    }
    
    /// 通过 AI 执行服务任务
    private func executeServiceTaskViaAI(
        taskSessionID: String,
        prompt: String
    ) async throws -> String {
        // 获取当前 Agent
        let agent = AgentOrchestrator.shared.currentAgent
            ?? AgentStore.shared.defaultAgent
            ?? AgentStore.shared.agents.first!
        
        // 设置任务会话状态
        await MainActor.run {
            commandRunner.updateTaskSessionStatus(
                sessionID: taskSessionID,
                status: .running,
                summary: "\(agent.displayName) 正在处理服务管理任务...",
                isExpanded: true
            )
            
            commandRunner.appendTaskSessionMessage(
                sessionID: taskSessionID,
                role: .assistant,
                content: "⏳ \(agent.name) 正在通过 OpenClaw 处理服务请求...\n\nAI 可以使用 shell、browser 等工具来完成服务管理操作。",
                agentName: agent.name
            )
        }
        
        // 生成 session key
        let sessionKey = "service-task-\(taskSessionID)"
        
        // 构建完整的系统提示词
        // 这个提示词告诉 AI 可以使用哪些工具，以及如何报告结果
        let systemPrompt = """
        # 服务管理专家模式

        你是服务管理专家，正在执行本地服务的生命周期管理操作。

        ## 可用工具

        1. **shell** - 执行 shell 命令
           - 启动服务: `cd /path && ./start.sh`
           - 检查状态: `pgrep process_name` 或 `lsof -i :port`
           - 停止服务: `kill PID` 或 `pkill process_name`
           - 查看日志: `tail -n 100 /path/to/log`

        2. **browser** - 浏览器自动化（Playwright）
           - 当服务需要网页授权时使用（如微信扫码登录）
           - 可以打开浏览器、导航到 URL、点击元素、截图等
           - 如果用户说"需要扫码"或类似的话，主动打开浏览器

        3. **read_file** - 读取文件内容
           - 查看配置文件
           - 查看日志文件分析错误

        ## 执行流程

        对于每个操作，按以下步骤执行：

        1. **环境检查**
           - 检查工作目录是否存在
           - 检查配置文件是否存在
           - 检查端口是否被占用

        2. **执行操作**
           - 根据操作类型执行启动/停止/重启命令
           - 使用 nohup 或 & 确保服务在后台运行
           - 捕获进程 PID

        3. **结果验证**
           - 等待 2-5 秒让服务启动
           - 执行健康检查（HTTP 请求或端口检查）
           - 验证进程是否存在

        4. **报告结果**
           必须包含以下信息：
           - ✅ 或 ❌ 表示成功/失败
           - 进程 PID（如果适用）
           - 服务最终状态（运行中/已停止/错误）
           - 错误信息（如果失败）
           - 建议的下一步操作（如果需要）

        ## 特殊场景处理

        - **需要网页授权**: 主动使用 browser 工具打开授权页面
        - **端口被占用**: 先停止占用进程，再启动服务
        - **启动失败**: 查看日志文件，分析错误原因
        - **超时**: 如果 30 秒内没有成功，报告超时

        ## 输出格式

        ```
        ## 执行摘要
        状态: ✅ 成功 / ❌ 失败
        操作: 启动/停止/重启
        服务: [服务名]

        ## 执行步骤
        1. [步骤1] - 结果
        2. [步骤2] - 结果
        ...

        ## 最终结果
        - PID: [进程ID 或 "N/A"]
        - 端口: [端口号 或 "N/A"]
        - 状态: [运行中/已停止/错误]

        ## 备注
        [任何需要说明的信息]
        ```
        """
        
        let fullPrompt = "\(systemPrompt)\n\n--- 服务配置 ---\n\(prompt)\n\n请开始执行，并严格按照上述格式报告结果。"
        
        // 调用 OpenClaw Gateway（真正的 AI 调用）
        return try await callOpenClawGateway(
            agent: agent,
            sessionKey: sessionKey,
            prompt: fullPrompt,
            taskSessionID: taskSessionID
        )
    }
    
    /// 调用 OpenClaw Gateway（真正的 AI 调用）
    private func callOpenClawGateway(
        agent: Agent,
        sessionKey: String,
        prompt: String,
        taskSessionID: String
    ) async throws -> String {
        // 添加用户消息到任务会话
        await MainActor.run {
            commandRunner.appendTaskSessionMessage(
                sessionID: taskSessionID,
                role: .user,
                content: prompt,
                agentName: "用户"
            )
        }
        
        // 调用 CommandRunner 的公共 API 执行 AI 请求
        // 这会真正调用 OpenClaw Gateway，AI 可以使用浏览器等工具
        let result = try await commandRunner.executeServiceTask(
            taskSessionID: taskSessionID,
            prompt: prompt,
            agent: agent
        )
        
        return result
    }
    
    /// 处理 AI 返回的结果
    private func processAIResult(
        taskSessionID: String,
        service: ServiceDefinition,
        action: AgentTaskSession.ServiceAction,
        result: String
    ) async {
        // 解析 AI 返回的结果，提取关键信息
        // 这里简化处理，实际应该解析结构化数据
        
        let isSuccess = result.contains("成功") || result.contains("✅")
        let pid = extractPID(from: result)
        
        let finalStatus: ServiceRuntimeStatus
        switch action {
        case .start, .restart:
            finalStatus = isSuccess ? .running : .error
        case .stop:
            finalStatus = isSuccess ? .stopped : .error
        case .checkStatus:
            finalStatus = .unknown
        }
        
        // 更新 ServiceManager 状态
        await MainActor.run {
            serviceManager.handleAIOperationResult(ServiceAIOperationResult(
                success: isSuccess,
                serviceId: service.id,
                action: action.rawValue,
                pid: pid,
                status: finalStatus,
                message: isSuccess ? "操作成功" : "操作失败",
                error: isSuccess ? nil : "请查看任务详情"
            ))
            
            // 更新任务会话
            commandRunner.appendTaskSessionMessage(
                sessionID: taskSessionID,
                role: .assistant,
                content: result,
                agentName: "服务管理"
            )
            
            commandRunner.updateTaskSessionStatus(
                sessionID: taskSessionID,
                status: isSuccess ? .completed : .failed,
                summary: isSuccess ? "\(actionDisplayName(action)) 完成" : "\(actionDisplayName(action)) 失败",
                isExpanded: false,
                resultSummary: result.prefix(200).description + (result.count > 200 ? "..." : ""),
                errorMessage: isSuccess ? nil : "操作失败，请查看详情"
            )
        }
    }
    
    /// 从结果中提取 PID
    private func extractPID(from result: String) -> Int? {
        // 简单的 PID 提取逻辑
        let patterns = [
            "PID: (\\d+)",
            "pid: (\\d+)",
            "进程 (\\d+)",
            "PID (\\d+)"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)),
               let pidRange = Range(match.range(at: 1), in: result) {
                return Int(result[pidRange])
            }
        }
        
        return nil
    }
    
    /// 处理执行错误
    private func handleExecutionError(
        taskSessionID: String,
        service: ServiceDefinition,
        error: Error
    ) async {
        await MainActor.run {
            let errorMessage = "❌ 执行失败: \(error.localizedDescription)"
            
            commandRunner.appendTaskSessionMessage(
                sessionID: taskSessionID,
                role: .assistant,
                content: errorMessage,
                agentName: "服务管理"
            )
            
            commandRunner.updateTaskSessionStatus(
                sessionID: taskSessionID,
                status: .failed,
                summary: "执行失败",
                errorMessage: error.localizedDescription
            )
            
            // 同步错误到主会话
            let errorChatMessage = ChatMessage(
                id: UUID(),
                role: .system,
                content: "❌ 服务「\(service.name)」操作遇到问题，可在任务标签页查看详情",
                timestamp: Date()
            )
            commandRunner.appendMessage(errorChatMessage)
        }
    }
    
    // MARK: - 提示词构建
    
    private func buildPrompt(for service: ServiceDefinition, action: AgentTaskSession.ServiceAction) -> String {
        switch action {
        case .start:
            return buildStartServicePrompt(service)
        case .stop:
            let pid = serviceManager.runtimeInfo(for: service.id)?.pid
            return buildStopServicePrompt(service, pid: pid)
        case .restart:
            return buildRestartServicePrompt(service)
        case .checkStatus:
            return buildCheckStatusPrompt(service)
        }
    }
    
    private func buildStartServicePrompt(_ service: ServiceDefinition) -> String {
        """
        请帮我启动服务「\(service.name)」（ID: \(service.id)）。
        
        服务配置：
        - 工作目录: \(service.path ?? "未指定")
        - 启动命令: \(service.startCommand ?? "未配置")
        - 健康检查: \(service.healthCheck?.type.rawValue ?? "无") \(service.healthCheck?.endpoint ?? "")
        \(service.port != nil ? "- 端口: \(service.port!)" : "")
        
        请按以下步骤执行：
        1. 检查工作目录是否存在
        2. 检查是否有残留进程，如有先停止
        3. 执行启动命令，确保在后台运行
        4. 捕获进程 PID
        5. 等待服务启动（最多 30 秒）
        6. 执行健康检查验证服务正常运行
        7. 报告执行结果
        
        如果启动失败，请分析原因并提供解决方案。
        """
    }
    
    private func buildStopServicePrompt(_ service: ServiceDefinition, pid: Int?) -> String {
        let pidInfo = pid != nil ? "已知 PID: \(pid!)" : "未记录 PID"
        
        return """
        请帮我停止服务「\(service.name)」（ID: \(service.id)）。
        
        服务配置：
        - 停止命令: \(service.stopCommand ?? "未配置")
        - \(pidInfo)
        \(service.port != nil ? "- 监听端口: \(service.port!)" : "")
        
        请按以下步骤执行：
        1. 查找服务相关进程
        2. 尝试优雅停止（使用 stopCommand 或 kill PID）
        3. 等待 5 秒
        4. 如未停止，强制停止（kill -9）
        5. 确认端口已释放
        6. 报告执行结果
        """
    }
    
    private func buildRestartServicePrompt(_ service: ServiceDefinition) -> String {
        """
        请帮我重启服务「\(service.name)」（ID: \(service.id)）。
        
        服务配置：
        - 工作目录: \(service.path ?? "未指定")
        - 启动命令: \(service.startCommand ?? "未配置")
        - 停止命令: \(service.stopCommand ?? "未配置")
        - 健康检查: \(service.healthCheck?.type.rawValue ?? "无")
        \(service.port != nil ? "- 端口: \(service.port!)" : "")
        
        请按以下步骤执行：
        1. 先停止现有进程（如果有）
        2. 等待 2 秒确保完全停止
        3. 启动服务
        4. 等待健康检查通过
        5. 报告执行结果
        """
    }
    
    private func buildCheckStatusPrompt(_ service: ServiceDefinition) -> String {
        var checks: [String] = []
        
        if let port = service.port {
            checks.append("- 检查端口 \(port) 是否监听")
        }
        if let command = service.startCommand {
            let processName = command.components(separatedBy: " ").first ?? command
            checks.append("- 检查进程 \"\(processName)\" 是否存在")
        }
        if let endpoint = service.healthCheck?.endpoint, let port = service.port {
            checks.append("- 测试 HTTP 健康端点 http://127.0.0.1:\(port)\(endpoint)")
        }
        
        let checksText = checks.isEmpty ? "- 检查工作目录是否存在" : checks.joined(separator: "\n")
        
        return """
        请帮我详细检查服务「\(service.name)」（ID: \(service.id)）的状态。
        
        服务配置：
        - 工作目录: \(service.path ?? "未指定")
        - 端口: \(service.port?.description ?? "无")
        - 健康检查类型: \(service.healthCheck?.type.rawValue ?? "无")
        
        请执行以下检查：
        \(checksText)
        
        如果服务未运行，尝试分析原因：
        - 检查日志文件
        - 检查配置文件
        - 检查依赖服务是否已启动
        
        报告检查结果和建议。
        """
    }
    
    // MARK: - 辅助方法
    
    private func actionDisplayName(_ action: AgentTaskSession.ServiceAction) -> String {
        switch action {
        case .start: return "启动"
        case .stop: return "停止"
        case .restart: return "重启"
        case .checkStatus: return "检查"
        }
    }
    
    /// 获取服务的活跃任务会话ID
    func activeTaskSessionID(for serviceID: String) -> String? {
        return activeServiceTasks[serviceID]
    }
    
    /// 检查服务是否有活跃任务
    func hasActiveTask(for serviceID: String) -> Bool {
        return activeServiceTasks[serviceID] != nil
    }
}
