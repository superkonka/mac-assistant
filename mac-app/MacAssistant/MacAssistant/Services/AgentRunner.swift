//
//  AgentRunner.swift
//  MacAssistant
//
//  轻量级 Agent 运行器 - 直接调用 Kimi CLI + Skill 系统
//

import Foundation
import Combine
import AppKit

/// AgentRunner - MacAssistant 核心 AI Agent
/// 
/// 架构:
/// 1. 直接调用 Kimi CLI 进行 LLM 推理
/// 2. 通过 prompt 工程让 Kimi 决定何时使用工具
/// 3. SkillRegistry 管理系统工具
/// 4. 支持工具调用链（多轮对话）
class AgentRunner: ObservableObject {
    static let shared = AgentRunner()
    
    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var status: String = "就绪"
    
    private let storage = StorageManager.shared
    private var currentTask: Process?
    private let skills = SkillRegistry.shared
    
    /// 系统 Prompt - 告诉 Kimi 如何使用工具
    private var systemPrompt: String {
        """
        你是 MacAssistant，一个运行在 macOS 上的智能助手。
        
        你可以使用以下工具来帮助用户：
        
        \(skills.allSkillsDescription())
        
        工具调用格式（必须严格遵守）：
        <tool>
        name: 工具名称
        args: 参数（可选）
        </tool>
        
        例如：
        <tool>
        name: system
        args: 获取CPU和内存信息
        </tool>
        
        规则：
        1. 如果用户请求需要工具，先调用工具，再基于结果回答
        2. 可以连续调用多个工具
        3. 如果没有匹配的工具，直接回答
        4. 永远不要在 tool 标签外使用"工具"这个词
        """
    }
    
    init() {
        LogInfo("🚀 AgentRunner 初始化完成")
        LogInfo("🧰 可用 Skills:\n\(skills.allSkillsDescription())")
        messages = storage.getRecentMessages(limit: 50)
    }
    
    // MARK: - 发送消息
    
    func sendMessage(_ content: String) {
        guard !content.isEmpty else { return }
        
        LogInfo("📤 用户发送消息: \(content.prefix(50))...")
        
        CLIProgressManager.shared.startTask()
        
        let userMessage = ChatMessage(
            id: UUID(),
            role: .user,
            content: content,
            timestamp: Date()
        )
        
        let context = ConversationContext(
            previousMessages: messages.suffix(5).map { $0 },
            currentTopic: nil,
            userIntent: nil
        )
        storage.saveMessage(userMessage, context: context)
        
        DispatchQueue.main.async { [weak self] in
            self?.messages.append(userMessage)
            self?.isLoading = true
            self?.status = "AI 思考中..."
        }
        
        if content.hasPrefix("/") {
            handleCommand(content)
        } else {
            processWithAgent(content, context: context)
        }
    }
    
    // MARK: - Agent 处理流程
    
