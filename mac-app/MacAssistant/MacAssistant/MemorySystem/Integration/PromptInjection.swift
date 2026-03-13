//
//  PromptInjection.swift
//  MacAssistant
//
//  Phase 4: Context to Prompt Conversion
//

import Foundation

/// Prompt 注入配置
struct PromptInjectionConfig {
    /// 是否启用记忆注入
    var enabled: Bool = true
    
    /// Token 预算分配
    var l2TokenAllocation: Int = 500
    var l1TokenAllocation: Int = 800
    var l0TokenAllocation: Int = 300
    
    /// 注入位置
    var injectionPosition: InjectionPosition = .afterSystem
    
    /// 格式模板
    var format: InjectionFormat = .structured
    
    /// 是否包含置信度
    var includeConfidence: Bool = true
    
    /// 是否包含来源引用
    var includeCitations: Bool = true
    
    /// 相关度阈值
    var relevanceThreshold: Double = 0.6
    
    static let `default` = PromptInjectionConfig()
    static let minimal = PromptInjectionConfig(
        l2TokenAllocation: 200,
        l1TokenAllocation: 300,
        l0TokenAllocation: 100,
        format: .compact
    )
}

enum InjectionPosition {
    case afterSystem      // 在 System Prompt 后
    case beforeUser       // 在用户消息前
    case asSystemPrefix   // 作为 System Prompt 前缀
}

enum InjectionFormat {
    case structured       // 结构化 XML/JSON 格式
    case natural          // 自然语言段落
    case compact          // 极简格式
    case markdown         // Markdown 列表
}

// MARK: - Prompt Builder

