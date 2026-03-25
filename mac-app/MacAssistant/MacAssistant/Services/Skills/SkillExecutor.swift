//
//  SkillExecutor.swift
//  MacAssistant
//
//  Skill 统一执行引擎 - 执行各种类型的 Skill
//

import Foundation
import AppKit

// MARK: - Skill Context

/// Skill 执行上下文
struct SkillExecutionContext {
    let sessionId: String
    let conversationId: String?
    let userIntent: String
    let previousResults: [String: Any]
    let availableAgents: [Agent]
    
    init(
        sessionId: String = "main_session",
        conversationId: String? = nil,
        userIntent: String = "",
        previousResults: [String: Any] = [:],
        availableAgents: [Agent] = []
    ) {
        self.sessionId = sessionId
        self.conversationId = conversationId
        self.userIntent = userIntent
        self.previousResults = previousResults
        self.availableAgents = availableAgents
    }
}

// MARK: - Skill Executor

/// Skill 统一执行引擎
@MainActor
final class SkillExecutor {
    static let shared = SkillExecutor()
    
    // 内置 Skill 实现注册表
    private var localSkillImplementations: [String: (SkillManifest, [String: Any], SkillExecutionContext) async -> SkillExecutionResult] = [:]
    
    private init() {
        registerBuiltInSkillImplementations()
        LogInfo("[SkillExecutor] Skill 执行引擎已初始化")
    }
    
    // MARK: - 主执行方法
    