    private func processWithAgent(_ content: String, context: ConversationContext?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 构建完整 prompt
            let fullPrompt = self.buildPrompt(userInput: content)
            
            // 调用 Kimi
            CLIProgressManager.shared.addStep(type: .thinking, title: "🤔 AI 思考中", detail: nil)
            
            let llmResponse = self.callKimi(prompt: fullPrompt, timeout: 180)
            
            // 检查是否需要工具调用
            let finalResponse = self.processToolCalls(in: llmResponse)
            
            DispatchQueue.main.async {
                self.handleAIResponse(finalResponse, context: context)
            }
        }
    }
    
    // MARK: - 构建 Prompt
    
    private func buildPrompt(userInput: String) -> String {
        var prompt = systemPrompt
        prompt += "\n\n"
        
        // 添加历史上下文
        let recentMessages = messages.suffix(3)
        if !recentMessages.isEmpty {
            prompt += "最近对话:\n"
            for msg in recentMessages {
                let role = msg.role == .user ? "用户" : "助手"
                prompt += "\(role): \(msg.content)\n"
            }
            prompt += "\n"
        }
        
        prompt += "用户: \(userInput)\n"
        prompt += "助手:"
        
        return prompt
    }
    
    // MARK: - 调用 Kimi
    
    private func callKimi(prompt: String, timeout: TimeInterval) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var output = ""
        
        let task = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()
        
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "kimi -p \(escape(prompt))"]
        task.standardOutput = pipe
        task.standardError = errorPipe
        
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "zh_CN.UTF-8"
        let localBin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        environment["PATH"] = "\(localBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"
        task.environment = environment
        
        // 流式输出处理
        pipe.fileHandleForReading.readabilityHandler = { handle in
            if let data = try? handle.read(upToCount: 4096), !data.isEmpty {
                if let str = String(data: data, encoding: .utf8) {
                    output += str
                    CLIProgressManager.shared.appendRawOutput(str)
                }
            }
        }
        
        do {
            try task.run()
            self.currentTask = task
            
            // 等待完成
            DispatchQueue.global().async {
                task.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                semaphore.signal()
            }
            
            // 超时控制
            let waitResult = semaphore.wait(timeout: .now() + timeout)
            
            if waitResult == .timedOut && task.isRunning {
                task.terminate()
                return UserFacingErrorFormatter.inlineMessage(
                    for: NSError(
                        domain: NSURLErrorDomain,
                        code: URLError.timedOut.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: "请求超时"]
                    ),
                    providerName: "本地 Kimi CLI"
                )
            }
            
        } catch {
            LogError("Kimi 启动失败", error: error)
            return UserFacingErrorFormatter.inlineMessage(for: error, providerName: "本地 Kimi CLI")
        }
        
        return UserFacingErrorFormatter.normalizeCLIOutput(output, providerName: "本地 Kimi CLI")
    }
    
    // MARK: - 处理工具调用
    
    private func processToolCalls(in response: String) -> String {
        var result = response
        var toolCallCount = 0
        
        // 正则匹配工具调用
        let pattern = "<tool>\\s*name:\\s*(\\w+)\\s*(?:args:\\s*(.*?))?\\s*</tool>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return response
        }
        
        let matches = regex.matches(in: response, options: [], range: NSRange(location: 0, length: response.utf16.count))
        
        for match in matches.reversed() {
            toolCallCount += 1
            
            // 提取工具名
            guard let nameRange = Range(match.range(at: 1), in: response) else { continue }
            let toolName = String(response[nameRange]).trimmingCharacters(in: .whitespaces)
            
            // 提取参数
            var args: [String] = []
            if let argsRange = Range(match.range(at: 2), in: response) {
                let argsString = String(response[argsRange]).trimmingCharacters(in: .whitespaces)
                if !argsString.isEmpty {
                    args = argsString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
            }
            
            // 执行工具
            CLIProgressManager.shared.addStep(
                type: .toolCall,
                title: "🔧 调用 \(toolName)",
                detail: args.joined(separator: ", ")
            )
            
            let toolResult = executeTool(name: toolName, args: args)
            
            // 替换工具调用为结果
            guard let fullRange = Range(match.range, in: result) else { continue }
            
            // 如果需要更详细的处理，可以让 Kimi 继续处理结果
            if toolCallCount <= 3 {  // 限制工具调用次数
                let followUpPrompt = """
                用户原始请求需要工具调用。
                
                工具调用: \(toolName)
                工具返回结果:
                ```
                \(toolResult)
                ```
                
                请基于以上结果回答用户。
                """
                
                let followUpResponse = callKimi(prompt: followUpPrompt, timeout: 60)
                result.replaceSubrange(fullRange, with: "\n\(followUpResponse)")
            } else {
                result.replaceSubrange(fullRange, with: "\n[工具结果: \(toolResult.prefix(100))...]")
            }
        }
        
        return result
    }
    
    // MARK: - 执行工具
    
    private func executeTool(name: String, args: [String]) -> String {
        guard let skill = skills.getSkill(name) else {
            return "未知工具: \(name)"
        }
        
        do {
            let command = args.joined(separator: " ")
            let result = runAsync {
                try await skill.execute(command, args: args)
            }
            return result ?? "工具执行无结果"
        } catch {
            return "工具执行错误: \(error.localizedDescription)"
        }
    }
    
    // MARK: - 处理 AI 回复
    
    private func handleAIResponse(_ output: String, context: ConversationContext?) {
        isLoading = false
        status = "就绪"
        currentTask = nil
        
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalOutput = trimmedOutput.isEmpty ? "抱歉，没有收到回复。" : trimmedOutput
        
        let response = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: finalOutput,
            timestamp: Date()
        )
        
        messages.append(response)
        if let ctx = context {
            storage.saveMessage(response, context: ctx)
        }
        
        CLIProgressManager.shared.completeTask(success: true)
    }
    
    // MARK: - 斜杠命令
    
    private func handleCommand(_ command: String) {
        let parts = command.dropFirst().split(separator: " ", maxSplits: 1)
        let cmd = String(parts.first ?? "")
        let args = parts.count > 1 ? String(parts[1]) : ""
        
        var result = ""
        
        switch cmd {
        case "截图", "screenshot", "ss":
            result = handleScreenshot()
        case "剪贴板", "clipboard", "cb":
            result = handleClipboard()
        case "系统", "system", "sys":
            if let skill = skills.getSkill("system") {
                result = (try? runAsync { try await skill.execute("系统信息", args: []) }) ?? "获取失败"
            }
        case "清空", "clear", "c":
            messages.removeAll()
            storage.clearHistory()
            result = "对话历史已清空"
        case "帮助", "help", "h", "?":
            result = helpText()
        default:
            // 尝试直接匹配 skill
            if let skill = skills.getSkill(cmd) {
                result = (try? runAsync { try await skill.execute(args, args: [args]) }) ?? "执行失败"
            } else {
                result = "未知命令: \(cmd)\n可用命令: /截图, /剪贴板, /系统, /清空, /帮助"
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.isLoading = false
            self?.status = "就绪"
            let response = ChatMessage(id: UUID(), role: .assistant, content: result, timestamp: Date())
            self?.messages.append(response)
        }
    }
    
    private func handleScreenshot() -> String {
        _ = runShellCommand("screencapture -c -x")
        if let imageData = NSPasteboard.general.data(forType: .tiff) {
            DispatchQueue.global().async { [weak self] in
                // TODO: 实现图像分析
                let result = "已截图（图像分析功能开发中）"
                DispatchQueue.main.async {
                    let response = ChatMessage(id: UUID(), role: .assistant, content: result, timestamp: Date())
                    self?.messages.append(response)
                }
            }
            return "已截图，分析中..."
        }
        return "截图失败"
    }
    
    private func handleClipboard() -> String {
        if let content = NSPasteboard.general.string(forType: .string) {
            let prompt = "分析以下剪贴板内容:\n```\n\(content.prefix(500))\n```"
            DispatchQueue.global().async { [weak self] in
                let result = self?.callKimi(prompt: prompt, timeout: 60) ?? "分析失败"
                DispatchQueue.main.async {
                    let response = ChatMessage(id: UUID(), role: .assistant, content: result, timestamp: Date())
                    self?.messages.append(response)
                }
            }
            return "正在分析剪贴板..."
        }
        return "剪贴板为空"
    }
    
    private func helpText() -> String {
        """
        📋 可用命令:
        
        /截图, /ss      - 截图并分析
        /剪贴板, /cb    - 分析剪贴板内容
        /系统, /sys     - 系统信息
        /清空, /c       - 清空历史
        /帮助, /h       - 显示帮助
        
        🧰 可用 Skills:
        \(skills.allSkillsDescription())
        
        💡 直接输入文字与 AI 对话
        """
    }
    
    // MARK: - 辅助方法
    
    private func escape(_ str: String) -> String {
        return "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    
    private func runShellCommand(_ command: String) -> String? {
        let task = Process()
        let pipe = Pipe()
        
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
    
    private func runAsync<T>(_ operation: @escaping () async throws -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        
        Task {
            do {
                result = try await operation()
            } catch {
                LogError("Async operation failed", error: error)
            }
            semaphore.signal()
        }
        
        semaphore.wait()
        return result
    }
    
    func loadHistory() {
        messages = storage.getRecentMessages(limit: 50)
    }
    
    func clearHistory() {
        messages.removeAll()
        storage.clearHistory()
    }
    
    func screenshotAndAsk() { sendMessage("/截图") }
    func clipboardAndAsk() { sendMessage("/剪贴板") }
}