/// Prompt 构建器：将检索到的上下文转换为 Prompt 文本
actor PromptContextBuilder {
    
    private let config: PromptInjectionConfig
    
    init(config: PromptInjectionConfig = .default) {
        self.config = config
    }
    
    // MARK: - Main API
    
    /// 构建完整的记忆上下文 Prompt
    func buildPrompt(
        from context: RetrievedContext,
        userQuery: String? = nil
    ) -> String {
        guard config.enabled else { return "" }
        
        var sections: [String] = []
        
        // 按格式构建各部分
        switch config.format {
        case .structured:
            sections.append(buildStructuredHeader())
            sections.append(buildL2Section(context.cognition))
            sections.append(buildL1Section(context.facts))
            sections.append(buildL0Section(context.recent))
            sections.append(buildSemanticSection(context.semantic))
            sections.append(buildStructuredFooter())
            
        case .natural:
            sections.append(buildNaturalLanguageContext(context))
            
        case .compact:
            sections.append(buildCompactContext(context))
            
        case .markdown:
            sections.append(buildMarkdownContext(context))
        }
        
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    
    /// 构建 System Prompt 扩展
    func buildSystemPromptExtension(
        from context: RetrievedContext
    ) -> String {
        guard config.enabled else { return "" }
        
        var parts: [String] = []
        
        // 核心信念（高置信度）
        let highConfidenceBeliefs = context.cognition.beliefs
            .filter { $0.confidence >= 0.8 }
            .prefix(3)
        
        if !highConfidenceBeliefs.isEmpty {
            parts.append("已知事实:")
            for belief in highConfidenceBeliefs {
                parts.append("- \(belief.statement)")
            }
        }
        
        // 可行洞察
        if let insight = context.cognition.insights.first {
            parts.append("\n建议策略: \(insight.insight)")
        }
        
        return parts.joined(separator: "\n")
    }
    
    /// 构建用户上下文前缀
    func buildUserContextPrefix(
        from context: RetrievedContext
    ) -> String {
        guard config.enabled else { return "" }
        
        var parts: [String] = []
        
        // 近期活动摘要
        if !context.recent.isEmpty {
            parts.append("近期活动:")
            for activity in context.recent.prefix(3) {
                let timeAgo = formatTimeAgo(activity.timestamp)
                parts.append("- [\(timeAgo)] \(activity.description)")
            }
            parts.append("")
        }
        
        // 相关概念
        if !context.cognition.concepts.isEmpty {
            let conceptNames = context.cognition.concepts
                .prefix(5)
                .map(\.name)
                .joined(separator: ", ")
            parts.append("相关概念: \(conceptNames)")
        }
        
        return parts.joined(separator: "\n")
    }
    
    // MARK: - Structured Format
    
    private func buildStructuredHeader() -> String {
        "<memory_context>"
    }
    
    private func buildStructuredFooter() -> String {
        "</memory_context>"
    }
    
    private func buildL2Section(_ cognition: L2CognitionContext) -> String {
        guard !cognition.concepts.isEmpty else { return "" }
        
        var parts: [String] = []
        parts.append("  <cognition_layer>")
        
        // 概念
        if !cognition.concepts.isEmpty {
            parts.append("    <concepts>")
            for concept in cognition.concepts.prefix(5) {
                let confidenceStr = config.includeConfidence ? " confidence=\"\(Int(concept.confidence * 100))%\"" : ""
                parts.append("      <concept\(confidenceStr)>\(concept.name): \(concept.definition)</concept>")
            }
            parts.append("    </concepts>")
        }
        
        // 信念
        let beliefs = cognition.beliefs.filter { $0.confidence >= config.relevanceThreshold }
        if !beliefs.isEmpty {
            parts.append("    <beliefs>")
            for belief in beliefs.prefix(3) {
                let conf = config.includeConfidence ? " [\(Int(belief.confidence * 100))%]" : ""
                parts.append("      <belief>\(belief.statement)\(conf)</belief>")
            }
            parts.append("    </beliefs>")
        }
        
        // 洞察
        if !cognition.insights.isEmpty {
            parts.append("    <insights>")
            for insight in cognition.insights.prefix(2) {
                parts.append("      <insight applicable=\"\(insight.applicability.joined(separator: ", "))\">\(insight.insight)</insight>")
            }
            parts.append("    </insights>")
        }
        
        parts.append("  </cognition_layer>")
        return parts.joined(separator: "\n")
    }
    
    private func buildL1Section(_ facts: [RelevantFact]) -> String {
        guard !facts.isEmpty else { return "" }
        
        var parts: [String] = []
        parts.append("  <fact_layer>")
        
        for fact in facts.prefix(5) {
            let conf = config.includeConfidence ? " confidence=\"\(Int(fact.confidence * 100))%\"" : ""
            let source = config.includeCitations ? " source=\"\(fact.source)\"" : ""
            parts.append("    <fact\(conf)\(source)>\(fact.statement)</fact>")
        }
        
        parts.append("  </fact_layer>")
        return parts.joined(separator: "\n")
    }
    
    private func buildL0Section(_ recent: [RecentActivity]) -> String {
        guard !recent.isEmpty else { return "" }
        
        var parts: [String] = []
        parts.append("  <recent_activity>")
        
        for activity in recent.prefix(5) {
            let timeAgo = formatTimeAgo(activity.timestamp)
            parts.append("    <activity time=\"\(timeAgo)\" type=\"\(activity.type)\">\(activity.description)</activity>")
        }
        
        parts.append("  </recent_activity>")
        return parts.joined(separator: "\n")
    }
    
    private func buildSemanticSection(_ semantic: [SemanticMatch]) -> String {
        guard !semantic.isEmpty else { return "" }
        
        var parts: [String] = []
        parts.append("  <semantic_matches>")
        
        for match in semantic.prefix(3) {
            parts.append("    <match score=\"\(Int(match.similarity * 100))%\" layer=\"\(match.layer)\">\(match.entryId)</match>")
        }
        
        parts.append("  </semantic_matches>")
        return parts.joined(separator: "\n")
    }
    
    // MARK: - Natural Language Format
    
    private func buildNaturalLanguageContext(_ context: RetrievedContext) -> String {
        var parts: [String] = []
        parts.append("根据我的记忆，以下信息可能相关：")
        
        // 概念和定义
        for concept in context.cognition.concepts.prefix(3) {
            parts.append("\(concept.name)是指\(concept.definition)。")
        }
        
        // 信念
        for belief in context.cognition.beliefs.prefix(2) {
            parts.append("已知\(belief.statement)。")
        }
        
        // 近期活动
        if !context.recent.isEmpty {
            parts.append("\n最近的活动包括：")
            for activity in context.recent.prefix(3) {
                parts.append("- \(activity.description)")
            }
        }
        
        return parts.joined(separator: "\n")
    }
    
    // MARK: - Compact Format
    
    private func buildCompactContext(_ context: RetrievedContext) -> String {
        var parts: [String] = []
        
        let concepts = context.cognition.concepts.prefix(3).map(\.name).joined(separator: ", ")
        let beliefs = context.cognition.beliefs.prefix(2).map(\.statement).joined(separator: "; ")
        
        if !concepts.isEmpty {
            parts.append("[C] \(concepts)")
        }
        if !beliefs.isEmpty {
            parts.append("[B] \(beliefs)")
        }
        if !context.recent.isEmpty {
            parts.append("[R] \(context.recent.count) activities")
        }
        
        return parts.joined(separator: " | ")
    }
    
    // MARK: - Markdown Format
    
    private func buildMarkdownContext(_ context: RetrievedContext) -> String {
        var parts: [String] = []
        parts.append("## 记忆上下文")
        
        if !context.cognition.concepts.isEmpty {
            parts.append("\n### 相关概念")
            for concept in context.cognition.concepts.prefix(5) {
                parts.append("- **\(concept.name)**: \(concept.definition)")
            }
        }
        
        if !context.cognition.beliefs.isEmpty {
            parts.append("\n### 已知事实")
            for belief in context.cognition.beliefs.prefix(3) {
                let conf = Int(belief.confidence * 100)
                parts.append("- \(belief.statement) (置信度: \(conf)%)")
            }
        }
        
        if !context.facts.isEmpty {
            parts.append("\n### 相关事实")
            for fact in context.facts.prefix(5) {
                parts.append("- \(fact.statement)")
            }
        }
        
        return parts.joined(separator: "\n")
    }
    
    // MARK: - Helpers
    
    private func formatTimeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        
        if interval < 60 {
            return "刚刚"
        } else if interval < 3600 {
            return "\(Int(interval / 60))分钟前"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))小时前"
        } else {
            return "\(Int(interval / 86400))天前"
        }
    }
}

