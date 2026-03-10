//
//  AgentStore.swift
//  MacAssistant
//
//  Agent 生命周期管理和持久化
//

import AppKit
import Combine
import Foundation

class AgentStore: ObservableObject {
    struct RuntimeProfile {
        let provider: String
        let model: String
        let apiKey: String
        let baseURL: String
    }

    @Published var agents: [Agent] = []
    @Published var currentAgent: Agent?
    @Published private(set) var usableAgents: [Agent] = []
    @Published private(set) var temporarilyUnavailableAgentIDs: Set<String> = []
    
    static let shared = AgentStore()
    
    private let userDefaults = UserDefaults.standard
    private let agentsKey = "macassistant.agents.v2"
    private let currentAgentIdKey = "macassistant.current_agent_id"
    private let temporarilyUnavailableAgentsKey = "macassistant.temporarily_unavailable_agents.v1"
    private let openClawDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".openclaw")
    
    init() {
        loadAgents()
        loadTemporarilyUnavailableAgentIDs()
        refreshAvailability()
    }
    
    // MARK: - CRUD Operations
    
    /// 创建新的 Agent（带完整配置）
    func createAgent(
        name: String,
        emoji: String,
        description: String,
        provider: ProviderType,
        model: String,
        apiKey: String,
        config: AgentConfig
    ) async throws -> Agent {
        // 1. 确定能力
        let capabilities = determineCapabilities(provider: provider, model: model)
        
        // 2. 创建 Agent 对象
        let agent = Agent(
            name: name,
            emoji: emoji,
            description: description,
            provider: provider,
            model: model,
            capabilities: capabilities,
            config: config,
            isDefault: true
        )
        
        // 3. 同步到 OpenClaw 配置
        try syncToOpenClaw(agent: agent, apiKey: apiKey)

        // 4. 保存到本地
        await MainActor.run {
            temporarilyUnavailableAgentIDs.remove(agent.id)
            saveTemporarilyUnavailableAgentIDs()
            // 取消其他默认
            if agent.isDefault {
                agents.indices.forEach { agents[$0].isDefault = false }
            }
            agents.append(agent)
            currentAgent = agent
            saveAgents()
            refreshAvailability()
        }

        return agent
    }
    
    /// 快速创建 Vision Agent
    func createVisionAgent(
        provider: ProviderType,
        apiKey: String,
        model: String? = nil
    ) async throws -> Agent {
        let selectedModel = model ?? provider.visionModels.first ?? provider.recommendedModel
        let emoji = getEmojiForProvider(provider)
        
        return try await createAgent(
            name: "\(provider.displayName) Vision",
            emoji: emoji,
            description: "支持图片分析的 \(provider.displayName) Agent",
            provider: provider,
            model: selectedModel,
            apiKey: apiKey,
            config: AgentConfig(temperature: 0.7, maxTokens: 4096)
        )
    }
    
    /// 更新 Agent
    func updateAgent(_ agent: Agent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[index] = agent
            saveAgents()
            refreshAvailability()
            
            // 如果当前使用的是这个 Agent，更新引用
            if currentAgent?.id == agent.id {
                currentAgent = agent
            }
        }
    }
    
    /// 删除 Agent
    func deleteAgent(_ agent: Agent) {
        agents.removeAll { $0.id == agent.id }
        temporarilyUnavailableAgentIDs.remove(agent.id)
        saveTemporarilyUnavailableAgentIDs()

        // 清理 OpenClaw 配置
        cleanupOpenClawConfig(agent: agent)
        refreshAvailability()
        saveAgents()
    }

    /// 设置默认 Agent
    func setDefaultAgent(_ agent: Agent) {
        guard canUse(agent) else { return }
        for index in agents.indices {
            agents[index].isDefault = (agents[index].id == agent.id)
        }
        currentAgent = agent
        saveAgents()
        refreshAvailability()
    }
    
    /// 切换到指定 Agent
    func switchToAgent(_ agent: Agent) {
        guard canUse(agent) else { return }
        currentAgent = agent
        
        // 更新最后使用时间
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            let updatedAgent = agents[index]
            // 注意：需要处理 lastUsedAt 字段
            agents[index] = updatedAgent
            saveAgents()
        }
    }
    
    // MARK: - 查询方法
    
    /// 查找支持特定能力的 Agents
    func agentsSupporting(_ capability: Capability) -> [Agent] {
        usableAgents.filter { $0.supports(capability) }
    }
    
    /// 查找支持图片分析的 Agents
    var visionAgents: [Agent] {
        usableAgents.filter { $0.supportsImageAnalysis }
    }
    
    /// 获取默认 Agent
    var defaultAgent: Agent? {
        usableAgents.first { $0.isDefault } ?? usableAgents.first
    }

    var allCapabilities: [Capability] {
        Array(Set(usableAgents.flatMap(\.capabilities))).sorted { $0.displayName < $1.displayName }
    }

    var hasUsableAgent: Bool {
        !usableAgents.isEmpty
    }

    var needsInitialSetup: Bool {
        usableAgents.isEmpty
    }

    func canUse(_ agent: Agent) -> Bool {
        usableAgents.contains { $0.id == agent.id }
    }

    func markTemporarilyUnavailable(_ agent: Agent) {
        guard agent.provider.requiresAPIKey else { return }
        temporarilyUnavailableAgentIDs.insert(agent.id)
        saveTemporarilyUnavailableAgentIDs()
        refreshAvailability()
    }

    func restoreAvailability(for agent: Agent) {
        guard temporarilyUnavailableAgentIDs.remove(agent.id) != nil else { return }
        saveTemporarilyUnavailableAgentIDs()
        refreshAvailability()
    }

    @MainActor
    @discardableResult
    func launchKimiLogin() -> Bool {
        let command = #"export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"; kimi login"#
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapeAppleScript(command))"
        end tell
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        do {
            try task.run()
            return true
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
            return false
        }
    }

    @MainActor
    func openKimiConfig() {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi/config.toml")
        let fallbackURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi", isDirectory: true)

        if FileManager.default.fileExists(atPath: configURL.path) {
            NSWorkspace.shared.open(configURL)
        } else {
            NSWorkspace.shared.open(fallbackURL)
        }
    }

    func runtimeProfile(for agent: Agent) -> RuntimeProfile? {
        guard let payload = loadAuthProfilePayload(for: agent) else {
            return nil
        }

        let provider = (payload["provider"] as? String ?? agent.provider.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (payload["model"] as? String ?? agent.model)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (payload["api_key"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = (payload["base_url"] as? String ?? getBaseURL(for: agent.provider))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !provider.isEmpty, !model.isEmpty, !baseURL.isEmpty else {
            return nil
        }

        return RuntimeProfile(provider: provider, model: model, apiKey: apiKey, baseURL: baseURL)
    }
    
    // MARK: - API Key 验证
    
    /// 验证 API Key 是否有效
    func validateAPIKey(provider: ProviderType, apiKey: String, baseURL: String? = nil) async -> ValidationResult {
        let urlString = (baseURL ?? getBaseURL(for: provider))
        
        // 清理 API Key（去除首尾空格）
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let validationTarget = provider.requiresAPIKey ? "API Key" : "CLI 运行时"
        LogInfo("验证 \(provider.displayName) \(validationTarget)...")

        if provider.requiresAPIKey {
            guard !cleanKey.isEmpty else {
                return .invalid("API Key 不能为空")
            }

            if cleanKey.contains(" ") || cleanKey.contains("\n") || cleanKey.contains("\t") {
                return .invalid("API Key 包含非法字符（空格或换行）")
            }
        }
        
        do {
            switch provider {
            case .moonshot, .openai:
                return try await validateOpenAICompatible(urlString: urlString, apiKey: cleanKey, provider: provider)
            case .anthropic:
                return try await validateAnthropic(urlString: urlString, apiKey: cleanKey)
            case .google:
                return try await validateGoogle(urlString: urlString, apiKey: cleanKey)
            case .ollama:
                return await validateLocalCodingRuntimeStatus()
            }
        } catch {
            LogError("API Key 验证失败", error: error)
            return .invalid("验证失败: \(error.localizedDescription)")
        }
    }
    
    private func validateOpenAICompatible(urlString: String, apiKey: String, provider: ProviderType) async throws -> ValidationResult {
        guard let url = URL(string: "\(urlString)/models") else {
            return .invalid("无效的 API 地址")
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            return .invalid("网络响应无效")
        }
        
        switch httpResponse.statusCode {
        case 200:
            LogInfo("\(provider.displayName) API Key 验证通过")
            return .valid
        case 401:
            return .invalid("API Key 无效或已过期，请检查 Key 是否正确")
        case 403:
            return .invalid("API Key 没有权限访问此资源")
        case 429:
            return .rateLimited("请求过于频繁，请稍后再试")
        default:
            return .invalid("HTTP 错误 \(httpResponse.statusCode)")
        }
    }
    
    private func validateAnthropic(urlString: String, apiKey: String) async throws -> ValidationResult {
        // Anthropic 使用 POST /v1/messages 进行简单测试
        guard let url = URL(string: "\(urlString)/messages") else {
            return .invalid("无效的 API 地址")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        
        // 发送一个最简单的请求
        let body: [String: Any] = [
            "model": "claude-3-haiku-20240307",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            return .invalid("网络响应无效")
        }
        
        switch httpResponse.statusCode {
        case 200:
            LogInfo("Anthropic API Key 验证通过")
            return .valid
        case 401:
            return .invalid("API Key 无效或已过期")
        case 403:
            return .invalid("API Key 没有权限")
        case 429:
            return .rateLimited("请求过于频繁")
        default:
            // 即使返回其他错误，只要不是 401/403，Key 可能是有效的
            if httpResponse.statusCode >= 500 {
                return .serverError("服务器错误 (HTTP \(httpResponse.statusCode))")
            }
            return .valid // 可能是模型不可用，但 Key 有效
        }
    }
    
    private func validateGoogle(urlString: String, apiKey: String) async throws -> ValidationResult {
        // Google 使用 GET 请求测试 Key
        var components = URLComponents(string: "\(urlString)/models")
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        
        guard let url = components?.url else {
            return .invalid("无效的 API 地址")
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            return .invalid("网络响应无效")
        }
        
        switch httpResponse.statusCode {
        case 200:
            LogInfo("Google API Key 验证通过")
            return .valid
        case 400:
            return .invalid("API Key 格式错误")
        case 403:
            return .invalid("API Key 无效或没有权限")
        default:
            return .invalid("HTTP 错误 \(httpResponse.statusCode)")
        }
    }
    
    enum ValidationResult {
        case valid
        case invalid(String)
        case rateLimited(String)
        case serverError(String)
        
        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }
        
        var message: String {
            switch self {
            case .valid:
                return "✅ API Key 有效"
            case .invalid(let msg):
                return "❌ \(msg)"
            case .rateLimited(let msg):
                return "⚠️ \(msg)"
            case .serverError(let msg):
                return "⚠️ \(msg)"
            }
        }
    }
    
    /// 获取指定 ID 的 Agent
    func agent(withId id: String) -> Agent? {
        agents.first { $0.id == id }
    }
    
    // MARK: - 持久化
    
    private func saveAgents() {
        if let data = try? JSONEncoder().encode(agents) {
            userDefaults.set(data, forKey: agentsKey)
        }
        if let currentId = currentAgent?.id {
            userDefaults.set(currentId, forKey: currentAgentIdKey)
        } else {
            userDefaults.removeObject(forKey: currentAgentIdKey)
        }
    }
    
    private func loadAgents() {
        if let data = userDefaults.data(forKey: agentsKey),
           let decoded = try? JSONDecoder().decode([Agent].self, from: data) {
            agents = decoded
        } else {
            agents = []
        }
        
        // 加载当前 Agent
        if let currentId = userDefaults.string(forKey: currentAgentIdKey) {
            currentAgent = agents.first { $0.id == currentId }
        } else {
            currentAgent = agents.first { $0.isDefault }
        }
    }

    private func loadTemporarilyUnavailableAgentIDs() {
        let stored = userDefaults.stringArray(forKey: temporarilyUnavailableAgentsKey) ?? []
        temporarilyUnavailableAgentIDs = Set(stored)
        if !temporarilyUnavailableAgentIDs.isEmpty {
            LogDebug("已加载临时停用 Agent: \(temporarilyUnavailableAgentIDs.sorted().joined(separator: ", "))")
        }
    }

    private func saveTemporarilyUnavailableAgentIDs() {
        if temporarilyUnavailableAgentIDs.isEmpty {
            userDefaults.removeObject(forKey: temporarilyUnavailableAgentsKey)
            return
        }

        userDefaults.set(Array(temporarilyUnavailableAgentIDs).sorted(), forKey: temporarilyUnavailableAgentsKey)
    }
    
    func validateLocalCodingRuntime() async -> Bool {
        (await validateLocalCodingRuntimeStatus()).isValid
    }

    func validateLocalCodingRuntimeStatus() async -> ValidationResult {
        await Task.detached(priority: .utility) {
            guard let commandPath = self.resolveKimiExecutablePath() else {
                return .invalid("未找到 `kimi` 命令，请先安装 Kimi CLI。")
            }

            let task = Process()
            let outputPipe = Pipe()
            let inputPipe = Pipe()

            task.executableURL = URL(fileURLWithPath: commandPath)
            task.arguments = [
                "--print",
                "--input-format", "text",
                "--output-format", "text",
                "--final-message-only",
            ]
            task.standardInput = inputPipe
            task.standardOutput = outputPipe
            task.standardError = outputPipe

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/Users/konka/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"
            env["KIMI_NO_COLOR"] = "1"
            task.environment = env

            let promptData = Data("Reply with OK.\n".utf8)
            var didTimeout = false
            let timeoutWorkItem = DispatchWorkItem {
                didTimeout = true
                if task.isRunning {
                    task.terminate()
                }
            }

            do {
                try task.run()
                try inputPipe.fileHandleForWriting.write(contentsOf: promptData)
                try inputPipe.fileHandleForWriting.close()
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeoutWorkItem)
                task.waitUntilExit()
                timeoutWorkItem.cancel()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if didTimeout {
                    return .invalid("Kimi CLI 响应超时，请先在终端完成 `kimi login` 或检查网络后再试。")
                }

                if UserFacingErrorFormatter.isAuthenticationError(
                    NSError(
                        domain: "AgentStore.KimiCLIValidation",
                        code: Int(task.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: output]
                    )
                ) || output.lowercased().contains("invalid_authentication_error") {
                    return .invalid("Kimi CLI 尚未完成认证。请先在终端执行 `kimi login`，或按 CLI 引导完成 provider 选择与 API Key / OAuth 配置。")
                }

                if task.terminationStatus == 0, !output.isEmpty {
                    return .valid
                }

                if output.lowercased().contains("login") || output.lowercased().contains("oauth") {
                    return .invalid("Kimi CLI 还没有完成登录。请先在终端执行 `kimi login`。")
                }

                if !output.isEmpty {
                    return .invalid("Kimi CLI 当前不可用：\(output)")
                }

                return .invalid("Kimi CLI 没有返回可用结果，请先完成登录/初始化后再试。")
            } catch {
                timeoutWorkItem.cancel()
                return .invalid("启动 Kimi CLI 失败：\(error.localizedDescription)")
            }
        }.value
    }

    private func resolveKimiExecutablePath() -> String? {
        let task = Process()
        let pipe = Pipe()

        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", "kimi"]
        task.standardOutput = pipe
        task.standardError = pipe

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/Users/konka/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"
        task.environment = env

        do {
            try task.run()
            task.waitUntilExit()

            guard task.terminationStatus == 0 else {
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }
    
    // MARK: - 能力判定
    
    /// 根据提供商和模型确定能力
    private func determineCapabilities(provider: ProviderType, model: String) -> [Capability] {
        var capabilities: [Capability] = [.textChat]
        
        // 基础能力
        switch provider {
        case .ollama:
            capabilities.append(.codeAnalysis)
        case .openai, .anthropic, .google, .moonshot:
            capabilities.append(contentsOf: [.codeAnalysis, .longContext])
        }
        
        // 视觉能力检查
        if provider.visionModels.contains(model) {
            capabilities.append(contentsOf: [.imageAnalysis, .vision])
        }
        
        // 文档分析（长上下文模型）
        if model.contains("32k") || model.contains("100k") || 
           model.contains("claude") || model.contains("gemini") {
            capabilities.append(.documentAnalysis)
        }
        
        return capabilities
    }
    
    private func getEmojiForProvider(_ provider: ProviderType) -> String {
        switch provider {
        case .ollama: return "🦙"
        case .openai: return "🅾️"
        case .anthropic: return "🅰️"
        case .google: return "🇬"
        case .moonshot: return "🌙"
        }
    }
    
    // MARK: - OpenClaw 集成
    
    /// 同步到 OpenClaw 配置
    private func syncToOpenClaw(agent: Agent, apiKey: String) throws {
        // 1. 创建 Agent 专属目录
        let agentDir = openClawDir.appendingPathComponent("agents/\(agent.id)")
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        
        // 3. 保存认证配置
        let authConfig: [String: Any] = [
            "provider": agent.provider.rawValue,
            "model": agent.model,
            "api_key": apiKey,
            "base_url": getBaseURL(for: agent.provider)
        ]
        
        let authPath = agentDir.appendingPathComponent("auth-profile.json")
        let authData = try JSONSerialization.data(withJSONObject: authConfig, options: .prettyPrinted)
        try authData.write(to: authPath)
        
        // 4. 更新主配置
        try updateOpenClawMainConfig(agent: agent)
        
        print("✅ Agent '\(agent.name)' 已同步到 OpenClaw")
    }
    
    /// 更新 OpenClaw 主配置
    private func updateOpenClawMainConfig(agent: Agent) throws {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/openclaw.json")
        
        var config: [String: Any]
        
        if FileManager.default.fileExists(atPath: configPath.path),
           let data = try? Data(contentsOf: configPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = existing
        } else {
            config = [:]
        }
        
        // 添加模型映射
        var models = config["models"] as? [[String: Any]] ?? []
        let newModel: [String: Any] = [
            "name": "\(agent.provider.rawValue)-\(agent.model)",
            "provider": agent.provider.rawValue,
            "model": agent.model,
            "agent_id": agent.id
        ]
        models.append(newModel)
        config["models"] = models
        
        // 如果设为默认，更新默认配置
        if agent.isDefault {
            config["default_model"] = "\(agent.provider.rawValue)-\(agent.model)"
        }
        
        let data = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
        try data.write(to: configPath)
    }
    
    /// 清理 OpenClaw 配置
    private func cleanupOpenClawConfig(agent: Agent) {
        let agentDir = openClawDir.appendingPathComponent("agents/\(agent.id)")
        try? FileManager.default.removeItem(at: agentDir)
    }
    
    /// 获取提供商的基础 URL
    private func getBaseURL(for provider: ProviderType) -> String {
        switch provider {
        case .ollama:
            return "http://localhost:11434"
        case .openai:
            return "https://api.openai.com/v1"
        case .anthropic:
            return "https://api.anthropic.com/v1"
        case .google:
            return "https://generativelanguage.googleapis.com/v1"
        case .moonshot:
            return "https://api.moonshot.cn/v1"
        }
    }

    private func refreshAvailability() {
        let originalAgents = agents
        let originalCurrentId = currentAgent?.id

        agents.removeAll { isLegacyBootstrapAgent($0) && !hasAuthProfile(for: $0) }
        let remoteAgentIDs = Set(agents.filter { $0.provider.requiresAPIKey }.map(\.id))
        let sanitizedUnavailableIDs = temporarilyUnavailableAgentIDs.intersection(remoteAgentIDs)
        if sanitizedUnavailableIDs != temporarilyUnavailableAgentIDs {
            temporarilyUnavailableAgentIDs = sanitizedUnavailableIDs
            saveTemporarilyUnavailableAgentIDs()
        }
        usableAgents = agents.filter { agent in
            isAgentConfigured(agent) && !temporarilyUnavailableAgentIDs.contains(agent.id)
        }

        if !temporarilyUnavailableAgentIDs.isEmpty {
            let usableSummary = usableAgents.map(\.id).joined(separator: ", ")
            LogDebug("刷新 Agent 可用性，停用名单: \(temporarilyUnavailableAgentIDs.sorted().joined(separator: ", "))，当前可用: \(usableSummary)")
        }

        if let current = currentAgent,
           usableAgents.contains(where: { $0.id == current.id }) {
            currentAgent = usableAgents.first(where: { $0.id == current.id })
        } else {
            currentAgent = usableAgents.first(where: { $0.isDefault }) ?? usableAgents.first
        }

        if agents != originalAgents || currentAgent?.id != originalCurrentId {
            saveAgents()
        }
    }

    private func isLegacyBootstrapAgent(_ agent: Agent) -> Bool {
        agent.provider == .ollama &&
        agent.model == "kimi-local" &&
        agent.name == "Kimi Local" &&
        agent.description == "本地运行的 Kimi 助手，快速且私密"
    }

    private func isAgentConfigured(_ agent: Agent) -> Bool {
        guard let payload = loadAuthProfilePayload(for: agent) else {
            return false
        }

        if agent.provider.requiresAPIKey {
            let apiKey = (payload["api_key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !apiKey.isEmpty
        }

        return true
    }

    private func hasAuthProfile(for agent: Agent) -> Bool {
        FileManager.default.fileExists(atPath: authProfileURL(for: agent).path)
    }

    private func loadAuthProfilePayload(for agent: Agent) -> [String: Any]? {
        guard hasAuthProfile(for: agent),
              let data = try? Data(contentsOf: authProfileURL(for: agent)),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return payload
    }

    private func authProfileURL(for agent: Agent) -> URL {
        openClawDir.appendingPathComponent("agents/\(agent.id)/auth-profile.json")
    }

    private func escapeAppleScript(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
