//
//  AgentModels.swift
//  MacAssistant
//
//  Agent 系统的数据模型
//

import Foundation

// MARK: - Provider Type

enum ProviderType: String, CaseIterable, Codable, Identifiable {
    // 已移除: ollama (Kimi CLI)
    case deepseek
    case doubao
    case zhipu
    case openai
    case anthropic
    case google
    case moonshot
    
    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .doubao: return "Doubao"
        case .zhipu: return "Zhipu"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google"
        case .moonshot: return "Moonshot"
        }
    }

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .deepseek: return "bolt.circle"
        case .doubao: return "sparkles.rectangle.stack"
        case .zhipu: return "brain"
        case .openai: return "sparkles"
        case .anthropic: return "brain.head.profile"
        case .google: return "globe"
        case .moonshot: return "moon.stars.fill"
        }
    }

    var emoji: String {
        switch self {
        case .deepseek: return "🧠"
        case .doubao: return "🎯"
        case .zhipu: return "🟣"
        case .openai: return "🅾️"
        case .anthropic: return "🅰️"
        case .google: return "🇬"
        case .moonshot: return "🌙"
        }
    }
    
    var requiresAPIKey: Bool {
        true  // 所有提供商都需要 API Key
    }

    var isOpenAICompatible: Bool {
        switch self {
        case .anthropic, .google:
            return false
        case .deepseek, .doubao, .zhipu, .openai, .moonshot:
            return true
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai:
            return "https://api.openai.com/v1"
        case .anthropic:
            return "https://api.anthropic.com/v1"
        case .google:
            return "https://generativelanguage.googleapis.com/v1"
        case .moonshot:
            return "https://api.moonshot.cn/v1"
        case .deepseek:
            return "https://api.deepseek.com/v1"
        case .doubao:
            return "https://ark.cn-beijing.volces.com/api/v3"
        case .zhipu:
            return "https://open.bigmodel.cn/api/paas/v4"
        }
    }

    var modelLabel: String {
        switch self {
        case .doubao:
            return "模型 / Endpoint"
        default:
            return "模型"
        }
    }

    var modelPlaceholder: String {
        switch self {
        case .openai:
            return "gpt-4o"
        case .anthropic:
            return "claude-opus-4"
        case .google:
            return "gemini-2.0-flash"
        case .moonshot:
            return "kimi-k2.5"
        case .deepseek:
            return "deepseek-chat"
        case .doubao:
            return "例如 Doubao-1.5-pro-32k 或 ep-xxxx"
        case .zhipu:
            return "glm-4.7"
        }
    }

    var setupHint: String? {
        switch self {
        case .doubao:
            return "豆包通过火山方舟接入。大多数场景可直接填写豆包模型名；如果你在方舟里创建了自定义接入点，也可以把 Endpoint ID 填到模型字段。"
        case .deepseek:
            return "DeepSeek 使用 OpenAI 兼容接口，默认走 /chat/completions。"
        case .zhipu:
            return "智谱默认走通用对话接口 /api/paas/v4/chat/completions。"
        default:
            return nil
        }
    }
    
    /// 获取最新的可用模型列表
    var availableModels: [String] {
        switch self {
        case .deepseek:
            return [
                "deepseek-chat",
                "deepseek-reasoner",
            ]

        case .doubao:
            return [
                "Doubao-1.5-pro-32k",
                "Doubao-1.5-thinking-pro",
                "Doubao-1.5-vision-pro-32k",
                "doubao-seed-code-preview-latest",
            ]

        case .zhipu:
            return [
                "glm-4.7",
                "glm-4.7-flash",
                "glm-4.5-air",
                "glm-4.5v",
            ]
            
        case .openai:
            // 2025 年最新 OpenAI 模型
            return [
                "gpt-4o",           // 旗舰多模态模型（推荐）
                "gpt-4o-mini",      // 轻量快速
                "gpt-4-turbo",      // 4 Turbo
                "gpt-4",            // GPT-4 基础版
                "o3-mini",          // 推理模型
            ]
            
        case .anthropic:
            // 2025 年最新 Claude 模型
            return [
                "claude-opus-4",         // 最强性能（推荐）
                "claude-sonnet-4",       // 平衡性能
                "claude-haiku-3.5",      // 快速轻量
                "claude-3-opus-20240229", // 旧版
                "claude-3-sonnet-20240229",
            ]
            
        case .moonshot:
            // 2025 年最新 Kimi 模型
            return [
                "kimi-k2.5",         // 最新多模态模型（推荐）
                "kimi-k2-32k",       // 32k 上下文
                "kimi-k2",           // K2 基础版
                "kimi-k1.5",         // K1.5
            ]
            
        case .google:
            // 2025 年最新 Google 模型
            return [
                "gemini-2.0-flash",        // 最新多模态（推荐）
                "gemini-2.0-flash-thinking", // 推理增强
                "gemini-1.5-pro",          // 1.5 Pro
                "gemini-1.5-flash",        // 1.5 Flash
            ]
        }
    }
    
    /// 默认推荐模型（最新最强）
    var recommendedModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .doubao: return "Doubao-1.5-pro-32k"
        case .zhipu: return "glm-4.7"
        case .openai: return "gpt-4o"
        case .anthropic: return "claude-opus-4"
        case .moonshot: return "kimi-k2.5"
        case .google: return "gemini-2.0-flash"
        }
    }
    
    /// 支持视觉/图片分析的模型
    var visionModels: [String] {
        switch self {
        case .deepseek:
            return []
        case .doubao:
            return ["Doubao-1.5-vision-pro-32k", "doubao-seed-code-preview-latest"]
        case .zhipu:
            return ["glm-4.5v"]
        case .openai:
            return ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-4-vision-preview"]
        case .anthropic:
            return ["claude-opus-4", "claude-sonnet-4", "claude-3-opus-20240229", "claude-3-sonnet-20240229"]
        case .moonshot:
            return ["kimi-k2.5", "kimi-k2-32k"] // K2.5 支持视觉
        case .google:
            return ["gemini-2.0-flash", "gemini-2.0-flash-thinking", "gemini-1.5-pro", "gemini-1.5-flash", "gemini-pro-vision"]
        }
    }
    
    var apiKeyPlaceholder: String {
        switch self {
        case .deepseek: return "sk-..."
        case .doubao: return "火山方舟 API Key"
        case .zhipu: return "智谱 API Key"
        case .openai: return "sk-..."
        case .anthropic: return "sk-ant-..."
        case .google: return "AIza..."
        case .moonshot: return "sk-..."
        }
    }
    
    var apiDocsURL: String {
        switch self {
        case .deepseek: return "https://api-docs.deepseek.com/"
        case .doubao: return "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey?"
        case .zhipu: return "https://open.bigmodel.cn/"
        case .openai: return "https://platform.openai.com/api-keys"
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .google: return "https://makersuite.google.com/app/apikey"
        case .moonshot: return "https://platform.moonshot.cn/console/api-keys"
        }
    }
}

