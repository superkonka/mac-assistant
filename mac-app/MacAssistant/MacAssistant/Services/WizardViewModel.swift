//
//  WizardViewModel.swift
//  MacAssistant
//
//  Agent 配置向导的 ViewModel
//

import SwiftUI
import Combine

enum ConfigurationStep: Int, CaseIterable {
    case selectProvider
    case inputAPIKey
    case testConnection
    case customizeSettings
    case assignRoles
    case complete

    var title: String {
        switch self {
        case .selectProvider: return "选择提供商"
        case .inputAPIKey: return "配置凭证"
        case .testConnection: return "测试连接"
        case .customizeSettings: return "自定义"
        case .assignRoles: return "分配角色"
        case .complete: return "完成"
        }
    }
}

class WizardViewModel: ObservableObject {
    @Published var currentStep: ConfigurationStep = .selectProvider
    
    // 选择
    @Published var selectedProvider: ProviderType?
    @Published var selectedModel: String?
    
    // API Key
    @Published var apiKey: String = ""
    
    // 自定义设置
    @Published var agentName: String = ""
    @Published var agentEmoji: String = "🤖"
    @Published var agentDescription: String = ""
    @Published var temperature: Double = 0.7
    @Published var maxTokens: Int = 4096
    @Published var roleProfile: AgentRoleProfile = .init()
    
    // 测试
    @Published var isTesting = false
    @Published var testSuccess = false
    @Published var testError: String?
    
    // 创建结果
    @Published var createdAgent: Agent?
    
    private var cancellables = Set<AnyCancellable>()
    
    var canProceed: Bool {
        switch currentStep {
        case .selectProvider:
            return selectedProvider != nil
        case .inputAPIKey:
            guard let provider = selectedProvider else { return false }
            return !provider.requiresAPIKey || !apiKey.isEmpty
        case .testConnection:
            return testSuccess
        case .customizeSettings:
            let model = selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !agentName.isEmpty && !model.isEmpty
        case .assignRoles:
            if AgentStore.shared.needsInitialSetup {
                return roleProfile.contains(.primaryChat)
            }
            return !roleProfile.roles.isEmpty
        case .complete:
            return true
        }
    }
    
    func selectProvider(_ provider: ProviderType, model: String? = nil) {
        selectedProvider = provider
        selectedModel = model ?? provider.availableModels[0]
        
        // 自动生成名称
        if agentName.isEmpty {
            if provider == .ollama {
                agentName = "Kimi Coder"
                agentDescription = "本地 Kimi CLI 编程 Agent"
                agentEmoji = "🌙"
            } else {
                agentName = "\(provider.displayName) Agent"
                agentDescription = "基于 \(provider.displayName) 的智能 Agent"
                agentEmoji = provider.emoji
            }
        }

        roleProfile = AgentRoleProfile.suggested(
            provider: provider,
            capabilities: inferCapabilities(for: provider, model: selectedModel ?? provider.availableModels[0]),
            isFirstAgent: AgentStore.shared.agents.isEmpty
        )
    }
    
    func nextStep() {
        guard let next = ConfigurationStep(rawValue: currentStep.rawValue + 1) else { return }
        
        if currentStep == .assignRoles {
            // 创建 Agent
            createAgent()
        }
        
        currentStep = next
    }
    
    func previousStep() {
        guard let prev = ConfigurationStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }

    func setRole(_ role: AgentRole, enabled: Bool) {
        roleProfile.set(role, enabled: enabled)
    }
    
    
    func testConnection() {
        guard let provider = selectedProvider else { return }
        
        isTesting = true
        testSuccess = false
        testError = nil
        
        Task {
            // 使用新的验证方法
            let result = await AgentStore.shared.validateAPIKey(
                provider: provider,
                apiKey: apiKey
            )
            
            await MainActor.run {
                self.isTesting = false
                let validationTarget = provider.requiresAPIKey ? "API Key" : "CLI 运行时"
                
                switch result {
                case .valid:
                    self.testSuccess = true
                    self.testError = nil
                    LogInfo("Agent 配置向导: \(provider.displayName) \(validationTarget) 验证通过")
                    
                case .invalid(let message):
                    self.testSuccess = false
                    if provider.requiresAPIKey {
                        self.testError = """
                            \(message)
                            
                            解决方法:
                            1. 检查 API Key 是否完整复制（没有遗漏字符）
                            2. 确认没有包含额外的空格或换行
                            3. 访问提供商控制台确认 Key 是否有效
                            """
                    } else {
                        self.testError = """
                            \(message)
                            
                            解决方法:
                            1. 在终端执行 `kimi login`
                            2. 如果 CLI 提示选择 provider 或输入 API Key，请完成它
                            3. 必要时检查 `~/.kimi/config.toml`
                            4. 返回这里重新测试
                            """
                    }
                    LogWarning("Agent 配置向导: \(provider.displayName) \(validationTarget) 验证失败 - \(message)")
                    
                case .rateLimited(let message):
                    self.testSuccess = false
                    self.testError = """
                        \(message)
                        
                        您的 API Key 是有效的，但当前请求过于频繁。
                        请稍后再试，或检查您的用量限制。
                        """
                    LogWarning("Agent 配置向导: \(provider.displayName) 请求频率限制")
                    
                case .serverError(let message):
                    self.testSuccess = false
                    self.testError = """
                        \(message)
                        
                        这是提供商服务器的问题，不是您的 API Key 问题。
                        请稍后再试。
                        """
                    LogWarning("Agent 配置向导: \(provider.displayName) \(validationTarget) 服务器错误")
                }
            }
        }
    }
    
