//
//  AgentRegistry.swift
//  MacAssistant
//
//  轻量级 Agent 注册表
//  只管理配置，不管理执行
//

import Foundation
import Combine
import SwiftUI

/// Agent 配置描述符
/// 只包含配置信息，不包含执行状态
struct AgentDescriptor: Codable, Identifiable {
    let id: String
    var name: String
    var emoji: String
    var description: String
    
    // 能力标签（用于路由选择）
    var capabilities: [CapabilityTag]
    
    // Provider 配置引用
    var providerRef: ProviderReference
    
    // 用户偏好
    var preferences: AgentPreferences
    
    // 元数据
    var createdAt: Date
    var updatedAt: Date
    
    struct ProviderReference: Codable {
        let providerId: String      // Provider 类型ID (openai/anthropic/kimi等)
        let modelId: String         // 模型ID
        var apiKeyRef: String?      // API Key 引用（不是实际密钥）
        var baseURL: String?        // 自定义 base URL
    }
    
    struct AgentPreferences: Codable {
        var temperature: Double?
        var maxTokens: Int?
        var systemPrompt: String?
        var preferredResponseLanguage: String?
    }
}

/// 能力标签
enum CapabilityTag: String, Codable, CaseIterable {
    case text         = "text"          // 通用文本
    case code         = "code"          // 代码
    case vision       = "vision"        // 视觉/图片
    case longContext  = "long_context"  // 长上下文
    case reasoning    = "reasoning"     // 推理
    case creative     = "creative"      // 创意
    case toolUse      = "tool_use"      // 工具使用
    case skillUse     = "skill_use"     // 技能使用
    
    // UI 展示属性
    var displayName: String {
        switch self {
        case .text: return "文本"
        case .code: return "代码"
        case .vision: return "视觉"
        case .longContext: return "长上下文"
        case .reasoning: return "推理"
        case .creative: return "创意"
        case .toolUse: return "工具"
        case .skillUse: return "技能"
        }
    }
    
    var shortName: String {
        switch self {
        case .text: return "文本"
        case .code: return "代码"
        case .vision: return "视觉"
        case .longContext: return "长文"
        case .reasoning: return "推理"
        case .creative: return "创意"
        case .toolUse: return "工具"
        case .skillUse: return "技能"
        }
    }
    
    var icon: String {
        switch self {
        case .text: return "text.bubble"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .vision: return "eye"
        case .longContext: return "doc.text"
        case .reasoning: return "brain"
        case .creative: return "lightbulb"
        case .toolUse: return "wrench"
        case .skillUse: return "puzzlepiece"
        }
    }
    
    var color: Color {
        switch self {
        case .text: return .blue
        case .code: return .green
        case .vision: return .purple
        case .longContext: return .orange
        case .reasoning: return .pink
        case .creative: return .yellow
        case .toolUse: return .gray
        case .skillUse: return .cyan
        }
    }
}

/// Agent 注册表
/// 职责：
/// 1. 管理 Agent 配置（CRUD）
/// 2. 根据能力标签解析合适的 Agent
/// 3. 同步配置到 OpenClaw Core
class AgentRegistry: ObservableObject {
    static let shared = AgentRegistry()
    
    // MARK: - 状态
    
    @Published private(set) var agents: [AgentDescriptor] = []
    @Published private(set) var defaultAgentId: String?
    
    // MARK: - 持久化
    
    private let storageKey = "agent.descriptors"
    private let defaults = UserDefaults.standard
    
    // MARK: - 初始化
    
    init() {
        loadFromStorage()
    }
    
    // MARK: - CRUD 操作
    
    /// 注册新 Agent
    func register(_ descriptor: AgentDescriptor) {
        agents.append(descriptor)
        saveToStorage()
        
        // 同步到 OpenClaw Core
        syncToOpenClaw()
    }
    
    /// 更新 Agent
    func update(_ descriptor: AgentDescriptor) {
        if let index = agents.firstIndex(where: { $0.id == descriptor.id }) {
            var updated = descriptor
            updated.updatedAt = Date()
            agents[index] = updated
            saveToStorage()
            syncToOpenClaw()
        }
    }
    
    /// 删除 Agent
    func remove(_ agentId: String) {
        agents.removeAll { $0.id == agentId }
        if defaultAgentId == agentId {
            defaultAgentId = agents.first?.id
        }
        saveToStorage()
        syncToOpenClaw()
    }
    
    /// 设置默认 Agent
    func setDefault(_ agentId: String) {
        guard agents.contains(where: { $0.id == agentId }) else { return }
        defaultAgentId = agentId
        saveToStorage()
    }
    
    // MARK: - 查询
    
    /// 根据 ID 获取 Agent
    func get(_ agentId: String) -> AgentDescriptor? {
        agents.first { $0.id == agentId }
    }
    
    /// 根据能力标签解析 Agent
    /// 返回最适合该能力的 Agent
    func resolve(for capability: CapabilityTag) -> AgentDescriptor? {
        // 1. 优先找有明确该能力的 Agent
        if let specialized = agents.first(where: { 
            $0.capabilities.contains(capability) 
        }) {
            return specialized
        }
        
        // 2. 返回默认 Agent
        if let defaultId = defaultAgentId,
           let defaultAgent = get(defaultId) {
            return defaultAgent
        }
        
        // 3. 返回第一个 Agent
        return agents.first
    }
    
