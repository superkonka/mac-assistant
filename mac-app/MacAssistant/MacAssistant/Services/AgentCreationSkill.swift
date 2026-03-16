//
//  AgentCreationSkill.swift
//  MacAssistant
//
//  对话引导式 Agent 创建 Skill
//

import Foundation

/// AgentCreationSkill - 通过对话引导用户创建 Agent
/// 
/// 流程：
/// 1. 检测到能力缺口 → 发起创建对话
/// 2. 用户选择 Provider
/// 3. 用户输入 API Key
/// 4. 自动测试并创建
/// 5. 切换并使用新 Agent
class AgentCreationSkill {
    static let shared = AgentCreationSkill()
    
    enum CreationState {
        case idle
        case selectingProvider(gap: CapabilityGap)
        case inputtingAPIKey(provider: ProviderType, gap: CapabilityGap)
        case selectingModel(provider: ProviderType, apiKey: String, gap: CapabilityGap)
        case testing(provider: ProviderType, apiKey: String, model: String, gap: CapabilityGap)
        case customizing(name: String, emoji: String)
    }
    
    @Published var state: CreationState = .idle
    
    /// 发起创建流程
    func initiateCreation(for gap: CapabilityGap, in runner: CommandRunner) {
        state = .selectingProvider(gap: gap)
        
        let message = createProviderSelectionMessage(gap: gap)
        let response = MacAssistant.ChatMessage(
            id: UUID(),
            role: .assistant,
            content: message,
            timestamp: Date(),
            metadata: ["creation_flow": "select_provider", "gap": gap.missingCapability.rawValue]
        )
        
        runner.messages.append(response)
    }
    
    /// 处理用户输入
    func handleInput(_ input: String, runner: CommandRunner) async {
        switch state {
        case .idle:
            break
            
        case .selectingProvider(let gap):
            await handleProviderSelection(input, gap: gap, runner: runner)
            
        case .inputtingAPIKey(let provider, let gap):
            await handleAPIKeyInput(input, provider: provider, gap: gap, runner: runner)
            
        case .selectingModel(let provider, let apiKey, let gap):
            await handleModelSelection(input, provider: provider, apiKey: apiKey, gap: gap, runner: runner)
            
        case .testing, .customizing:
            // 创建中，忽略输入
            break
        }
    }
    
    /// 处理 Provider 选择
    private func handleProviderSelection(_ input: String, gap: CapabilityGap, runner: CommandRunner) async {
        let choice = input.trimmingCharacters(in: .whitespaces).lowercased()
        
        // 解析选择
        let selectedProvider: ProviderType?
        if choice.contains("1") || choice.contains("openai") || choice.contains("gpt") {
            selectedProvider = .openai
        } else if choice.contains("2") || choice.contains("anthropic") || choice.contains("claude") {
            selectedProvider = .anthropic
        } else if choice.contains("3") || choice.contains("kimi") || choice.contains("moonshot") {
            selectedProvider = .moonshot
        } else if choice.contains("4") || choice.contains("google") || choice.contains("gemini") {
            selectedProvider = .google
        } else if choice.contains("5") || choice.contains("deepseek") {
            selectedProvider = .deepseek
        } else if choice.contains("6") || choice.contains("doubao") || choice.contains("豆包") {
            selectedProvider = .doubao
        } else if choice.contains("7") || choice.contains("zhipu") || choice.contains("智谱") || choice.contains("glm") {
            selectedProvider = .zhipu
        } else {
            // 无法识别，重新提示
            let retryMessage = MacAssistant.ChatMessage(
                id: UUID(),
                role: .assistant,
                content: """
                ❓ 无法识别您的选择："\(input)"
                
                请回复数字 1-7 或提供商名称：
                1️⃣ OpenAI (GPT-4V)
                2️⃣ Anthropic (Claude 3)
                3️⃣ Moonshot (Kimi K2.5)
                4️⃣ Google (Gemini)
                5️⃣ DeepSeek
                6️⃣ Doubao (豆包)
                7️⃣ Zhipu (智谱 GLM)
                
                或输入 "取消" 退出创建流程。
                """,
                timestamp: Date()
            )
            runner.messages.append(retryMessage)
            return
        }
        
        guard let provider = selectedProvider else { return }
        
        // 进入 API Key 输入阶段
        state = .inputtingAPIKey(provider: provider, gap: gap)
        
        let keyMessage = MacAssistant.ChatMessage(
            id: UUID(),
            role: .assistant,
            content: createAPIKeyMessage(provider: provider),
            timestamp: Date(),
            metadata: ["creation_flow": "input_apikey", "provider": provider.rawValue]
        )
        runner.messages.append(keyMessage)
    }
    