    private func performConnectionTest(provider: ProviderType, apiKey: String) async throws -> Bool {
        try await Task.sleep(nanoseconds: 300_000_000)

        switch provider {
        case .ollama:
            return await AgentStore.shared.validateLocalCodingRuntime()
        case .deepseek, .doubao, .zhipu, .openai, .moonshot:
            return try await testOpenAICompatibleProvider(provider: provider, apiKey: apiKey)
        case .anthropic:
            return try await testAnthropicProvider(apiKey: apiKey)
        case .google:
            return try await testGoogleProvider(apiKey: apiKey)
        }
    }

    private func testOpenAICompatibleProvider(provider: ProviderType, apiKey: String) async throws -> Bool {
        guard provider.isOpenAICompatible else {
            throw NSError(domain: "WizardViewModel", code: 100, userInfo: [NSLocalizedDescriptionKey: "不支持的提供商测试。"])
        }

        let baseURL = provider.defaultBaseURL
        let endpoint = URL(string: "\(baseURL)/chat/completions")!
        let body: [String: Any] = [
            "model": selectedModel ?? provider.recommendedModel,
            "messages": [
                ["role": "user", "content": "Reply with OK."]
            ],
            "stream": false,
            "max_tokens": 8,
            "temperature": 0
        ]

        return try await sendTestRequest(
            url: endpoint,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json"
            ],
            body: body
        )
    }

    private func testAnthropicProvider(apiKey: String) async throws -> Bool {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let body: [String: Any] = [
            "model": selectedModel ?? ProviderType.anthropic.recommendedModel,
            "max_tokens": 8,
            "messages": [
                [
                    "role": "user",
                    "content": [["type": "text", "text": "Reply with OK."]]
                ]
            ]
        ]

        return try await sendTestRequest(
            url: endpoint,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json"
            ],
            body: body
        )
    }

    private func testGoogleProvider(apiKey: String) async throws -> Bool {
        let model = selectedModel ?? ProviderType.google.recommendedModel
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1/models/\(model):generateContent")
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let endpoint = components?.url else {
            throw NSError(domain: "WizardViewModel", code: 101, userInfo: [NSLocalizedDescriptionKey: "Google 请求地址无效。"])
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": "Reply with OK."]]
                ]
            ],
            "generationConfig": [
                "temperature": 0,
                "maxOutputTokens": 8
            ]
        ]

        return try await sendTestRequest(
            url: endpoint,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }

    private func sendTestRequest(
        url: URL,
        headers: [String: String],
        body: [String: Any]
    ) async throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "WizardViewModel", code: 102, userInfo: [NSLocalizedDescriptionKey: "没有收到有效的 HTTP 响应。"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "WizardViewModel", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }

        return true
    }

    private func extractErrorMessage(from data: Data) -> String? {
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

        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }
    
    private func createAgent() {
        guard let provider = selectedProvider,
              let model = selectedModel else { return }
        
        Task {
            do {
                let config = AgentConfig(
                    temperature: temperature,
                    maxTokens: maxTokens,
                    topP: 1.0
                )
                
                let agent = try await AgentStore.shared.createAgent(
                    name: agentName,
                    emoji: agentEmoji,
                    description: agentDescription,
                    provider: provider,
                    model: model,
                    apiKey: apiKey,
                    config: config,
                    roleProfile: roleProfile
                )
                
                await MainActor.run {
                    self.createdAgent = agent
                }
            } catch {
                await MainActor.run {
                    self.testError = UserFacingErrorFormatter.setupMessage(
                        for: error,
                        providerName: provider.displayName
                    )
                    self.currentStep = .assignRoles
                }
            }
        }
    }

    private func inferCapabilities(for provider: ProviderType, model: String) -> [Capability] {
        var capabilities: [Capability] = [.textChat]

        switch provider {
        case .ollama:
            capabilities.append(.codeAnalysis)
        case .deepseek, .doubao, .zhipu, .openai, .anthropic, .google, .moonshot:
            capabilities.append(contentsOf: [.codeAnalysis, .longContext])
        }

        if provider.visionModels.contains(model) {
            capabilities.append(contentsOf: [.imageAnalysis, .vision])
        }

        let normalizedModel = model.lowercased()
        if normalizedModel.contains("32k") || normalizedModel.contains("100k") ||
            normalizedModel.contains("claude") || normalizedModel.contains("gemini") ||
            normalizedModel.contains("deepseek") || normalizedModel.contains("glm") ||
            normalizedModel.contains("doubao") {
            capabilities.append(.documentAnalysis)
        }

        return capabilities
    }
}