// MARK: - Capabilities

enum Capability: String, CaseIterable, Codable {
    case textChat
    case codeAnalysis
    case imageAnalysis
    case vision
    case documentAnalysis
    case longContext
    case voiceRecognition
    case webSearch
    
    var displayName: String {
        switch self {
        case .textChat: return "文本对话"
        case .codeAnalysis: return "代码分析"
        case .imageAnalysis: return "图片分析"
        case .vision: return "视觉理解"
        case .documentAnalysis: return "文档分析"
        case .longContext: return "长上下文"
        case .voiceRecognition: return "语音识别"
        case .webSearch: return "网络搜索"
        }
    }
    
    var icon: String {
        switch self {
        case .textChat: return "bubble.left.fill"
        case .codeAnalysis: return "chevron.left.forwardslash.chevron.right"
        case .imageAnalysis: return "photo.fill"
        case .vision: return "eye.fill"
        case .documentAnalysis: return "doc.text.fill"
        case .longContext: return "book.fill"
        case .voiceRecognition: return "waveform"
        case .webSearch: return "magnifyingglass"
        }
    }
    
    var description: String {
        switch self {
        case .textChat:
            return "自然语言对话和问答"
        case .codeAnalysis:
            return "代码理解、生成和重构"
        case .imageAnalysis:
            return "分析图片内容和含义"
        case .vision:
            return "视觉理解（看图说话）"
        case .documentAnalysis:
            return "处理长文档和 PDF"
        case .longContext:
            return "处理超长文本（100K+ tokens）"
        case .voiceRecognition:
            return "识别和转录语音"
        case .webSearch:
            return "实时网络搜索"
        }
    }
}

