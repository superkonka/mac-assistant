//
//  AgentStore.swift
//  MacAssistant
//
//  Agent 管理：生命周期、持久化、OpenClaw 集成
//

import Foundation
import Combine

class AgentStore: ObservableObject {
    static let shared = AgentStore()
    
    @Published var agents: [Agent] = []
    @Published var isLoading = false
    @Published var error: String?
    
    private let userDefaults = UserDefaults.standard
    private let agentsKey = "macassistant.agents"
    
    init() {
        loadAgents()
        
        // 如果没有 Agent，创建默认的
        if agents.isEmpty {
            createDefaultAgent()
        }
    }
    
    // MARK: - 加载/保存
    
    private func loadAgents() {
        guard let data = userDefaults.data(forKey: agentsKey),
              let savedAgents = try? JSONDecoder().decode([Agent].self, from: data) else {
            return
        }
        agents = savedAgents
        LogInfo("📦 加载了 \(agents.count) 个 Agent")
    }
    
    private func saveAgents() {
        if let data = try? JSONEncoder().encode(agents) {
            userDefaults.set(data, forKey: agentsKey)
        }
    }
    
    private func createDefaultAgent() {
        let defaultAgent = Agent.default
        agents = [defaultAgent]
        saveAgents()
        
        // 同步到 OpenClaw
        syncToOpenClaw(defaultAgent)
        
        LogInfo("✅ 创建默认 Agent")
    }
    
    // MARK: - CRUD 操作
    
    /// 创建新 Agent
    func createAgent(
        name: String,
        emoji: String,
        description: String,
        provider: ProviderType,
        model: String,
        apiKey: String,
        config: AgentConfig = AgentConfig()
    ) async throws -> Agent {
        isLoading = true
        defer { isLoading = false }
        
        let id = "agent-\(UUID().uuidString.prefix(8))"
        
        // 1. 创建 Agent 对象
        let agent = Agent(
            id: id,
            name: name,
            emoji: emoji,
            description: description,
            provider: provider,
            model: model,
            capabilities: provider.defaultCapabilities,
            isActive: true,
            isDefault: false,
            config: config,
            createdAt: Date(),
            lastUsedAt: nil
        )
        
        // 2. 配置 OpenClaw
        try await configureOpenClawAgent(agent, apiKey: apiKey)
        
        // 3. 添加到列表
        await MainActor.run {
            agents.append(agent)
            saveAgents()
        }
        
        LogInfo("✅ 创建 Agent: \(name)")
        return agent
    }
    
    /// 删除 Agent
    func deleteAgent(_ agent: Agent) async throws {
        // 不能删除默认 Agent
        guard !agent.isDefault else {
            throw AgentError.cannotDeleteDefault
        }
        
        // 从 OpenClaw 删除
        try await deleteOpenClawAgent(agent)
        
        // 从列表移除
        await MainActor.run {
            agents.removeAll { $0.id == agent.id }
            saveAgents()
        }
        
        LogInfo("🗑️ 删除 Agent: \(agent.name)")
    }
    
    /// 更新 Agent
    func updateAgent(_ agent: Agent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[index] = agent
            saveAgents()
            syncToOpenClaw(agent)
            LogInfo("📝 更新 Agent: \(agent.name)")
        }
    }
    
    /// 设置默认 Agent
    func setDefaultAgent(_ agent: Agent) {
        for i in agents.indices {
            agents[i].isDefault = (agents[i].id == agent.id)
        }
        saveAgents()
        LogInfo("⭐ 设置默认 Agent: \(agent.name)")
    }
    
    /// 切换到指定 Agent（更新 Orchestrator）
    func switchToAgent(_ agent: Agent) {
        updateLastUsed(agent)
        AgentOrchestrator.shared.switchToAgent(agent)
        LogInfo("🔄 AgentStore 切换到: \(agent.name)")
    }
    
    /// 更新最后使用时间
    func updateLastUsed(_ agent: Agent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[index].lastUsedAt = Date()
            saveAgents()
        }
    }
    
    // MARK: - OpenClaw 集成
    
    /// 配置 OpenClaw Agent
    private func configureOpenClawAgent(_ agent: Agent, apiKey: String) async throws {
        let agentDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/agents/\(agent.id)/agent")
        
        // 创建目录
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        
        // 1. 创建 agent 配置
        let config: [String: Any] = [
            "models": [
                "providers": [
                    agent.provider.rawValue: [
                        "api": agent.provider.rawValue,
                        "apiKey": apiKey,
                        "models": [
                            [
                                "id": agent.model,
                                "name": agent.model
                            ]
                        ]
                    ]
                ]
            ],
            "agent": [
                "model": "\(agent.provider.rawValue)/\(agent.model)"
            ]
        ]
        
        let configData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
        let configPath = agentDir.appendingPathComponent("config.json")
        try configData.write(to: configPath)
        
        // 2. 创建 auth-profiles
        let authProfile: [String: Any] = [
            "version": 1,
            "profiles": [
                "\(agent.provider.rawValue)-primary": [
                    "type": "api_key",
                    "provider": agent.provider.rawValue,
                    "key": apiKey
                ]
            ],
            "lastGood": [
                agent.provider.rawValue: "\(agent.provider.rawValue)-primary"
            ]
        ]
        
        let authData = try JSONSerialization.data(withJSONObject: authProfile, options: .prettyPrinted)
        let authPath = agentDir.appendingPathComponent("auth-profiles.json")
        try authData.write(to: authPath)
        
        // 3. 设置权限
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath.path)
        
        LogInfo("🔧 配置 OpenClaw Agent: \(agent.id)")
    }
    
    /// 删除 OpenClaw Agent
    private func deleteOpenClawAgent(_ agent: Agent) async throws {
        let agentDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/agents/\(agent.id)")
        
        if FileManager.default.fileExists(atPath: agentDir.path) {
            try FileManager.default.removeItem(at: agentDir)
            LogInfo("🗑️ 删除 OpenClaw Agent: \(agent.id)")
        }
    }
    
    /// 同步 Agent 到 OpenClaw
    private func syncToOpenClaw(_ agent: Agent) {
        // OpenClaw 通过文件系统读取配置，无需额外同步
        // 这里可以添加路由绑定等操作
        LogDebug("🔄 同步 Agent 到 OpenClaw: \(agent.id)")
    }
    
    // MARK: - 查询
    
    /// 获取所有能力
    var allCapabilities: [Capability] {
        Array(Set(agents.flatMap { $0.capabilities }))
    }
    
    /// 根据 ID 获取 Agent
    func agent(id: String) -> Agent? {
        agents.first { $0.id == id }
    }
    
    /// 获取支持特定能力的 Agent
    func agents(capableOf capability: Capability) -> [Agent] {
        agents.filter { $0.capabilities.contains(capability) }
    }
    
    /// 获取默认 Agent
    var defaultAgent: Agent? {
        agents.first { $0.isDefault }
    }
}

// MARK: - 错误类型

enum AgentError: Error {
    case cannotDeleteDefault
    case invalidAPIKey
    case configurationFailed(String)
    case syncFailed(String)
    
    var localizedDescription: String {
        switch self {
        case .cannotDeleteDefault:
            return "不能删除默认 Agent"
        case .invalidAPIKey:
            return "无效的 API Key"
        case .configurationFailed(let msg):
            return "配置失败: \(msg)"
        case .syncFailed(let msg):
            return "同步失败: \(msg)"
        }
    }
}