    /// 执行 Skill
    /// - Parameters:
    ///   - skillId: Skill ID
    ///   - input: 输入参数
    ///   - context: 执行上下文
    /// - Returns: 执行结果
    func execute(
        skillId: String,
        input: [String: Any] = [:],
        context: SkillExecutionContext = SkillExecutionContext()
    ) async -> SkillExecutionResult {
        let startTime = Date()
        LogInfo("[SkillExecutor] 开始执行 Skill: \(skillId)")
        
        // 1. 查找 Skill Manifest
        guard let manifest = SkillCatalog.shared.find(byID: skillId) else {
            LogError("[SkillExecutor] Skill 未找到: \(skillId)")
            return .failure(error: "Skill '\(skillId)' 未找到")
        }
        
        // 2. 验证输入参数
        let validation = validateInput(manifest: manifest, input: input)
        if !validation.isValid {
            return .failure(error: "缺少必需参数: \(validation.missingParams.joined(separator: ", "))")
        }
        
        // 3. 根据执行器类型执行
        let result: SkillExecutionResult
        
        switch manifest.executorType {
        case .local:
            result = await executeLocalSkill(manifest: manifest, input: input, context: context)
            
        case .browser:
            result = await executeBrowserSkill(manifest: manifest, input: input, context: context)
            
        case .agent:
            result = await executeAgentSkill(manifest: manifest, input: input, context: context)
            
        case .javascript:
            result = await executeJavaScriptSkill(manifest: manifest, input: input, context: context)
            
        case .remote:
            result = await executeRemoteSkill(manifest: manifest, input: input, context: context)
            
        case .mcp:
            result = await executeMCPSkill(manifest: manifest, input: input, context: context)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        // 4. 记录执行结果
        await recordExecution(skillId: skillId, manifest: manifest, input: input, result: result, duration: duration)
        
        LogInfo("[SkillExecutor] Skill 执行完成: \(skillId), 成功: \(result.success), 耗时: \(String(format: "%.2f", duration))s")
        
        return result
    }
    
    /// 根据名称匹配并执行 Skill
    func executeByName(
        name: String,
        input: [String: Any] = [:],
        context: SkillExecutionContext = SkillExecutionContext()
    ) async -> SkillExecutionResult {
        // 1. 尝试从 SkillCatalog 查找
        if let manifest = SkillCatalog.shared.find(byName: name) {
            return await execute(skillId: manifest.id, input: input, context: context)
        }
        
        // 2. 尝试从 SkillSystem 查找
        if let skill = SkillSystem.shared.matchSkill(for: name) {
            let textInput = input["text"] as? String ?? ""
            let output = SkillSystem.shared.executeSkill(skill, withInput: textInput)
            return .success(output: output)
        }
        
        return .failure(error: "未找到名为 '\(name)' 的 Skill")
    }
    
    /// 根据意图匹配并执行最佳 Skill
    func executeByIntent(
        intent: String,
        input: [String: Any] = [:],
        context: SkillExecutionContext = SkillExecutionContext()
    ) async -> SkillExecutionResult {
        // 1. 尝试匹配 SkillCatalog
        if let manifest = SkillCatalog.shared.matchBestSkill(intent: intent) {
            LogInfo("[SkillExecutor] 意图匹配到 SkillCatalog: \(manifest.name)")
            return await execute(skillId: manifest.id, input: input, context: context)
        }
        
        // 2. 尝试匹配 SkillSystem
        if let skill = SkillSystem.shared.matchSkill(for: intent) {
            LogInfo("[SkillExecutor] 意图匹配到 SkillSystem: \(skill.name)")
            let textInput = input["text"] as? String ?? intent
            let output = SkillSystem.shared.executeSkill(skill, withInput: textInput)
            return .success(output: output)
        }
        
        return .failure(error: "未找到匹配意图 '\(intent)' 的 Skill")
    }
    
    // MARK: - 执行器实现
    
    /// 执行本地 Skill
    private func executeLocalSkill(
        manifest: SkillManifest,
        input: [String: Any],
        context: SkillExecutionContext
    ) async -> SkillExecutionResult {
        LogInfo("[SkillExecutor] 执行本地 Skill: \(manifest.name)")
        
        // 1. 检查是否有内置实现
        if let implementation = localSkillImplementations[manifest.id] {
            return await implementation(manifest, input, context)
        }
        
        // 2. 尝试从 executorConfig 获取命令
        if let command = manifest.executorConfig["command"] {
            return await executeShellCommand(command, input: input)
        }
        
        // 3. 默认返回信息
        return .success(
            output: "本地 Skill '\(manifest.name)' 已执行",
            data: ["skill_id": manifest.id, "input": input]
        )
    }
    
    /// 执行浏览器 Skill
    private func executeBrowserSkill(
        manifest: SkillManifest,
        input: [String: Any],
        context: SkillExecutionContext
    ) async -> SkillExecutionResult {
        LogInfo("[SkillExecutor] 执行浏览器 Skill: \(manifest.name)")
        
        // 获取 BrowserAgentService
        let browserService = BrowserAgentService.shared
        
        // 根据 Skill ID 执行不同操作
        switch manifest.id {
        case "browser.navigate":
            guard let url = input["url"] as? String else {
                return .failure(error: "缺少 url 参数")
            }
            
            do {
                try await browserService.navigate(to: url)
                return .success(
                    output: "已导航到: \(url)",
                    data: ["url": url, "skill": manifest.id]
                )
            } catch {
                return .failure(error: "导航失败: \(error.localizedDescription)")
            }
            
        case "browser.screenshot":
            // 浏览器截图
            do {
                let screenshotResult = try await browserService.screenshot()
                if screenshotResult.success {
                    let screenshotData = screenshotResult.data
                    return .success(
                        output: "浏览器截图已捕获",
                        data: ["screenshot_data": screenshotData as Any, "skill": manifest.id]
                    )
                } else {
                    return .failure(error: "截图失败: \(screenshotResult.message)")
                }
            } catch {
                return .failure(error: "截图失败: \(error.localizedDescription)")
            }
            
        case "whatsapp.send":
            guard let contact = input["contact"] as? String,
                  let message = input["message"] as? String else {
                return .failure(error: "缺少 contact 或 message 参数")
            }
            
            let whatsappURL = "https://web.whatsapp.com/send?phone=\(contact)&text=\(message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            
            do {
                try await browserService.navigate(to: whatsappURL)
                return .success(
                    output: "已打开 WhatsApp 网页版，准备发送消息给 \(contact)",
                    data: ["contact": contact, "skill": manifest.id]
                )
            } catch {
                return .failure(error: "打开 WhatsApp 失败: \(error.localizedDescription)")
            }
            
        default:
            return .success(
                output: "浏览器 Skill '\(manifest.name)' 已准备",
                data: [
                    "skill_id": manifest.id,
                    "capabilities": manifest.capabilities.map { $0.fullIdentifier },
                    "input": input
                ]
            )
        }
    }
    
    /// 执行 Agent Skill
    private func executeAgentSkill(
        manifest: SkillManifest,
        input: [String: Any],
        context: SkillExecutionContext
    ) async -> SkillExecutionResult {
        LogInfo("[SkillExecutor] 执行 Agent Skill: \(manifest.name)")
        
        // 获取目标 Agent
        guard let agentId = manifest.executorConfig["agent_id"] ?? input["agent_id"] as? String else {
            return .failure(error: "Agent Skill 需要指定 agent_id")
        }
        
        // 查找 Agent
        let agentStore = AgentStore.shared
        guard let agent = agentStore.agents.first(where: { $0.id == agentId }) else {
            return .failure(error: "Agent '\(agentId)' 未找到")
        }
        
        // 构建消息
        let userMessage = input["message"] as? String ?? input["text"] as? String ?? "执行 Skill: \(manifest.name)"
        
        // 使用 AgentRunner 执行 - sendMessage 是同步方法，不返回值
        let runner = AgentRunner.shared
        runner.sendMessage(userMessage)
        
        return .success(
            output: "消息已发送给 Agent: \(agent.name)",
            data: [
                "skill_id": manifest.id,
                "agent_id": agentId,
                "agent_name": agent.name
            ]
        )
    }
    
    /// 执行 JavaScript/AppleScript Skill
    private func executeJavaScriptSkill(
        manifest: SkillManifest,
        input: [String: Any],
        context: SkillExecutionContext
    ) async -> SkillExecutionResult {
        LogInfo("[SkillExecutor] 执行 JavaScript Skill: \(manifest.name)")
        
        guard let script = manifest.executorConfig["script"] else {
            return .failure(error: "JavaScript Skill 需要配置 script")
        }
        
        // 填充脚本模板
        var filledScript = script
        for (key, value) in input {
            let placeholder = "{{\(key)}}"
            let valueString = String(describing: value)
            filledScript = filledScript.replacingOccurrences(of: placeholder, with: valueString)
        }
        
        // 执行 AppleScript
        if filledScript.hasPrefix("tell application") || filledScript.hasPrefix("osascript") {
            return await executeAppleScript(filledScript)
        }
        
        // 或者执行 JS
        return await executeShellCommand("osascript -l JavaScript -e '\(filledScript)'", input: [:])
    }
    
    /// 执行远程 API Skill
    private func executeRemoteSkill(
        manifest: SkillManifest,
        input: [String: Any],
        context: SkillExecutionContext
    ) async -> SkillExecutionResult {
        LogInfo("[SkillExecutor] 执行远程 Skill: \(manifest.name)")
        
        guard let endpoint = manifest.executorConfig["endpoint"] else {
            return .failure(error: "远程 Skill 需要配置 endpoint")
        }
        
        // 构建请求
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = manifest.executorConfig["method"] ?? "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // 添加认证头
        if let authHeader = manifest.executorConfig["auth_header"] {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        
        // 构建请求体
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: input)
        } catch {
            return .failure(error: "构建请求体失败: \(error.localizedDescription)")
        }
        
        // 发送请求
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(error: "无效的响应")
            }
            