// MARK: - Token Budget Manager

/// Token 预算管理器（非 actor，纯计算）
struct TokenBudgetManager {
    
    struct BudgetAllocation {
        let l2Allocation: Int
        let l1Allocation: Int
        let l0Allocation: Int
        let totalUsed: Int
    }
    
    /// 计算最优预算分配
    func allocateBudget(
        totalBudget: Int,
        l2Available: Int,
        l1Available: Int,
        l0Available: Int
    ) -> BudgetAllocation {
        // 优先级：L2 > L1 > L0
        let l2Weight = 0.4
        let l1Weight = 0.4
        let l0Weight = 0.2
        
        let l2Allocation = min(
            Int(Double(totalBudget) * l2Weight),
            l2Available
        )
        
        let remainingAfterL2 = totalBudget - l2Allocation
        let l1Allocation = min(
            Int(Double(remainingAfterL2) * (l1Weight / (l1Weight + l0Weight))),
            l1Available
        )
        
        let l0Allocation = min(
            remainingAfterL2 - l1Allocation,
            l0Available
        )
        
        return BudgetAllocation(
            l2Allocation: l2Allocation,
            l1Allocation: l1Allocation,
            l0Allocation: l0Allocation,
            totalUsed: l2Allocation + l1Allocation + l0Allocation
        )
    }
    
    /// 估算文本的 token 数
    func estimateTokens(_ text: String) -> Int {
        // 简化估算：平均每个 token 约 4 个字符
        return text.count / 4
    }
    
    /// 截断文本到指定 token 数
    func truncateToTokens(_ text: String, maxTokens: Int) -> String {
        let estimatedTokens = estimateTokens(text)
        guard estimatedTokens > maxTokens else { return text }
        
        // 计算目标字符数
        let targetChars = maxTokens * 4
        return String(text.prefix(targetChars)) + "..."
    }
}

// MARK: - Context Injection Result

/// 上下文注入结果
struct ContextInjectionResult {
    /// 注入的 Prompt 文本
    let prompt: String
    
    /// 注入位置
    let position: InjectionPosition
    
    /// 使用的 Token 数
    let tokenCount: Int
    
    /// 包含的记忆层
    let includedLayers: [MemoryLayer]
    
    /// 置信度分数
    let confidence: Double
    
    /// 是否成功
    let isSuccess: Bool
    
    /// 错误信息（如果有）
    let error: String?
}