    /// 获取多个能力匹配的 Agent 列表（按匹配度排序）
    func resolveMultiple(for capabilities: [CapabilityTag]) -> [AgentDescriptor] {
        return agents.sorted { a, b in
            let aScore = a.capabilities.filter { capabilities.contains($0) }.count
            let bScore = b.capabilities.filter { capabilities.contains($0) }.count
            return aScore > bScore
        }
    }
    
    /// 检查是否存在指定能力的 Agent
    func hasAgent(with capability: CapabilityTag) -> Bool {
        agents.contains { $0.capabilities.contains(capability) }
    }
    
    // MARK: - 批量操作
    
    /// 导入 Agent 配置
    func importAgents(_ descriptors: [AgentDescriptor]) {
        for descriptor in descriptors {
            if !agents.contains(where: { $0.id == descriptor.id }) {
                agents.append(descriptor)
            }
        }
        saveToStorage()
        syncToOpenClaw()
    }
    
    /// 导出 Agent 配置
    func exportAgents() -> [AgentDescriptor] {
        agents
    }
    
    /// 重置为默认配置
    func resetToDefaults() {
        // 可以预设一些默认 Agent
        let defaultAgents = createDefaultAgents()
        agents = defaultAgents
        defaultAgentId = defaultAgents.first?.id
        saveToStorage()
        syncToOpenClaw()
    }
    
    // MARK: - 同步到 OpenClaw Core
    
    /// 将 Agent 配置同步到 OpenClaw Core
    /// 应用层不直接管理 Agent 执行，只提供配置
    func syncToOpenClaw() {
        // 转换为 OpenClaw Core 的配置格式
        let openClawConfig = agents.map { agent in
            OpenClawAgentConfig(
                id: agent.id,
                name: agent.name,
                model: OpenClawModelConfig(
                    provider: mapProvider(agent.providerRef.providerId),
                    primary: agent.providerRef.modelId,
                    fallbacks: []
                ),
                capabilities: agent.capabilities.map { $0.rawValue }
            )
        }
        
        // 发送到 OpenClaw Gateway 更新配置
        // 实际实现需要通过 GatewayClient 发送配置更新消息
        Task {
            // await GatewayClient.shared.updateAgentConfig(openClawConfig)
        }
    }
    
    // MARK: - 私有方法
    
    private func loadFromStorage() {
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([AgentDescriptor].self, from: data) else {
            // 首次使用，创建默认 Agent
            let defaults = createDefaultAgents()
            self.agents = defaults
            self.defaultAgentId = defaults.first?.id
            return
        }
        agents = saved
        defaultAgentId = saved.first?.id
    }
    
    private func saveToStorage() {
        if let data = try? JSONEncoder().encode(agents) {
            defaults.set(data, forKey: storageKey)
        }
    }
    
    private func createDefaultAgents() -> [AgentDescriptor] {
        [
            AgentDescriptor(
                id: "default-kimi",
                name: "Kimi",
                emoji: "🌙",
                description: "Moonshot Kimi 助手，适合通用对话",
                capabilities: [.text, .code, .vision, .longContext],
                providerRef: .init(
                    providerId: "moonshot",
                    modelId: "kimi-k2.5",
                    apiKeyRef: nil,
                    baseURL: nil
                ),
                preferences: .init(
                    temperature: 0.7,
                    maxTokens: 8192,
                    systemPrompt: "你是 Kimi，一个有帮助的 AI 助手。",
                    preferredResponseLanguage: "zh"
                ),
                createdAt: Date(),
                updatedAt: Date()
            ),
            AgentDescriptor(
                id: "default-claude",
                name: "Claude",
                emoji: "🅰️",
                description: "Anthropic Claude，适合复杂推理",
                capabilities: [.text, .code, .reasoning, .creative],
                providerRef: .init(
                    providerId: "anthropic",
                    modelId: "claude-sonnet-4",
                    apiKeyRef: nil,
                    baseURL: nil
                ),
                preferences: .init(
                    temperature: 0.5,
                    maxTokens: 4096,
                    systemPrompt: "你是 Claude，一个 AI 助手。",
                    preferredResponseLanguage: "zh"
                ),
                createdAt: Date(),
                updatedAt: Date()
            )
        ]
    }
    
    private func mapProvider(_ providerId: String) -> String {
        // 映射应用层的 provider ID 到 OpenClaw Core 的 provider 名称
        switch providerId {
        case "moonshot": return "moonshot"
        case "anthropic": return "anthropic"
        case "openai": return "openai"
        case "deepseek": return "deepseek"
        case "doubao": return "doubao"
        default: return providerId
        }
    }
}

// MARK: - OpenClaw 配置结构

struct OpenClawAgentConfig: Codable {
    let id: String
    let name: String
    let model: OpenClawModelConfig
    let capabilities: [String]
}

struct OpenClawModelConfig: Codable {
    let provider: String
    let primary: String
    let fallbacks: [String]
}
