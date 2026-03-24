//
//  ConversationRuntimeAdapter.swift
//  MacAssistant
//
//  运行时适配器 - 纯原生实现
//

import Foundation

// 兼容别名
typealias ClawRuntimeAdapter = ConversationRuntimeAdapter

protocol ConversationRuntimeAdapter: Actor {
    func sendMessage(
        agent: Agent,
        sessionKey: String,
        sessionLabel: String?,
        requestID: String,
        text: String,
        images: [String],
        systemPrompt: String?,
        onAssistantText: (@Sendable (String) async -> Void)?
    ) async throws -> String

    func skillsStatus() async throws -> SkillsStatusReport

    func recoverInterruptedTaskOutput(
        sessionKey: String,
        requestStartedAt: Date,
        latestAssistantText: String
    ) async -> RecoveredOutput?

    func injectAssistantMessage(
        sessionKey: String,
        message: String,
        label: String?
    ) async throws
}

// MARK: - 原生运行时适配器

actor NativeConversationRuntimeAdapter: ConversationRuntimeAdapter {
    static let shared = NativeConversationRuntimeAdapter()

    private let llmClient = UnifiedLLMClient.shared
    private let localKimiCLIService = LocalKimiCLIService.shared

    func sendMessage(
        agent: Agent,
        sessionKey: String,
        sessionLabel: String?,
        requestID: String,
        text: String,
        images: [String],
        systemPrompt: String? = nil,
        onAssistantText: (@Sendable (String) async -> Void)?
    ) async throws -> String {
        
        // 构建 LLM 消息
        var messages: [LLMMessage] = []
        
        // System prompt
        if let system = systemPrompt, !system.isEmpty {
            messages.append(LLMMessage(role: .system, content: system))
        }
        
        // 处理图片附件
        var imageAttachments: [LLMImageAttachment] = []
        for path in images {
            if let attachment = try? loadImageAttachment(at: path) {
                imageAttachments.append(attachment)
            }
        }
        
        // User message
        messages.append(LLMMessage(role: .user, content: text, images: imageAttachments))
        
        // 获取运行时配置
        let profile = try await runtimeProfile(for: agent)
        
        // 映射 Provider 名称
        let providerName = mapProviderName(agent.provider)
        
        // 发送请求
        return try await llmClient.send(
            providerName: providerName,
            model: profile.model,
            messages: messages,
            temperature: agent.config.temperature,
            maxTokens: agent.config.maxTokens,
            apiKey: profile.apiKey,
            baseURL: profile.baseURL,
            stream: onAssistantText != nil,
            onChunk: onAssistantText
        )
    }

    func skillsStatus() async throws -> SkillsStatusReport {
        // 原生运行时返回空技能列表
        return SkillsStatusReport.empty
    }

    func recoverInterruptedTaskOutput(
        sessionKey: String,
        requestStartedAt: Date,
        latestAssistantText: String
    ) async -> RecoveredOutput? {
        // 原生运行时暂不支持自动恢复
        return nil
    }

    func injectAssistantMessage(
        sessionKey: String,
        message: String,
        label: String?
    ) async throws {
        // 原生运行时无需注入
        LogDebug("[NativeRuntime] injectAssistantMessage noop: \(message.prefix(50))")
    }

    // MARK: - 私有方法

    private func runtimeProfile(for agent: Agent) async throws -> AgentStore.RuntimeProfile {
        let profile = await MainActor.run { AgentStore.shared.runtimeProfile(for: agent) }
        guard let profile else {
            throw NSError(
                domain: "NativeConversationRuntimeAdapter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(agent.displayName) 缺少认证配置，请重新配置该 Agent。"]
            )
        }
        return profile
    }

    private func mapProviderName(_ provider: ProviderType) -> String {
        switch provider {
        case .openai:
            return "OpenAICompatible"
        case .anthropic:
            return "Anthropic"
        case .google:
            return "Google"
        case .deepseek, .doubao, .zhipu, .moonshot, .minimax:
            // 这些都是 OpenAI 兼容格式
            return "OpenAICompatible"
        case .ollama:
            // Ollama 走特殊路径
            return "Ollama"
        }
    }

    private func loadImageAttachment(at path: String) throws -> LLMImageAttachment {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let mimeType = mimeType(for: url.pathExtension)
        return LLMImageAttachment(data: data, mimeType: mimeType)
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - OpenClaw 运行时适配器（占位符）

actor OpenClawRuntimeAdapter: ConversationRuntimeAdapter {
    static let shared = OpenClawRuntimeAdapter()

    func sendMessage(
        agent: Agent,
        sessionKey: String,
        sessionLabel: String?,
        requestID: String,
        text: String,
        images: [String],
        systemPrompt: String?,
        onAssistantText: (@Sendable (String) async -> Void)?
    ) async throws -> String {
        throw NSError(domain: "Runtime", code: -1, userInfo: [NSLocalizedDescriptionKey: "请使用原生运行时"])
    }

    func skillsStatus() async throws -> SkillsStatusReport {
        return .empty
    }

    func recoverInterruptedTaskOutput(
        sessionKey: String,
        requestStartedAt: Date,
        latestAssistantText: String
    ) async -> RecoveredOutput? {
        return nil
    }

    func injectAssistantMessage(
        sessionKey: String,
        message: String,
        label: String?
    ) async throws {
        // No-op
    }
}
