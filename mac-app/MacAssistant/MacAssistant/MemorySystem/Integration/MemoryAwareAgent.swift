//
//  MemoryAwareAgent.swift
//  MacAssistant
//
//  Phase 4: Memory-Aware Agent Protocol and Decorator
//

import Foundation
import OpenClawKit

/// 记忆感知 Agent 协议
/// 记忆感知 Agent 协议（使用 OpenClawKit.Agent）
protocol MemoryAwareAgentProtocol {
    /// Agent ID
    var agentId: String { get }
    
    /// 所属 Plan ID
    var planId: String { get }
    
    /// 当前任务 ID（如果有）
    var taskId: String? { get }
    
    /// 是否启用记忆
    var memoryEnabled: Bool { get }
    
    /// 上下文注入配置
    var injectionConfig: PromptInjectionConfig { get }
    
    /// 执行带记忆的消息发送
    func sendMessageWithMemory(
        message: String,
        systemPrompt: String?,
        contextBudget: Int
    ) async throws -> AgentResponse
}

/// Agent 响应（带记忆元数据）
struct AgentResponse {
    /// 原始响应文本
    let content: String
    
    /// 使用的记忆上下文
    let memoryContext: RetrievedContext?
    
    /// 注入详情
    let injectionResult: ContextInjectionResult?
    
    /// Token 使用统计
    let tokenUsage: TokenUsage?
    
    /// 执行元数据
    let metadata: [String: AnyCodable]
}

struct TokenUsage {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
}

// MARK: - Memory-Aware Agent Decorator

/// 记忆感知 Agent 装饰器
actor MemoryAwareAgentDecorator: MemoryAwareAgentProtocol {
    
    // MARK: - Properties
    
    let agentId: String
    let planId: String
    let taskId: String?
    let memoryEnabled: Bool
    let injectionConfig: PromptInjectionConfig
    
    private let underlyingAgent: Agent
    private let contextInjector: ContextInjector
    private let coordinator: MemoryCoordinator
    
    // MARK: - Initialization
    
    init(
        agent: Agent,
        planId: String,
        taskId: String? = nil,
        coordinator: MemoryCoordinator = .shared,
        config: PromptInjectionConfig = .default
    ) async {
        self.underlyingAgent = agent
        self.agentId = agent.id
        self.planId = planId
        self.taskId = taskId
        self.coordinator = coordinator
        self.memoryEnabled = MemoryFeatureFlags.enableNewRetrieval
        self.injectionConfig = config
        
        // 创建 ContextInjector
        let contextBuilder = await MemoryContextBuilder(
            l0Store: coordinator.l0Store,
            l1Store: coordinator.l1Store,
            l2Store: coordinator.l2Store,
            vectorStore: coordinator.vectorStore,
            graphStore: coordinator.graphStore
        )
        self.contextInjector = await ContextInjector(
            contextBuilder: contextBuilder,
            config: config
        )
    }
    
    // MARK: - MemoryAwareAgent
    
    func sendMessageWithMemory(
        message: String,
        systemPrompt: String? = nil,
        contextBudget: Int = 2000
    ) async throws -> AgentResponse {
        
        // 1. 准备带记忆的执行
        let prepared = try await prepareExecution(
            message: message,
            systemPrompt: systemPrompt,
            contextBudget: contextBudget
        )
        
        // 2. 执行实际调用
        let startTime = Date()
        let response = try await executeWithUnderlyingAgent(
            systemPrompt: prepared.systemPrompt,
            userMessage: prepared.userMessage
        )
        
        let duration = Date().timeIntervalSince(startTime)
        
        // 3. 存储执行记录到 L0
        if MemoryFeatureFlags.enableL0Storage {
            await storeExecutionRecord(
                input: message,
                response: response,
                preparedExecution: prepared,
                duration: duration
            )
        }
        
        return AgentResponse(
            content: response,
            memoryContext: prepared.memoryContext,
            injectionResult: prepared.injectionResult,
            tokenUsage: estimateTokenUsage(
                prompt: prepared.userMessage,
                response: response
            ),
            metadata: [
                "planId": AnyCodable(planId),
                "taskId": AnyCodable(taskId),
                "durationMs": AnyCodable(Int(duration * 1000)),
                "memoryInjected": AnyCodable(prepared.injectionResult.isSuccess)
            ]
        )
    }
    
    // MARK: - Private Methods
    
    private func prepareExecution(
        message: String,
        systemPrompt: String?,
        contextBudget: Int
    ) async throws -> PreparedExecution {
        
        guard memoryEnabled && MemoryFeatureFlags.enableNewRetrieval else {
            // 记忆未启用，直接返回原始输入
            return PreparedExecution(
                systemPrompt: systemPrompt,
                userMessage: message,
                memoryContext: nil,
                injectionResult: ContextInjectionResult(
                    prompt: "",
                    position: injectionConfig.injectionPosition,
                    tokenCount: 0,
                    includedLayers: [],
                    confidence: 0,
                    isSuccess: false,
                    error: "Memory retrieval disabled"
                )
            )
        }
        
        return await contextInjector.prepareExecution(
            planId: planId,
            taskId: taskId,
            agentId: agentId,
            userMessage: message,
            systemPrompt: systemPrompt,
            availableBudget: contextBudget
        )
    }
    
    private func executeWithUnderlyingAgent(
        systemPrompt: String?,
        userMessage: String
    ) async throws -> String {
        // 调用底层 Agent
        // 这里需要根据实际的 Agent 接口调整
        
        // Mock 实现 - 实际应调用 OpenClawKit 的 Agent 方法
        LogInfo("[MemoryAwareAgent] Executing with injected context")
        
        // 模拟延迟
        try await Task.sleep(nanoseconds: 100_000_000)
        
        return "Response to: \(userMessage.prefix(50))..."
    }
    
    private func storeExecutionRecord(
        input: String,
        response: String,
        preparedExecution: PreparedExecution,
        duration: TimeInterval
    ) async {
        let tokenUsage = MemoryTokenUsage(
            promptTokens: preparedExecution.injectionResult.tokenCount,
            completionTokens: response.count / 4,  // 估算
            totalTokens: (preparedExecution.injectionResult.tokenCount + response.count / 4),
            cachedTokens: nil
        )
        
        await coordinator.storeExecution(
            planId: planId,
            taskId: taskId,
            agentId: agentId,
            sessionKey: "memory-aware-session",
            prompt: input,
            response: response,
            durationMs: Int(duration * 1000),
            tokenUsage: tokenUsage,
            metadata: [
                "injectedTokens": AnyCodable(preparedExecution.injectionResult.tokenCount),
                "includedLayers": AnyCodable(preparedExecution.injectionResult.includedLayers.map(\.rawValue)),
                "injectionConfidence": AnyCodable(preparedExecution.injectionResult.confidence)
            ]
        )
    }
    
    private func estimateTokenUsage(prompt: String, response: String) -> TokenUsage {
        let promptTokens = prompt.count / 4
        let completionTokens = response.count / 4
        return TokenUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: promptTokens + completionTokens
        )
    }
}