    /// 处理 API Key 输入
    private func handleAPIKeyInput(_ input: String, provider: ProviderType, gap: CapabilityGap, runner: CommandRunner) async {
        let apiKey = input.trimmingCharacters(in: .whitespaces)
        
        // 验证 API Key 格式
        guard validateAPIKey(apiKey, for: provider) else {
            let errorMessage = MacAssistant.ChatMessage(
                id: UUID(),
                role: .assistant,
                content: """
                ⚠️ API Key 格式不正确
                
                \(provider.displayName) 的 API Key 应该：
                - \(provider.apiKeyPlaceholder)
                - 长度大于 20 个字符
                
                请重新输入，或输入 "取消" 退出。
                """,
                timestamp: Date()
            )
            runner.messages.append(errorMessage)
            return
        }
        
        // 进入模型选择阶段
        state = .selectingModel(provider: provider, apiKey: apiKey, gap: gap)
        
        let modelMessage = MacAssistant.ChatMessage(
            id: UUID(),
            role: .assistant,
            content: createModelSelectionMessage(provider: provider),
            timestamp: Date(),
            metadata: ["creation_flow": "select_model", "provider": provider.rawValue]
        )
        runner.messages.append(modelMessage)
    }
    
    /// 处理模型选择
    private func handleModelSelection(_ input: String, provider: ProviderType, apiKey: String, gap: CapabilityGap, runner: CommandRunner) async {
        let choice = input.trimmingCharacters(in: .whitespaces)
        
        // 获取推荐模型
        let recommendedModel = getRecommendedModel(for: provider, gap: gap)
        
        let selectedModel: String
        if choice.isEmpty || choice == "1" {
            selectedModel = recommendedModel
        } else if let index = Int(choice), index > 0 && index <= provider.availableModels.count {
            selectedModel = provider.availableModels[index - 1]
        } else if provider.availableModels.contains(choice) {
            selectedModel = choice
        } else {
            // 使用推荐模型
            selectedModel = recommendedModel
        }
        
        // 进入测试阶段
        state = .testing(provider: provider, apiKey: apiKey, model: selectedModel, gap: gap)
        
        let testingMessage = MacAssistant.ChatMessage(
            id: UUID(),
            role: .assistant,
            content: """
            🧪 正在测试连接...
            
            提供商: \(provider.displayName)
            模型: \(selectedModel)
            
            请稍候...
            """,
            timestamp: Date()
        )
        runner.messages.append(testingMessage)
        
        // 执行测试和创建
        await testAndCreateAgent(
            provider: provider,
            apiKey: apiKey,
            model: selectedModel,
            gap: gap,
            runner: runner
        )
    }
    
