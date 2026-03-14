//
//  ContextInjector.swift
//  MacAssistant
//
//  Phase 4: Automatic Context Injection into Agent Execution
//

import Foundation
import OpenClawKit

// MARK: - Prepared Execution

/// 准备好的执行上下文
struct PreparedExecution {
    /// 最终 System Prompt
    let systemPrompt: String?
    
    /// 最终 User Message
    let userMessage: String
    
    /// 完整的记忆上下文（用于后续存储）
    let memoryContext: RetrievedContext?
    
    /// 注入结果详情
    let injectionResult: ContextInjectionResult
}

/// 上下文注入器：在 Agent 执行前自动注入记忆上下文
actor ContextInjector {
    
    // MARK: - Dependencies
    
    private let contextBuilder: MemoryContextBuilder
    private let promptBuilder: PromptContextBuilder
    private let budgetManager: TokenBudgetManager
    private let config: PromptInjectionConfig
    
    init(
        contextBuilder: MemoryContextBuilder,
        config: PromptInjectionConfig = .default
    ) {
        self.contextBuilder = contextBuilder
        self.promptBuilder = PromptContextBuilder(config: config)
        self.budgetManager = TokenBudgetManager()
        self.config = config
    }
    
    // MARK: - Main API
    
    /// 为 Agent 执行准备带上下文的输入
    func prepareExecution(
        planId: String,
        taskId: String? = nil,
        agentId: String,
        userMessage: String,
        systemPrompt: String? = nil,
        availableBudget: Int = 2000
    ) async -> PreparedExecution {
        
        LogInfo("[ContextInjector] Preparing execution for plan:\(planId), agent:\(agentId)")
        
        do {
            // 1. 构建记忆状态
            let state = MemorySystemState(
                planId: planId,
                taskId: taskId,
                agentId: agentId,
                recentKeywords: extractKeywords(from: userMessage),
                currentIntent: inferIntent(from: userMessage)
            )
            
            // 2. 根据预算调整偏好
            var preferences = ContextPreferences.default
            preferences.maxConcepts = min(10, availableBudget / 100)
            preferences.maxFacts = min(10, availableBudget / 80)
            preferences.maxRecentItems = min(5, availableBudget / 150)
            
            // 3. 检索上下文
            let context = try await contextBuilder.buildContext(
                for: state,
                preferences: preferences
            )
            
            // 4. 计算预算分配
            let l2Text = context.cognition.concepts.map { "\($0.name): \($0.definition)" }.joined(separator: "\n")
            let l1Text = context.facts.map(\.statement).joined(separator: "\n")
            let l0Text = context.recent.map(\.description).joined(separator: "\n")
            
            let budget = budgetManager.allocateBudget(
                totalBudget: availableBudget,
                l2Available: await budgetManager.estimateTokens(l2Text),
                l1Available: await budgetManager.estimateTokens(l1Text),
                l0Available: await budgetManager.estimateTokens(l0Text)
            )
            
            // 5. 构建注入 Prompt
            let memoryPrompt = await promptBuilder.buildPrompt(from: context)
            let truncatedPrompt = await budgetManager.truncateToTokens(
                memoryPrompt,
                maxTokens: availableBudget
            )
            
            // 6. 组装最终 Prompt
            let (finalSystemPrompt, finalUserMessage) = assemblePrompts(
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                memoryPrompt: truncatedPrompt,
                position: config.injectionPosition
            )
            
            let tokenCount = await budgetManager.estimateTokens(truncatedPrompt)
            
            LogInfo("[ContextInjector] Injected \(tokenCount) tokens of context")
            
            return PreparedExecution(
                systemPrompt: finalSystemPrompt,
                userMessage: finalUserMessage,
                memoryContext: context,
                injectionResult: ContextInjectionResult(
                    prompt: truncatedPrompt,
                    position: config.injectionPosition,
                    tokenCount: tokenCount,
                    includedLayers: determineIncludedLayers(context),
                    confidence: calculateConfidence(context),
                    isSuccess: true,
                    error: nil
                )
            )
            
        } catch {
            LogError("[ContextInjector] Failed to prepare execution: \(error)")
            
            // 返回原始输入（无记忆注入）
            return PreparedExecution(
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                memoryContext: nil,
                injectionResult: ContextInjectionResult(
                    prompt: "",
                    position: config.injectionPosition,
                    tokenCount: 0,
                    includedLayers: [],
                    confidence: 0,
                    isSuccess: false,
                    error: error.localizedDescription
                )
            )
        }
    }
    
    /// 快速注入：仅使用 L2 认知层
    func injectCognitionOnly(
        planId: String,
        systemPrompt: String? = nil,
        userMessage: String
    ) async -> PreparedExecution {
        
        var minimalConfig = config
        minimalConfig.l1TokenAllocation = 0
        minimalConfig.l0TokenAllocation = 0
        
        let tempBuilder = PromptContextBuilder(config: minimalConfig)
        
        do {
            let state = MemorySystemState(
                planId: planId,
                taskId: nil,
                agentId: nil,
                recentKeywords: [],
                currentIntent: nil
            )
            
            let context = try await contextBuilder.buildContext(
                for: state,
                preferences: .minimal
            )
            
            let memoryPrompt = await tempBuilder.buildSystemPromptExtension(from: context)
            
            let (finalSystem, finalUser) = assemblePrompts(
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                memoryPrompt: memoryPrompt,
                position: .asSystemPrefix
            )
            
            return PreparedExecution(
                systemPrompt: finalSystem,
                userMessage: finalUser,
                memoryContext: context,
                injectionResult: ContextInjectionResult(
                    prompt: memoryPrompt,
                    position: .asSystemPrefix,
                    tokenCount: await budgetManager.estimateTokens(memoryPrompt),
                    includedLayers: [.distilled],
                    confidence: 0.8,
                    isSuccess: true,
                    error: nil
                )
            )
            
        } catch {
            return PreparedExecution(
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                memoryContext: nil,
                injectionResult: ContextInjectionResult(
                    prompt: "",
                    position: .asSystemPrefix,
                    tokenCount: 0,
                    includedLayers: [],
                    confidence: 0,
                    isSuccess: false,
                    error: error.localizedDescription
                )
            )
        }
    }
    
    /// 增量注入：只注入新信息
    func injectDelta(
        planId: String,
        lastInjectedContext: RetrievedContext?,
        systemPrompt: String? = nil,
        userMessage: String
    ) async -> PreparedExecution {
        
        let fullContext = try? await contextBuilder.buildContext(
            for: MemorySystemState(
                planId: planId,
                taskId: nil,
                agentId: nil,
                recentKeywords: extractKeywords(from: userMessage),
                currentIntent: nil
            ),
            preferences: .default
        )
        
        guard let context = fullContext else {
            return PreparedExecution(
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                memoryContext: nil,
                injectionResult: ContextInjectionResult(
                    prompt: "",
                    position: config.injectionPosition,
                    tokenCount: 0,
                    includedLayers: [],
                    confidence: 0,
                    isSuccess: false,
                    error: "Failed to build context"
                )
            )
        }
        
        // 计算增量
        let deltaContext = calculateDelta(
            current: context,
            previous: lastInjectedContext
        )
        
        let memoryPrompt = await promptBuilder.buildPrompt(from: deltaContext)
        
        let (finalSystem, finalUser) = assemblePrompts(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            memoryPrompt: memoryPrompt,
            position: config.injectionPosition
        )
        
        return PreparedExecution(
            systemPrompt: finalSystem,
            userMessage: finalUser,
            memoryContext: context,
            injectionResult: ContextInjectionResult(
                prompt: memoryPrompt,
                position: config.injectionPosition,
                tokenCount: await budgetManager.estimateTokens(memoryPrompt),
                includedLayers: determineIncludedLayers(deltaContext),
                confidence: calculateConfidence(deltaContext),
                isSuccess: true,
                error: nil
            )
        )
    }
    
    // MARK: - Private Methods
    
    private func assemblePrompts(
        systemPrompt: String?,
        userMessage: String,
        memoryPrompt: String,
        position: InjectionPosition
    ) -> (systemPrompt: String?, userMessage: String) {
        
        guard !memoryPrompt.isEmpty else {
            return (systemPrompt, userMessage)
        }
        
        switch position {
        case .afterSystem:
            let newSystem: String
            if let existing = systemPrompt {
                newSystem = existing + "\n\n" + memoryPrompt
            } else {
                newSystem = memoryPrompt
            }
            return (newSystem, userMessage)
            
        case .beforeUser:
            let newUser = memoryPrompt + "\n\n" + userMessage
            return (systemPrompt, newUser)
            
        case .asSystemPrefix:
            let newSystem: String
            if let existing = systemPrompt {
                newSystem = memoryPrompt + "\n\n" + existing
            } else {
                newSystem = memoryPrompt
            }
            return (newSystem, userMessage)
        }
    }
    
    private func extractKeywords(from text: String) -> [String] {
        // 简单关键词提取：去掉停用词，取名词
        let stopWords = Set(["的", "了", "是", "在", "我", "有", "和", "就", "不", "人", "都", "一", "一个", "上", "也", "很", "到", "说", "要", "去", "你", "会", "着", "没有", "看", "好", "自己", "这", "那"])
        
        return text
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { $0.count > 1 }
            .filter { !stopWords.contains($0) }
            .map { $0.lowercased() }
            .uniqued()
    }
    
    private func inferIntent(from text: String) -> String? {
        // 简单意图识别
        if text.contains("?") || text.contains("？") || text.contains("怎么") || text.contains("如何") {
            return "question"
        } else if text.contains("做") || text.contains("创建") || text.contains("生成") {
            return "creation"
        } else if text.contains("改") || text.contains("修改") || text.contains("更新") {
            return "modification"
        } else if text.contains("删") || text.contains("删除") {
            return "deletion"
        }
        return nil
    }
    
    private func determineIncludedLayers(_ context: RetrievedContext) -> [MemoryLayer] {
        var layers: [MemoryLayer] = []
        if !context.cognition.concepts.isEmpty { layers.append(.distilled) }
        if !context.facts.isEmpty { layers.append(.filtered) }
        if !context.recent.isEmpty { layers.append(.raw) }
        return layers
    }
    
    private func calculateConfidence(_ context: RetrievedContext) -> Double {
        var scores: [Double] = []
        
        if !context.cognition.beliefs.isEmpty {
            let avgConfidence = context.cognition.beliefs.map(\.confidence).reduce(0, +) / Double(context.cognition.beliefs.count)
            scores.append(avgConfidence)
        }
        
        if !context.facts.isEmpty {
            let avgConfidence = context.facts.map(\.confidence).reduce(0, +) / Double(context.facts.count)
            scores.append(avgConfidence)
        }
        
        return scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
    }
    
    private func calculateDelta(
        current: RetrievedContext,
        previous: RetrievedContext?
    ) -> RetrievedContext {
        guard let previous = previous else { return current }
        
        // 返回只有新信息的上下文
        let newConcepts = current.cognition.concepts.filter { concept in
            !previous.cognition.concepts.contains { $0.id == concept.id }
        }
        
        let newBeliefs = current.cognition.beliefs.filter { belief in
            !previous.cognition.beliefs.contains { $0.id == belief.id }
        }
        
        let newFacts = current.facts.filter { fact in
            !previous.facts.contains { $0.statement == fact.statement }
        }
        
        return RetrievedContext(
            cognition: L2CognitionContext(
                concepts: newConcepts,
                beliefs: newBeliefs,
                insights: [],
                relations: []
            ),
            facts: newFacts,
            recent: current.recent,
            semantic: [],
            graph: current.graph,
            timestamp: Date(),
            tokenEstimate: current.tokenEstimate
        )
    }
}

// MARK: - Array Extension

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