enum AgentRole: String, CaseIterable, Codable, Identifiable, Hashable {
    case primaryChat
    case planner
    case subtaskWorker
    case fallback
    case manualOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .primaryChat:
            return "主会话"
        case .planner:
            return "Planner"
        case .subtaskWorker:
            return "子任务"
        case .fallback:
            return "回退"
        case .manualOnly:
            return "仅手动"
        }
    }

    var summary: String {
        switch self {
        case .primaryChat:
            return "可作为主对话 Agent，承接主会话回答。"
        case .planner:
            return "可作为秘书层 / Planner，负责意图分析与调度。"
        case .subtaskWorker:
            return "可作为独立 side task worker，不打断主会话。"
        case .fallback:
            return "主 Agent 失败时可作为自动回退候选。"
        case .manualOnly:
            return "只在用户手动选择时使用，不参与自动路由。"
        }
    }

    var icon: String {
        switch self {
        case .primaryChat:
            return "text.bubble"
        case .planner:
            return "point.topleft.down.curvedto.point.bottomright.up"
        case .subtaskWorker:
            return "square.stack.3d.up"
        case .fallback:
            return "arrow.trianglehead.clockwise"
        case .manualOnly:
            return "hand.raised"
        }
    }
}

struct AgentRoleProfile: Codable, Hashable {
    var roles: Set<AgentRole>

    init(roles: Set<AgentRole> = []) {
        if roles.contains(.manualOnly) {
            self.roles = [.manualOnly]
        } else {
            self.roles = roles
        }
    }

    var sortedRoles: [AgentRole] {
        AgentRole.allCases.filter { roles.contains($0) }
    }

    func contains(_ role: AgentRole) -> Bool {
        roles.contains(role)
    }

    mutating func set(_ role: AgentRole, enabled: Bool) {
        if role == .manualOnly {
            roles = enabled ? [.manualOnly] : []
            return
        }

        if enabled {
            roles.remove(.manualOnly)
            roles.insert(role)
        } else {
            roles.remove(role)
        }
    }

    static func suggested(
        provider: ProviderType,
        capabilities: [Capability],
        isFirstAgent: Bool
    ) -> AgentRoleProfile {
        var roles: Set<AgentRole> = [.fallback]

        if isFirstAgent || capabilities.contains(.codeAnalysis) {
            roles.insert(.primaryChat)
        }

        roles.insert(.planner)
        roles.insert(.subtaskWorker)

        if capabilities.contains(.vision) || capabilities.contains(.documentAnalysis) {
            roles.insert(.subtaskWorker)
        }

        return AgentRoleProfile(roles: roles)
    }
}

// MARK: - Agent

struct Agent: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let description: String
    let provider: ProviderType
    let model: String
    let capabilities: [Capability]
    let config: AgentConfig
    var isDefault: Bool
    var createdAt: Date
    var lastUsedAt: Date?
    
    init(
        id: String = "agent-\(UUID().uuidString.prefix(8))",
        name: String,
        emoji: String,
        description: String,
        provider: ProviderType,
        model: String,
        capabilities: [Capability],
        config: AgentConfig = AgentConfig(),
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.description = description
        self.provider = provider
        self.model = model
        self.capabilities = capabilities
        self.config = config
        self.isDefault = isDefault
        self.createdAt = Date()
        self.lastUsedAt = nil
    }
    
    /// 检查是否支持特定能力
    func supports(_ capability: Capability) -> Bool {
        capabilities.contains(capability)
    }
    
    /// 检查是否支持图片分析（vision 或 imageAnalysis）
    var supportsImageAnalysis: Bool {
        supports(.vision) || supports(.imageAnalysis)
    }
    
    /// 模型是否为最新
    var isLatestModel: Bool {
        provider.recommendedModel == model
    }
    
    /// 格式化显示名称
    var displayName: String {
        "\(emoji) \(name)"
    }
    
    /// 简短描述
    var shortDescription: String {
        "\(provider.displayName) · \(model)"
    }

    /// 兼容旧 UI 状态显示
    var isActive: Bool { true }
}

