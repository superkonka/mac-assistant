//
//  AgentOrchestrator.swift
//  MacAssistant
//
//  智能请求路由和 Agent 选择
//

import Foundation
import Combine

class AgentOrchestrator: ObservableObject {
    @Published var currentAgent: Agent?
    @Published var recentAgents: [Agent] = []
    
    static let shared = AgentOrchestrator()
    
    private let agentStore = AgentStore.shared
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupBindings()
    }
    
    private func setupBindings() {
        agentStore.$currentAgent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agent in
                self?.currentAgent = agent
                if let agent = agent {
                    self?.addToRecent(agent)
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 意图分析
    
    /// 分析用户输入的意图
    func analyzeIntent(_ input: String) async -> Intent {
        let lowercased = input.lowercased()
        
        // 关键词匹配
        if containsAny(lowercased, ["截图", "图片", "图像", "看图", "分析图", "这是什么图"]) {
            return .imageAnalysis
        }
        
        if containsAny(lowercased, ["代码", "编程", "bug", "debug", "函数", "类", "swift", "python"]) {
            return .codeAnalysis
        }
        
        if containsAny(lowercased, ["文档", "pdf", "文件", "论文", "报告", "长文"]) {
            return .documentAnalysis
        }
        
        if containsAny(lowercased, ["搜索", "查找", "查一下", "google", "百度"]) {
            return .webSearch
        }
        
        if containsAny(lowercased, ["创建 agent", "新 agent", "添加 agent", "agent 设置"]) {
            return .agentManagement
        }
        
        // 默认一般对话
        return .generalChat
    }
    
    // MARK: - 路由决策
    
    /// 路由请求到合适的 Agent
    func route(_ input: String, images: [String] = [], intent: Intent? = nil) async -> RoutingResult {
        await route(input, images: images, intent: intent, preferCurrentAgent: false)
    }

    func route(
        _ input: String,
        images: [String] = [],
        intent: Intent? = nil,
        preferCurrentAgent: Bool
    ) async -> RoutingResult {
        let targetIntent: Intent
        if let intent {
            targetIntent = intent
        } else {
            targetIntent = await analyzeIntent(input)
        }
        let requiredCapability = targetIntent.requiredCapability

        if preferCurrentAgent,
           images.isEmpty,
           let current = currentAgent,
           current.supports(.textChat),
           targetIntent != .imageAnalysis,
           targetIntent != .voiceCommand {
            return .agentSelected(current)
        }
        
        // 1. 检查当前 Agent
        if let current = currentAgent {
            if current.supports(requiredCapability) {
                // 当前 Agent 支持
                return .agentSelected(current)
            }
        }
        
        // 2. 查找支持该能力的 Agents
        let suitableAgents = agentStore.autoRoutableAgentsSupporting(requiredCapability)
        
        if suitableAgents.isEmpty {
            // 3. 无可用 Agent，检测能力缺口
            let gap = createCapabilityGap(
                requiredCapability: requiredCapability,
                context: input
            )
            return .gapDetected(gap)
        }
        
        if suitableAgents.count == 1 {
            // 4. 只有一个可用，直接选择
            return .agentSelected(suitableAgents[0])
        }
        
        // 5. 多个可用，返回列表让用户选择（或根据偏好自动选择）
        return .multipleAgents(suitableAgents)
    }
    
    /// 发现能力缺口（用于截图等场景）
    func discoverGap(for context: String) -> CapabilityGap? {
        // 检查是否有视觉能力
        let visionAgents = agentStore.visionAgents
        
        if visionAgents.isEmpty {
            return createCapabilityGap(
                requiredCapability: .vision,
                context: context
            )
        }
        
        return nil
    }
    
    // MARK: - Agent 切换
    
    /// 切换到指定 Agent
    func switchToAgent(_ agent: Agent) {
        agentStore.switchToAgent(agent)
    }
    
    /// 根据能力自动切换 Agent
    func autoSwitch(for capability: Capability) -> Agent? {
        let suitable = agentStore.autoRoutableAgentsSupporting(capability)
        
        if let first = suitable.first {
            switchToAgent(first)
            return first
        }
        
        return nil
    }
    
    // MARK: - 智能建议
    
    /// 获取 Agent 建议
    func getSuggestion(for input: String) -> String? {
        // 1. 检查是否需要 Vision
        if input.contains("截图") || input.contains("图片") {
            if agentStore.visionAgents.isEmpty {
                return "💡 您需要图片分析能力。建议创建一个 Vision Agent。"
            }
        }
        
        // 2. 检查模型是否过时
        if let current = currentAgent, !current.isLatestModel {
            return "💡 您正在使用旧版模型 \(current.model)，建议升级到 \(current.provider.recommendedModel)"
        }
        
        return nil
    }
    
    // MARK: - 辅助方法
    
    /// 创建能力缺口
    private func createCapabilityGap(
        requiredCapability: Capability,
        context: String? = nil
    ) -> CapabilityGap {
        let suggestedProviders: [ProviderType]
        let description: String
        
        switch requiredCapability {
        case .vision, .imageAnalysis:
            suggestedProviders = [.openai, .anthropic, .moonshot, .doubao, .zhipu]
            description = "需要图片分析能力来分析图像内容"
        case .codeAnalysis:
            suggestedProviders = [.deepseek, .doubao, .anthropic, .openai, .moonshot]
            description = "需要代码分析能力来处理编程相关请求"
        case .documentAnalysis:
            suggestedProviders = [.anthropic, .moonshot, .deepseek, .zhipu, .openai, .doubao]
            description = "需要文档分析能力来处理长文本"
        case .webSearch:
            suggestedProviders = [.google, .moonshot, .openai, .zhipu]
            description = "需要网络搜索能力来获取实时信息"
        default:
            suggestedProviders = ProviderType.allCases
            description = "需要 \(requiredCapability.displayName) 能力"
        }
        
        return CapabilityGap(
            missingCapability: requiredCapability,
            suggestedProviders: suggestedProviders,
            description: description,
            context: context
        )
    }
    
    /// 添加到最近使用
    private func addToRecent(_ agent: Agent) {
        recentAgents.removeAll { $0.id == agent.id }
        recentAgents.insert(agent, at: 0)
        
        // 限制数量
        if recentAgents.count > 5 {
            recentAgents = Array(recentAgents.prefix(5))
        }
    }
    
    /// 字符串包含检查
    private func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}

// MARK: - 路由结果扩展

extension RoutingResult {
    /// 是否检测到缺口
    var isGap: Bool {
        if case .gapDetected = self { return true }
        return false
    }
    
    /// 获取选中的 Agent（如果有）
    var selectedAgent: Agent? {
        if case .agentSelected(let agent) = self {
            return agent
        }
        return nil
    }
    
    /// 获取能力缺口（如果有）
    var capabilityGap: CapabilityGap? {
        if case .gapDetected(let gap) = self {
            return gap
        }
        return nil
    }
}
