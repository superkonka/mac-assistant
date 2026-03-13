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
    @Published private(set) var roleProfilesByAgentID: [String: AgentRoleProfile] = [:]
    @Published private(set) var temporarilyUnavailableAgentIDs: Set<String> = []
    
    static let shared = AgentStore()
    
    private let userDefaults = UserDefaults.standard
    private let agentsKey = "macassistant.agents.v2"
    private let currentAgentIdKey = "macassistant.current_agent_id"
    private let agentRoleProfilesKey = "macassistant.agent_role_profiles.v1"
    private let temporarilyUnavailableAgentsKey = "macassistant.temporarily_unavailable_agents.v1"
    private let openClawDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".openclaw")
    private let preferences = UserPreferenceStore.shared
    
    init() {
        loadAgents()
        loadRoleProfiles()
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
        config: AgentConfig,
        roleProfile: AgentRoleProfile? = nil
    ) async throws -> Agent {
        // 1. 确定能力
        let capabilities = determineCapabilities(provider: provider, model: model)
        let isFirstAgent = await MainActor.run { self.agents.isEmpty }
        let resolvedRoleProfile = roleProfile ?? AgentRoleProfile.suggested(
            provider: provider,
            capabilities: capabilities,
            isFirstAgent: isFirstAgent
        )
        let shouldBecomeDefault = resolvedRoleProfile.contains(.primaryChat) && isFirstAgent
        
        // 2. 创建 Agent 对象
        let agent = Agent(
            name: name,
            emoji: emoji,
            description: description,
            provider: provider,
            model: model,
            capabilities: capabilities,
            config: config,
            isDefault: shouldBecomeDefault
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
            roleProfilesByAgentID[agent.id] = resolvedRoleProfile
            applyRoleSideEffects(afterSetting: resolvedRoleProfile, for: agent, previousProfile: nil)
            if currentAgent == nil && shouldAutoAdoptAsCurrent(agent) {
                currentAgent = agent
            }
            saveRoleProfiles()
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
            config: AgentConfig(temperature: 0.7, maxTokens: 4096),
            roleProfile: AgentRoleProfile(roles: [.subtaskWorker, .fallback])
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
        roleProfilesByAgentID.removeValue(forKey: agent.id)
        temporarilyUnavailableAgentIDs.remove(agent.id)
        saveTemporarilyUnavailableAgentIDs()
        applyRoleRemovalSideEffects(for: agent)
        saveRoleProfiles()

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
        var profile = roleProfile(for: agent)
        profile.set(.primaryChat, enabled: true)
        roleProfilesByAgentID[agent.id] = profile
        saveRoleProfiles()
        saveAgents()
        refreshAvailability()
    }
    
    /// 切换到指定 Agent
    func switchToAgent(_ agent: Agent) {
        guard canUse(agent) else { return }
        let previousAgentID = currentAgent?.id ?? "none"
        currentAgent = agent
        LogInfo("切换当前 Agent previous=\(previousAgentID) next=\(agent.id)")
        
        // 更新最后使用时间
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            let updatedAgent = agents[index]
            // 注意：需要处理 lastUsedAt 字段
            agents[index] = updatedAgent
            saveAgents()
        }
    }
    
    // MARK: - 查询方法

    func roleProfile(for agent: Agent) -> AgentRoleProfile {
        roleProfilesByAgentID[agent.id] ?? AgentRoleProfile.suggested(
            provider: agent.provider,
            capabilities: agent.capabilities,
            isFirstAgent: agent.isDefault || agents.count == 1
        )
    }

    func roles(for agent: Agent) -> Set<AgentRole> {
        roleProfile(for: agent).roles
    }

    func hasRole(_ role: AgentRole, for agent: Agent) -> Bool {
        roles(for: agent).contains(role)
    }

    func setRoleProfile(_ profile: AgentRoleProfile, for agent: Agent) {
        let normalized = normalizeRoleProfile(profile, for: agent)
        let previous = roleProfilesByAgentID[agent.id]
        roleProfilesByAgentID[agent.id] = normalized
        applyRoleSideEffects(afterSetting: normalized, for: agent, previousProfile: previous)
        saveRoleProfiles()
        refreshAvailability()
    }

    func setRole(_ role: AgentRole, enabled: Bool, for agent: Agent) {
        var profile = roleProfile(for: agent)
        profile.set(role, enabled: enabled)
        setRoleProfile(profile, for: agent)
    }

    func setPlannerPreferredAgent(_ agent: Agent?) {
        preferences.plannerPreferredAgentID = agent?.id
        objectWillChange.send()
    }
    
    /// 查找支持特定能力的 Agents
    func agentsSupporting(_ capability: Capability) -> [Agent] {
        usableAgents.filter { $0.supports(capability) }
    }

    func autoRoutableAgentsSupporting(_ capability: Capability) -> [Agent] {
        usableAgents.filter { candidate in
            isAutoRoutable(candidate) && candidate.supports(capability)
        }
    }
    
    /// 查找支持图片分析的 Agents
    var visionAgents: [Agent] {
        usableAgents.filter { $0.supportsImageAnalysis }
    }
    
    /// 获取默认 Agent
    var defaultAgent: Agent? {
        let primary = primaryChatAgents(usableOnly: true)
        return primary.first { $0.isDefault } ??
            primary.first ??
            usableAgents.first { $0.isDefault } ??
            usableAgents.first
    }

    var plannerPreferredAgent: Agent? {
        if let preferredID = preferences.plannerPreferredAgentID,
           let preferred = usableAgents.first(where: { $0.id == preferredID && hasRole(.planner, for: $0) }) {
            return preferred
        }
        return plannerAgents(usableOnly: true).first ?? defaultAgent
    }

    var workflowDesignerPreferredAgent: Agent? {
        if let plannerPreferredAgent,
           isAutoRoutable(plannerPreferredAgent),
           plannerPreferredAgent.supports(.textChat) {
            return plannerPreferredAgent
        }

        if let plannerWorker = plannerAgents(usableOnly: true).first(where: { candidate in
            isAutoRoutable(candidate) && candidate.supports(.textChat)
        }) {
            return plannerWorker
        }

        if let subtaskWorker = subtaskWorkerAgents(usableOnly: true).first(where: { candidate in
            isAutoRoutable(candidate) && candidate.supports(.textChat)
        }) {
            return subtaskWorker
        }

        return usableAgents.first(where: { candidate in
            isAutoRoutable(candidate) && candidate.supports(.textChat)
        })
    }

    func primaryChatAgents(usableOnly: Bool) -> [Agent] {
        agents(for: .primaryChat, usableOnly: usableOnly)
    }

    func plannerAgents(usableOnly: Bool) -> [Agent] {
        agents(for: .planner, usableOnly: usableOnly)
    }

    func subtaskWorkerAgents(usableOnly: Bool) -> [Agent] {
        agents(for: .subtaskWorker, usableOnly: usableOnly)
    }

    func fallbackAgents(usableOnly: Bool) -> [Agent] {
        agents(for: .fallback, usableOnly: usableOnly)
    }

    func manualOnlyAgents(usableOnly: Bool) -> [Agent] {
        agents(for: .manualOnly, usableOnly: usableOnly)
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

    func isAutoRoutable(_ agent: Agent) -> Bool {
        !hasRole(.manualOnly, for: agent)
    }

    func preferredSubtaskWorker(
        for capability: Capability,
        requireToolSupport: Bool = false,
        excluding excludedIDs: Set<String> = []
    ) -> Agent? {
        let candidates = subtaskWorkerAgents(usableOnly: true).filter { agent in
            !excludedIDs.contains(agent.id) &&
            agent.supports(capability) &&
            (!requireToolSupport || agent.provider != .ollama)
        }

        if let current = currentAgent,
           candidates.contains(where: { $0.id == current.id }) {
            return current
        }

        return candidates.first ?? usableAgents.first(where: { agent in
            !excludedIDs.contains(agent.id) &&
            isAutoRoutable(agent) &&
            agent.supports(capability) &&
            (!requireToolSupport || agent.provider != .ollama)
        })
    }

    func fallbackCandidates(
        for capability: Capability,
        excluding excludedIDs: Set<String> = [],
        preferredCurrent: Agent? = nil
    ) -> [Agent] {
        let pool = usableAgents.filter { agent in
            !excludedIDs.contains(agent.id) &&
            isAutoRoutable(agent) &&
            agent.supports(capability)
        }

        var ordered: [Agent] = []
        var seenIDs = Set<String>()

        func append(_ candidate: Agent?) {
            guard let candidate,
                  seenIDs.insert(candidate.id).inserted,
                  pool.contains(where: { $0.id == candidate.id }) else {
                return
            }
            ordered.append(candidate)
        }

        if let preferredCurrent {
            append(preferredCurrent)
        }

        fallbackAgents(usableOnly: true)
            .filter { $0.supports(capability) && !excludedIDs.contains($0.id) }
            .forEach { append($0) }

        append(defaultAgent)
        pool.forEach { append($0) }
        return ordered
    }

    func shouldAutoAdoptAsCurrent(_ agent: Agent) -> Bool {
        let assignedRoles = roles(for: agent)
        if currentAgent == nil {
            return !assignedRoles.contains(.manualOnly)
        }
        return assignedRoles.contains(.primaryChat)
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
        let command = """
        export PATH="\(commandSearchPath())";
        kimi login;
        status=$?;
        echo;
        if [ "$status" -eq 0 ]; then
            echo "[MacAssistant] 如果你在 'logged in successfully' 之后看到类似 'pyenv: command not found' 的 shell 启动警告，登录通常已经成功，可以直接回到应用重新测试。";
        fi
        """
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
            case .deepseek, .doubao, .zhipu, .moonshot, .openai:
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
        guard let url = URL(string: "\(urlString)/chat/completions") else {
            return .invalid("无效的 API 地址")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let body: [String: Any] = [
            "model": provider.recommendedModel,
            "messages": [
                ["role": "user", "content": "Reply with OK."]
            ],
            "stream": false,
            "max_tokens": 8,
            "temperature": 0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
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
            if let message = extractValidationErrorMessage(from: data), !message.isEmpty {
                if httpResponse.statusCode >= 500 {
                    return .serverError(message)
                }
                return .invalid(message)
            }
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

    private func extractValidationErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? String, !error.isEmpty {
                return error
            }
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.isEmpty {
                return message
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return message
            }
        }

        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
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

    private func saveRoleProfiles() {
        if let data = try? JSONEncoder().encode(roleProfilesByAgentID) {
            userDefaults.set(data, forKey: agentRoleProfilesKey)
        } else {
            userDefaults.removeObject(forKey: agentRoleProfilesKey)
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

    private func loadRoleProfiles() {
        guard let data = userDefaults.data(forKey: agentRoleProfilesKey),
              let decoded = try? JSONDecoder().decode([String: AgentRoleProfile].self, from: data) else {
            roleProfilesByAgentID = [:]
            return
        }
        roleProfilesByAgentID = decoded
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
            env["PATH"] = self.commandSearchPath()
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
                let rawOutput = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let output = self.sanitizedLocalRuntimeOutput(rawOutput)

                if didTimeout {
                    return .invalid("Kimi CLI 响应超时，请先在终端完成 `kimi login` 或检查网络后再试。")
                }

                if UserFacingErrorFormatter.isAuthenticationError(
                    NSError(
                        domain: "AgentStore.KimiCLIValidation",
                        code: Int(task.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: rawOutput]
                    )
                ) || rawOutput.lowercased().contains("invalid_authentication_error") {
                    return .invalid("Kimi CLI 尚未完成认证。请先在终端执行 `kimi login`，或按 CLI 引导完成 provider 选择与 API Key / OAuth 配置。")
                }

                if task.terminationStatus == 0, !output.isEmpty {
                    return .valid
                }

                if rawOutput.lowercased().contains("logged in successfully") {
                    return .valid
                }

                if output.lowercased().contains("login") || output.lowercased().contains("oauth") {
                    return .invalid("Kimi CLI 还没有完成登录。请先在终端执行 `kimi login`。")
                }

                if !output.isEmpty {
                    return .invalid("Kimi CLI 当前不可用：\(output)")
                }

                if !rawOutput.isEmpty, self.containsOnlyShellNoise(rawOutput) {
                    return .invalid("Kimi CLI 已经执行，但你的 shell 启动里还有额外警告（例如 pyenv 配置异常）。请先修复 shell 环境，或忽略该警告后重新测试。")
                }

                return .invalid("Kimi CLI 没有返回可用结果，请先完成登录/初始化后再试。")
            } catch {
                timeoutWorkItem.cancel()
                return .invalid("启动 Kimi CLI 失败：\(error.localizedDescription)")
            }
        }.value
    }

    private func resolveKimiExecutablePath() -> String? {
        for candidate in self.kimiExecutableCandidates() where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let task = Process()
        let pipe = Pipe()

        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", "kimi"]
        task.standardOutput = pipe
        task.standardError = pipe

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = self.commandSearchPath()
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

    private func kimiExecutableCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/kimi",
            "\(home)/.cargo/bin/kimi",
            "\(home)/.pyenv/shims/kimi",
            "/opt/homebrew/bin/kimi",
            "/usr/local/bin/kimi",
            "/usr/bin/kimi"
        ]
    }

    private func commandSearchPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let entries = [
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.pyenv/shims",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/sbin",
            "/usr/sbin"
        ]

        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    private func sanitizedLocalRuntimeOutput(_ output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !isBenignShellNoiseLine($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsOnlyShellNoise(_ output: String) -> Bool {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { isBenignShellNoiseLine($0) }
    }

    private func isBenignShellNoiseLine(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.contains("command not found: pyenv") ||
            normalized.contains("pyenv:") && normalized.contains("command not found") ||
            normalized.contains("compdef: command not found") ||
            normalized.contains("zsh compinit:")
    }
    
    // MARK: - 能力判定
    
    /// 根据提供商和模型确定能力
    private func determineCapabilities(provider: ProviderType, model: String) -> [Capability] {
        var capabilities: [Capability] = [.textChat]
        
        // 基础能力
        switch provider {
        case .ollama:
            capabilities.append(.codeAnalysis)
        case .deepseek, .doubao, .zhipu, .openai, .anthropic, .google, .moonshot:
            capabilities.append(contentsOf: [.codeAnalysis, .longContext])
        }
        
        // 视觉能力检查
        if provider.visionModels.contains(model) {
            capabilities.append(contentsOf: [.imageAnalysis, .vision])
        }
        
        // 文档分析（长上下文模型）
        let normalizedModel = model.lowercased()
        if normalizedModel.contains("32k") || normalizedModel.contains("100k") ||
           normalizedModel.contains("claude") || normalizedModel.contains("gemini") ||
           normalizedModel.contains("deepseek") || normalizedModel.contains("glm") ||
           normalizedModel.contains("doubao") {
            capabilities.append(.documentAnalysis)
        }
        
        return capabilities
    }
    
    private func getEmojiForProvider(_ provider: ProviderType) -> String {
        switch provider {
        case .ollama: return "🦙"
        case .deepseek: return "🧠"
        case .doubao: return "🎯"
        case .zhipu: return "🟣"
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
        provider.defaultBaseURL
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
        normalizeRoleProfiles()

        if !temporarilyUnavailableAgentIDs.isEmpty {
            let usableSummary = usableAgents.map(\.id).joined(separator: ", ")
            LogDebug("刷新 Agent 可用性，停用名单: \(temporarilyUnavailableAgentIDs.sorted().joined(separator: ", "))，当前可用: \(usableSummary)")
        }

        if let current = currentAgent,
           usableAgents.contains(where: { $0.id == current.id }) {
            currentAgent = usableAgents.first(where: { $0.id == current.id })
        } else {
            currentAgent = defaultAgent
        }

        if agents != originalAgents || currentAgent?.id != originalCurrentId {
            saveAgents()
        }
    }

    private func agents(for role: AgentRole, usableOnly: Bool) -> [Agent] {
        let source = usableOnly ? usableAgents : agents
        return source.filter { hasRole(role, for: $0) }
    }

    private func normalizeRoleProfiles() {
        let existingIDs = Set(agents.map(\.id))
        var normalized = roleProfilesByAgentID.filter { existingIDs.contains($0.key) }
        var didChange = normalized.count != roleProfilesByAgentID.count

        for agent in agents {
            let profile = normalized[agent.id] ?? AgentRoleProfile.suggested(
                provider: agent.provider,
                capabilities: agent.capabilities,
                isFirstAgent: agent.isDefault || agents.count == 1
            )
            let sanitized = normalizeRoleProfile(profile, for: agent)
            if normalized[agent.id] != sanitized {
                normalized[agent.id] = sanitized
                didChange = true
            }
        }

        if roleProfilesByAgentID != normalized {
            roleProfilesByAgentID = normalized
            didChange = true
        }

        if let preferredID = preferences.plannerPreferredAgentID,
           !(roleProfilesByAgentID[preferredID]?.contains(.planner) ?? false) {
            preferences.plannerPreferredAgentID = normalized.first(where: { $0.value.contains(.planner) })?.key
        }

        if didChange {
            saveRoleProfiles()
        }
    }

    private func normalizeRoleProfile(_ profile: AgentRoleProfile, for agent: Agent) -> AgentRoleProfile {
        var normalized = profile
        if agent.isDefault {
            normalized.set(.primaryChat, enabled: true)
        }
        if normalized.roles.isEmpty {
            normalized = AgentRoleProfile.suggested(
                provider: agent.provider,
                capabilities: agent.capabilities,
                isFirstAgent: agent.isDefault || agents.count == 1
            )
        }
        return normalized
    }

    private func applyRoleSideEffects(
        afterSetting profile: AgentRoleProfile,
        for agent: Agent,
        previousProfile: AgentRoleProfile?
    ) {
        if profile.contains(.planner) {
            if preferences.plannerPreferredAgentID == nil ||
                preferences.plannerPreferredAgentID == agent.id ||
                previousProfile?.contains(.planner) != true {
                preferences.plannerPreferredAgentID = agent.id
            }
        } else if preferences.plannerPreferredAgentID == agent.id {
            preferences.plannerPreferredAgentID = plannerAgents(usableOnly: true)
                .first(where: { $0.id != agent.id })?
                .id
        }
    }

    private func applyRoleRemovalSideEffects(for agent: Agent) {
        if preferences.plannerPreferredAgentID == agent.id {
            preferences.plannerPreferredAgentID = nil
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