// MARK: - Agent Config

struct AgentConfig: Codable, Hashable {
    var temperature: Double
    var maxTokens: Int
    var topP: Double?
    var presencePenalty: Double?
    var frequencyPenalty: Double?
    
    init(
        temperature: Double = 0.7,
        maxTokens: Int = 4096,
        topP: Double? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
    }
}

// MARK: - Capability Gap

struct CapabilityGap: Identifiable, Codable {
    struct SuggestedAgent: Codable, Hashable {
        let name: String
        let emoji: String
        let description: String
        let provider: ProviderType
        let model: String
    }

    let id = UUID()
    let missingCapability: Capability
    let suggestedProviders: [ProviderType]
    let description: String
    let context: String?
    
    init(
        missingCapability: Capability,
        suggestedProviders: [ProviderType],
        description: String? = nil,
        context: String? = nil
    ) {
        self.missingCapability = missingCapability
        self.suggestedProviders = suggestedProviders
        self.description = description ?? "缺少 \(missingCapability.displayName) 能力"
        self.context = context
    }

    var solutionDescription: String {
        "建议创建一个支持 \(missingCapability.displayName) 的 Agent。"
    }

    var suggestedAgents: [SuggestedAgent] {
        suggestedProviders.map { provider in
            SuggestedAgent(
                name: "\(provider.displayName) \(missingCapability.displayName)",
                emoji: provider.defaultEmoji,
                description: provider.recommendedDescription(for: missingCapability),
                provider: provider,
                model: provider.recommendedModel
            )
        }
    }
}

private extension ProviderType {
    var defaultEmoji: String {
        switch self {

        case .deepseek: return "🧠"
        case .doubao: return "🎯"
        case .zhipu: return "🟣"
        case .openai: return "🅾️"
        case .anthropic: return "🅰️"
        case .google: return "🇬"
        case .moonshot: return "🌙"
        }
    }

    func recommendedDescription(for capability: Capability) -> String {
        switch capability {
        case .vision, .imageAnalysis:
            return "适合图片理解和截图分析"
        case .codeAnalysis:
            return "适合代码审查、解释和排错"
        case .documentAnalysis, .longContext:
            return "适合长文档和复杂上下文处理"
        case .webSearch:
            return "适合联网检索和实时信息"
        default:
            return "适合日常对话与任务处理"
        }
    }
}

// MARK: - Intent

enum Intent {
    case generalChat
    case codeAnalysis
    case imageAnalysis
    case documentAnalysis
    case webSearch
    case voiceCommand
    case agentManagement
    
    var requiredCapability: Capability {
        switch self {
        case .generalChat: return .textChat
        case .codeAnalysis: return .codeAnalysis
        case .imageAnalysis: return .vision
        case .documentAnalysis: return .documentAnalysis
        case .webSearch: return .webSearch
        case .voiceCommand: return .voiceRecognition
        case .agentManagement: return .textChat
        }
    }
    
    var displayName: String {
        switch self {
        case .generalChat: return "一般对话"
        case .codeAnalysis: return "代码分析"
        case .imageAnalysis: return "图片分析"
        case .documentAnalysis: return "文档分析"
        case .webSearch: return "网络搜索"
        case .voiceCommand: return "语音命令"
        case .agentManagement: return "Agent 管理"
        }
    }
}

// MARK: - Routing Result

enum RoutingResult {
    case agentSelected(Agent)
    case gapDetected(CapabilityGap)
    case multipleAgents([Agent])
}

// MARK: - Agent Statistics

struct AgentStatistics: Codable {
    var totalMessages: Int = 0
    var totalTokens: Int = 0
    var averageResponseTime: Double = 0
    var lastUsedAt: Date?
}