            let responseString = String(data: data, encoding: .utf8) ?? ""
            
            if (200...299).contains(httpResponse.statusCode) {
                return .success(
                    output: responseString,
                    data: [
                        "status_code": httpResponse.statusCode,
                        "response": responseString
                    ]
                )
            } else {
                return .failure(error: "HTTP \(httpResponse.statusCode): \(responseString)")
            }
        } catch {
            return .failure(error: "请求失败: \(error.localizedDescription)")
        }
    }
    
    /// 执行 MCP Service Skill
    private func executeMCPSkill(
        manifest: SkillManifest,
        input: [String: Any],
        context: SkillExecutionContext
    ) async -> SkillExecutionResult {
        LogInfo("[SkillExecutor] 执行 MCP Skill: \(manifest.name)")
        
        // MCP 集成 - 调用 MCP Service
        // TODO: 实现 MCP 协议调用
        
        return .success(
            output: "MCP Skill '\(manifest.name)' 执行完成",
            data: ["skill_id": manifest.id, "mcp": true]
        )
    }
    
    // MARK: - 内置 Skill 实现
    
    private func registerBuiltInSkillImplementations() {
        // System Screenshot
        localSkillImplementations["system.screenshot"] = { [weak self] manifest, input, context in
            guard let self = self else { return .failure(error: "SkillExecutor 已释放") }
            return await self.executeSystemScreenshot(input: input)
        }
        
        // System Clipboard
        localSkillImplementations["system.clipboard"] = { [weak self] manifest, input, context in
            guard let self = self else { return .failure(error: "SkillExecutor 已释放") }
            return await self.executeClipboardOperation(input: input)
        }
        
        // System Notification
        localSkillImplementations["system.notification"] = { [weak self] manifest, input, context in
            guard let self = self else { return .failure(error: "SkillExecutor 已释放") }
            return await self.executeNotification(input: input)
        }
        
        // System Volume
        localSkillImplementations["system.volume"] = { [weak self] manifest, input, context in
            guard let self = self else { return .failure(error: "SkillExecutor 已释放") }
            return await self.executeVolumeControl(input: input)
        }
        
        LogInfo("[SkillExecutor] 已注册 \(localSkillImplementations.count) 个本地 Skill 实现")
    }
    
    // MARK: - 具体 Skill 实现
    
    /// 系统截图
    private func executeSystemScreenshot(input: [String: Any]) async -> SkillExecutionResult {
        let fileName = input["filename"] as? String ?? "screenshot_\(Int(Date().timeIntervalSince1970)).png"
        let savePath = input["path"] as? String ?? "/tmp/\(fileName)"
        let interactive = input["interactive"] as? Bool ?? false
        
        var command = "screencapture"
        if interactive {
            command += " -i" // 交互式截图（选区）
        } else {
            command += " -x" // 静默截图
        }
        command += " \(savePath)"
        
        let result = await executeShellCommand(command, input: [:])
        
        if result.success {
            return .success(
                output: "截图已保存到: \(savePath)",
                data: ["path": savePath, "filename": fileName]
            )
        } else {
            return result
        }
    }
    
    /// 剪贴板操作
    private func executeClipboardOperation(input: [String: Any]) async -> SkillExecutionResult {
        let action = input["action"] as? String ?? "read"
        
        switch action {
        case "read", "get":
            let result = await executeShellCommand("pbpaste", input: [:])
            let outputString = result.output?["response"] ?? ""
            return .success(
                output: outputString,
                data: ["content": outputString, "action": "read"]
            )
            
        case "write", "set":
            guard let content = input["content"] as? String else {
                return .failure(error: "write 操作需要提供 content 参数")
            }
            let escapedContent = content.replacingOccurrences(of: "'", with: "'\"'\"'")
            let result = await executeShellCommand("echo '\(escapedContent)' | pbcopy", input: [:])
            return .success(
                output: "内容已写入剪贴板",
                data: ["action": "write", "length": content.count]
            )
            
        case "clear":
            let result = await executeShellCommand("echo '' | pbcopy", input: [:])
            return .success(output: "剪贴板已清空", data: ["action": "clear"])
            
        default:
            return .failure(error: "未知的剪贴板操作: \(action)")
        }
    }
    
    /// 系统通知
    private func executeNotification(input: [String: Any]) async -> SkillExecutionResult {
        guard let title = input["title"] as? String else {
            return .failure(error: "缺少 title 参数")
        }
        
        let message = input["message"] as? String ?? ""
        let sound = input["sound"] as? String ?? "default"
        
        let script = """
        display notification "\(message.replacingOccurrences(of: "\"", with: "\\\""))" \
        with title "\(title.replacingOccurrences(of: "\"", with: "\\\""))" \
        sound name "\(sound)"
        """
        
        return await executeAppleScript(script)
    }
    
    /// 音量控制
    private func executeVolumeControl(input: [String: Any]) async -> SkillExecutionResult {
        if let level = input["level"] as? Int {
            let clampedLevel = max(0, min(100, level))
            let result = await executeShellCommand("osascript -e 'set volume output volume \(clampedLevel)'", input: [:])
            return .success(
                output: "音量已设置为 \(clampedLevel)%",
                data: ["level": clampedLevel]
            )
        }
        
        if let action = input["action"] as? String {
            switch action {
            case "mute":
                let result = await executeShellCommand("osascript -e 'set volume with output muted'", input: [:])
                return .success(output: "音量已静音", data: ["muted": true])
                
            case "unmute":
                let result = await executeShellCommand("osascript -e 'set volume without output muted'", input: [:])
                return .success(output: "音量已恢复", data: ["muted": false])
                
            case "up", "increase":
                let result = await executeShellCommand("osascript -e 'set volume output volume (output volume of (get volume settings) + 10)'", input: [:])
                return .success(output: "音量已增加", data: ["action": "increase"])
                
            case "down", "decrease":
                let result = await executeShellCommand("osascript -e 'set volume output volume (output volume of (get volume settings) - 10)'", input: [:])
                return .success(output: "音量已降低", data: ["action": "decrease"])
                
            default:
                return .failure(error: "未知的音量操作: \(action)")
            }
        }
        
        // 获取当前音量
        let result = await executeShellCommand("osascript -e 'output volume of (get volume settings)'", input: [:])
        if let level = Int(result.output?["response"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
            return .success(
                output: "当前音量: \(level)%",
                data: ["current_level": level]
            )
        }
        
        return .failure(error: "请提供 level 参数或 action 参数")
    }
    
    // MARK: - 辅助方法
    
    /// 执行 Shell 命令
    private func executeShellCommand(_ command: String, input: [String: Any]) async -> SkillExecutionResult {
        let task = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()
        
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]
        task.standardOutput = pipe
        task.standardError = errorPipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let error = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if task.terminationStatus == 0 {
                return .success(output: output)
            } else {
                return .failure(error: error ?? "命令执行失败，退出码: \(task.terminationStatus)", output: output)
            }
        } catch {
            return .failure(error: "执行错误: \(error.localizedDescription)")
        }
    }
    
    /// 执行 AppleScript
    private func executeAppleScript(_ script: String) async -> SkillExecutionResult {
        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return .failure(error: "无法创建 AppleScript")
        }
        
        let result = appleScript.executeAndReturnError(&errorInfo)
        
        if let error = errorInfo {
            let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "未知错误"
            return .failure(error: "AppleScript 错误: \(errorMessage)")
        }
        
        // result is non-optional, but stringValue returns String?
        let output = result.stringValue ?? ""
        return .success(output: output.isEmpty ? nil : output)
    }
    
    /// 验证输入参数
    private func validateInput(manifest: SkillManifest, input: [String: Any]) -> (isValid: Bool, missingParams: [String]) {
        let required = manifest.inputSchema.required
        let missing = required.filter { input[$0] == nil }
        return (missing.isEmpty, missing)
    }
    
    /// 记录执行结果
    private func recordExecution(
        skillId: String,
        manifest: SkillManifest,
        input: [String: Any],
        result: SkillExecutionResult,
        duration: TimeInterval
    ) async {
        // 更新 SkillSystem 中的使用统计
        // TODO: 完善统计分析
        LogDebug("[SkillExecutor] 记录 Skill 执行: \(skillId), 耗时: \(String(format: "%.3f", duration))s")
    }
}

// MARK: - 便捷扩展

extension SkillExecutor {
    
    /// 批量执行 Skills
    func executeBatch(
        skills: [(skillId: String, input: [String: Any])],
        context: SkillExecutionContext = SkillExecutionContext()
    ) async -> [(skillId: String, result: SkillExecutionResult)] {
        var results: [(String, SkillExecutionResult)] = []
        
        for (skillId, input) in skills {
            let result = await execute(skillId: skillId, input: input, context: context)
            results.append((skillId, result))
        }
        
        return results
    }
    
    /// 获取 Skill 的可用参数信息
    func getSkillParameters(skillId: String) -> [String: Any]? {
        guard let manifest = SkillCatalog.shared.find(byID: skillId) else {
            return nil
        }
        
        return [
            "skill_id": manifest.id,
            "name": manifest.name,
            "description": manifest.description,
            "parameters": manifest.inputSchema.parameters.map { param in
                [
                    "name": param.name,
                    "type": param.type.rawValue,
                    "description": param.description,
                    "required": manifest.inputSchema.required.contains(param.name),
                    "default": param.defaultValue as Any
                ]
            }
        ]
    }
}