    /// 测试并创建 Agent
    private func testAndCreateAgent(
        provider: ProviderType,
        apiKey: String,
        model: String,
        gap: CapabilityGap,
        runner: CommandRunner
    ) async {
        do {
            // 1. 测试连接
            let success = try await performConnectionTest(provider: provider, apiKey: apiKey)
            
            guard success else {
                let errorMessage = MacAssistant.ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: """
                    ❌ 连接测试失败
                    
                    无法连接到 \(provider.displayName)，请检查：
                    1. API Key 是否正确
                    2. 网络连接是否正常
                    3. 账户是否有足够的额度
                    
                    您可以：
                    - 重新输入 "创建 Agent" 再次尝试
                    - 使用其他提供商
                    """,
                    timestamp: Date()
                )
                runner.messages.append(errorMessage)
                state = .idle
                return
            }
            
            // 2. 创建 Agent
            let agentName = generateAgentName(for: gap, provider: provider)
            let emoji = getEmoji(for: gap)
            
            let config = AgentConfig(
                temperature: 0.7,
                maxTokens: 4096
            )
            
            let agent = try await AgentStore.shared.createAgent(
                name: agentName,
                emoji: emoji,
                description: "支持 \(gap.missingCapability.displayName) 的 \(provider.displayName) Agent",
                provider: provider,
                model: model,
                apiKey: apiKey,
                config: config,
                roleProfile: recommendedRoleProfile(for: gap)
            )
            
            // 3. 仅在适合作为主会话时自动切换
            let adoptedAsCurrent = AgentStore.shared.shouldAutoAdoptAsCurrent(agent)
            if adoptedAsCurrent {
                AgentOrchestrator.shared.switchToAgent(agent)
            }
            
            // 4. 完成提示
            let successMessage = MacAssistant.ChatMessage(
                id: UUID(),
                role: .assistant,
                content: """
                ✅ Agent 创建成功！
                
                \(emoji) \(agent.name) 已就绪
                • 提供商: \(provider.displayName)
                • 模型: \(model)
                • 能力: \(agent.capabilities.map { $0.displayName }.joined(separator: ", "))
                
                \(adoptedAsCurrent ? "已自动切换到此 Agent。" : "它已加入后台角色池，不会影响当前主会话。")
                
                现在可以重新发送您的图片分析请求了！
                """,
                timestamp: Date()
            )
            runner.messages.append(successMessage)
            
            state = .idle
            
        } catch {
            let errorMessage = MacAssistant.ChatMessage(
                id: UUID(),
                role: .assistant,
                content: """
                \(UserFacingErrorFormatter.setupMessage(for: error, providerName: provider.displayName))
                """,
                timestamp: Date()
            )
            runner.messages.append(errorMessage)
            state = .idle
        }
    }
    
    // MARK: - 辅助方法
    
    private func createProviderSelectionMessage(gap: CapabilityGap) -> String {
        return """
        💡 检测到您需要 **\(gap.missingCapability.displayName)** 能力
        
        我可以帮您创建一个支持此能力的 Agent。
        
        请选择 AI 提供商：
        
        1️⃣ **OpenAI** (GPT-4o / GPT-4V)
           最强视觉理解能力，支持图文分析
           
        2️⃣ **Anthropic** (Claude 3 Opus/Sonnet)
           精准的视觉识别，文档分析能力强
           
        3️⃣ **Moonshot** (Kimi K2.5) ⭐ 推荐
           国内可用，支持图片和超长上下文
           
        4️⃣ **Google** (Gemini Pro Vision)
           多模态能力强，免费额度多

        5️⃣ **DeepSeek**
           OpenAI 兼容接口，适合长文本与推理

        6️⃣ **Doubao** (豆包 / 火山方舟)
           国内主流模型，可走方舟 API

        7️⃣ **Zhipu** (智谱 GLM)
           国内主流模型，GLM 系列适合通用对话与文档
        
        请回复数字 (1-7) 选择，或输入 "取消" 退出。
        """
    }
    
    private func createAPIKeyMessage(provider: ProviderType) -> String {
//        if provider == .ollama {
//            return """
//            ⚙️ \(provider.displayName) 需要先完成 CLI 认证
//
//            这个入口不会直接保存 Kimi CLI 的 API Key。
//            如果你的 Kimi CLI 首次启动时需要选择 provider、登录或输入 API Key，请先在终端执行 `kimi login` 或按 CLI 引导完成。
//
//            完成后回到这里，我会继续帮你验证。
//            """
//        }

        var message = """
        🔑 请输入 \(provider.displayName) 的 API Key
        
        格式: \(provider.apiKeyPlaceholder)
        """

        message += "\n\n获取地址: \(provider.apiDocsURL)"

        if let setupHint = provider.setupHint {
            message += "\n\n说明: \(setupHint)"
        }
        
        message += "\n\n您的 API Key 将安全存储在本地。"
        
        return message
    }
    
    private func createModelSelectionMessage(provider: ProviderType) -> String {
        let models = provider.availableModels
        var message = "🎯 请选择模型（直接回车使用推荐）:\n\n"
        
        for (index, model) in models.enumerated() {
            let isRecommended = index == 0
            message += "\(index + 1). \(model)\(isRecommended ? " ⭐ 推荐" : "")\n"
        }
        
        message += "\n回复数字或直接输入模型名称。"
        
        return message
    }
    
    private func validateAPIKey(_ key: String, for provider: ProviderType) -> Bool {
        guard provider.requiresAPIKey else { return true }
        
        switch provider {
        case .openai:
            return key.hasPrefix("sk-") && key.count > 20
        case .anthropic:
            return key.hasPrefix("sk-ant-") && key.count > 20
        case .google:
            return key.hasPrefix("AIza") && key.count > 20
        case .moonshot:
            return key.hasPrefix("sk-") && key.count > 20
        case .deepseek:
            return key.hasPrefix("sk-") && key.count > 20
        case .doubao, .zhipu:
            return key.count > 20
//        case .ollama:
//            return true
        }
    }
    
    private func getRecommendedModel(for provider: ProviderType, gap: CapabilityGap) -> String {
        switch (provider, gap.missingCapability) {
        case (.openai, .imageAnalysis), (.openai, .vision):
            return "gpt-4o"
        case (.anthropic, .imageAnalysis), (.anthropic, .vision):
            return "claude-opus-4"
        case (.moonshot, .imageAnalysis), (.moonshot, .vision):
            return "kimi-k2.5"
        case (.google, .imageAnalysis), (.google, .vision):
            return "gemini-pro-vision"
        case (.doubao, .imageAnalysis), (.doubao, .vision):
            return "Doubao-1.5-vision-pro-32k"
        case (.zhipu, .imageAnalysis), (.zhipu, .vision):
            return "glm-4.5v"
        default:
            return provider.availableModels[0]
        }
    }
    
    private func generateAgentName(for gap: CapabilityGap, provider: ProviderType) -> String {
        switch gap.missingCapability {
        case .imageAnalysis, .vision:
            return "\(provider.displayName) Vision"
        case .documentAnalysis:
            return "\(provider.displayName) Document"
        case .voiceRecognition:
            return "\(provider.displayName) Voice"
        case .webSearch:
            return "\(provider.displayName) Search"
        default:
            return "\(provider.displayName) Agent"
        }
    }
    
    private func getEmoji(for gap: CapabilityGap) -> String {
        switch gap.missingCapability {
        case .imageAnalysis, .vision:
            return "👁️"
        case .documentAnalysis:
            return "📄"
        case .voiceRecognition:
            return "🎙️"
        case .webSearch:
            return "🔍"
        default:
            return "🤖"
        }
    }
    
    private func performConnectionTest(provider: ProviderType, apiKey: String) async throws -> Bool {
        // 模拟测试延迟
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // 简单验证
//        if provider == .ollama {
//            return await AgentStore.shared.validateLocalCodingRuntime()
//        }
        if provider.requiresAPIKey {
            return validateAPIKey(apiKey, for: provider)
        }
        return true
    }
    
    /// 检查是否在创建流程中
    var isInCreationFlow: Bool {
        if case .idle = state {
            return false
        }
        return true
    }
    
    /// 取消创建
    func cancel() {
        state = .idle
    }

    private func recommendedRoleProfile(for gap: CapabilityGap) -> AgentRoleProfile {
        switch gap.missingCapability {
        case .vision, .imageAnalysis, .documentAnalysis:
            return AgentRoleProfile(roles: [.subtaskWorker, .fallback])
        case .webSearch:
            return AgentRoleProfile(roles: [.planner, .subtaskWorker, .fallback])
        default:
            return AgentRoleProfile(roles: [.primaryChat, .fallback])
        }
    }
}
