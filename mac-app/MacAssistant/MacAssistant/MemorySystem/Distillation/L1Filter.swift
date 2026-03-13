//
//  L1Filter.swift
//  MacAssistant
//
//  L1: Raw to Filtered Distillation (Phase 2)
//

import Foundation

/// L1 蒸馏引擎：从 L0 提取关键信息
actor L1DistillationEngine {
    
    private let importanceScorer: ImportanceScorer
    private let factExtractor: FactExtractor
    private let summarizer: Summarizer
    
    init() {
        self.importanceScorer = ImportanceScorer()
        self.factExtractor = FactExtractor()
        self.summarizer = Summarizer()
    }
    
    /// 蒸馏单个 L0 条目
    func distill(_ rawEntry: RawMemoryEntry) async throws -> FilteredMemoryEntry? {
        // Phase 2 实现：重要性评分
        let importance = await importanceScorer.score(rawEntry)
        
        guard importance.rawValue >= ImportanceScore.normal.rawValue else {
            return nil  // 低于阈值，丢弃
        }
        
        // 提取关键事实
        let facts = await factExtractor.extract(from: rawEntry)
        
        // 生成摘要
        let summary = await summarizer.summarize(rawEntry.output.response, maxLength: 200)
        
        // 提取实体
        let entities = await extractEntities(from: rawEntry)
        
        return FilteredMemoryEntry(
            id: rawEntry.id.childID(in: .filtered),
            sourceId: rawEntry.id,
            timestamp: rawEntry.timestamp,
            importance: importance,
            keyFacts: facts,
            decisions: extractDecisions(from: rawEntry),
            outcomes: extractOutcomes(from: rawEntry),
            summary: summary,
            keywords: extractKeywords(from: rawEntry),
            entities: entities,
            searchableContent: buildSearchableContent(summary, facts),
            category: classifyCategory(rawEntry),
            sentiment: analyzeSentiment(rawEntry)
        )
    }
    
    /// 批量蒸馏
    func distillBatch(_ entries: [RawMemoryEntry]) async throws -> [FilteredMemoryEntry] {
        var results: [FilteredMemoryEntry] = []
        
        for entry in entries {
            if let distilled = try? await distill(entry) {
                results.append(distilled)
            }
        }
        
        return results
    }
    
    // MARK: - Private Methods
    
    private func extractEntities(from entry: RawMemoryEntry) async -> [EntityReference] {
        // 使用 NER 或规则提取实体
        // 简化实现
        []
    }
    
    private func extractDecisions(from entry: RawMemoryEntry) -> [DecisionPoint] {
        // 识别决策点
        []
    }
    
    private func extractOutcomes(from entry: RawMemoryEntry) -> [TaskOutcome] {
        // 提取结果
        [TaskOutcome(
            success: entry.executionTrace.errorInfo == nil,
            result: String(entry.output.response.prefix(100)),
            metrics: [
                "durationMs": Double(entry.executionTrace.durationMs),
                "tokenCount": Double(entry.executionTrace.tokenUsage?.totalTokens ?? 0)
            ]
        )]
    }
    
    private func extractKeywords(from entry: RawMemoryEntry) -> [String] {
        // 关键词提取
        entry.input.prompt.split(separator: " ").map { String($0) }
    }
    
    private func buildSearchableContent(_ summary: String, _ facts: [KeyFact]) -> String {
        var content = summary
        if !facts.isEmpty {
            content += "\n" + facts.map { "\($0.subject) \($0.predicate) \($0.object)" }.joined(separator: "\n")
        }
        return content
    }
    
    private func classifyCategory(_ entry: RawMemoryEntry) -> MemoryCategory {
        // 分类逻辑
        if entry.executionTrace.errorInfo != nil {
            return .errorResolution
        }
        return .technicalDecision
    }
    
    private func analyzeSentiment(_ entry: RawMemoryEntry) -> Sentiment {
        // 情感分析
        entry.executionTrace.errorInfo != nil ? .negative : .neutral
    }
}

// MARK: - Supporting Components

actor ImportanceScorer {
    func score(_ entry: RawMemoryEntry) async -> ImportanceScore {
        var score = 0
        
        // 错误 = 重要
        if entry.executionTrace.errorInfo != nil {
            score += 2
        }
        
        // 重试 = 重要
        score += entry.executionTrace.retryCount
        
        // 长耗时 = 重要
        if entry.executionTrace.durationMs > 5000 {
            score += 1
        }
        
        // 用户输入 = 重要
        if entry.type == .userInput {
            score += 2
        }
        
        switch score {
        case 0...1: return .trivial
        case 2: return .normal
        case 3...4: return .significant
        default: return .critical
        }
    }
}

actor FactExtractor {
    func extract(from entry: RawMemoryEntry) async -> [KeyFact] {
        // 使用 LLM 或规则提取三元组
        // 简化实现
        []
    }
}

actor Summarizer {
    func summarize(_ text: String, maxLength: Int) async -> String {
        // 摘要生成
        if text.count <= maxLength {
            return text
        }
        return String(text.prefix(maxLength)) + "..."
    }
}