// MARK: - Memory Agent Factory

/// 记忆感知 Agent 工厂
actor MemoryAgentFactory {
    
    private var agentCache: [String: MemoryAwareAgentDecorator] = [:]
    private let coordinator: MemoryCoordinator
    
    init(coordinator: MemoryCoordinator = .shared) {
        self.coordinator = coordinator
    }
    
    /// 创建或获取记忆感知 Agent
    func createAgent(
        baseAgent: Agent,
        planId: String,
        taskId: String? = nil,
        config: PromptInjectionConfig = .default
    ) async -> MemoryAwareAgentDecorator {
        
        let cacheKey = "\(baseAgent.id):\(planId):\(taskId ?? "main")"
        
        if let cached = agentCache[cacheKey] {
            return cached
        }
        
        let agent = await MemoryAwareAgentDecorator(
            agent: baseAgent,
            planId: planId,
            taskId: taskId,
            coordinator: coordinator,
            config: config
        )
        
        agentCache[cacheKey] = agent
        return agent
    }
    
    /// 清理指定 Plan 的 Agent 缓存
    func clearCache(forPlanId planId: String) {
        agentCache = agentCache.filter { !$0.key.contains(":\(planId):") }
    }
    
    /// 清理所有缓存
    func clearAllCache() {
        agentCache.removeAll()
    }
}

// MARK: - Convenience Extensions

extension MemoryCoordinator {
    
    /// 创建记忆感知的 Agent 包装
    func wrapAgent(
        _ agent: Agent,
        planId: String,
        taskId: String? = nil,
        config: PromptInjectionConfig = .default
    ) async -> MemoryAwareAgentDecorator {
        await MemoryAwareAgentDecorator(
            agent: agent,
            planId: planId,
            taskId: taskId,
            coordinator: self,
            config: config
        )
    }
    
    /// 快速发送带记忆的消息
    func sendMessageWithMemory(
        agent: Agent,
        planId: String,
        message: String,
        systemPrompt: String? = nil,
        contextBudget: Int = 2000
    ) async throws -> AgentResponse {
        let memoryAgent = await wrapAgent(agent, planId: planId)
        return try await memoryAgent.sendMessageWithMemory(
            message: message,
            systemPrompt: systemPrompt,
            contextBudget: contextBudget
        )
    }
}

