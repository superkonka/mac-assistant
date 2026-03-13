//
//  HierarchicalRetriever.swift
//  MacAssistant
//
//  Hierarchical Memory Retrieval (Phase 4)
//

import Foundation

/// 分层检索器：L2 → L1 → L0 扩散检索
actor HierarchicalRetriever {
    
    private let l0Store: RawMemoryStore
    private let l1Store: FilteredMemoryStore
    private let l2Store: DistilledMemoryStore
    
    init(
        l0Store: RawMemoryStore,
        l1Store: FilteredMemoryStore,
        l2Store: DistilledMemoryStore
    ) {
        self.l0Store = l0Store
        self.l1Store = l1Store
        self.l2Store = l2Store
    }
    
    /// 执行分层检索
    func retrieve(query: RetrievalQuery) async throws -> HierarchicalRetrievalResult {
        
        // 1. L2 语义检索（入口层）
        let l2Results = try await retrieveL2(query)
        
        // 2. 根据深度决定是否扩散
        var l1Results: [FilteredMemoryEntry] = []
        var l0Results: [RawMemoryEntry] = []
        var diffusionPaths: [DiffusionPath] = []
        
        if query.depth == .detailed || query.depth == .complete {
            // 扩散到 L1
            let (l1, paths1) = try await diffuseToL1(from: l2Results, query: query)
            l1Results = l1
            diffusionPaths = paths1
        }
        
        if query.depth == .complete {
            // 扩散到 L0
            let (l0, paths0) = try await diffuseToL0(from: l1Results)
            l0Results = l0
            // 合并扩散路径
            diffusionPaths = mergePaths(diffusionPaths, paths0)
        }
        
        // 3. 计算总 token 数
        let totalTokens = estimateTotalTokens(l2Results, l1Results, l0Results)
        
        return HierarchicalRetrievalResult(
            query: query,
            l2Entries: l2Results,
            l1Entries: l1Results,
            l0Entries: l0Results,
            diffusionPaths: diffusionPaths,
            totalTokens: totalTokens
        )
    }
    
    /// 快速表面检索（仅 L2）
    func surfaceRetrieve(
        query: String,
        topK: Int = 5
    ) async throws -> [DistilledMemoryEntry] {
        let embedding = try? await generateEmbedding(query)
        
        return try await l2Store.semanticSearch(
            query: query,
            embedding: embedding ?? EmbeddingVector(
                model: "default",
                dimensions: 0,
                vector: [],
                normalized: false
            ),
            topK: topK,
            filters: nil
        )
    }
    
    /// 详细检索（L2 + L1）
    func detailedRetrieve(
        query: String,
        planId: String? = nil
    ) async throws -> (l2: [DistilledMemoryEntry], l1: [FilteredMemoryEntry]) {
        let retrievalQuery = RetrievalQuery(
            text: query,
            embedding: nil,
            filters: RetrievalFilters(
                timeRange: nil,
                categories: nil,
                minImportance: .normal,
                entities: nil,
                planId: planId
            ),
            depth: .detailed,
            maxResults: 10
        )
        
        let result = try await retrieve(query: retrievalQuery)
        return (result.l2Entries, result.l1Entries)
    }
    
    /// 完整检索（L2 + L1 + L0）
    func completeRetrieve(
        query: String,
        planId: String? = nil
    ) async throws -> HierarchicalRetrievalResult {
        let retrievalQuery = RetrievalQuery(
            text: query,
            embedding: nil,
            filters: RetrievalFilters(
                timeRange: nil,
                categories: nil,
                minImportance: nil,
                entities: nil,
                planId: planId
            ),
            depth: .complete,
            maxResults: 20
        )
        
        return try await retrieve(query: retrievalQuery)
    }
    
    // MARK: - Private Methods
    
    private func retrieveL2(_ query: RetrievalQuery) async throws -> [DistilledMemoryEntry] {
        // 如果有向量，使用语义搜索
        if let embedding = query.embedding {
            return try await l2Store.semanticSearch(
                query: query.text,
                embedding: embedding,
                topK: query.maxResults,
                filters: query.filters
            )
        }
        
        // 否则使用概念匹配
        let concepts = extractConcepts(from: query.text)
        var results: [DistilledMemoryEntry] = []
        
        for concept in concepts {
            let matches = try await l2Store.queryByConcept(conceptName: concept)
            results.append(contentsOf: matches)
        }
        
        // 去重并排序
        return Array(Dictionary(grouping: results, by: { $0.id })
            .mapValues { $0.first! }
            .values)
            .sorted { $0.updateCount > $1.updateCount }
            .prefix(query.maxResults)
            .map { $0 }
    }
    
    private func diffuseToL1(
        from l2Entries: [DistilledMemoryEntry],
        query: RetrievalQuery
    ) async throws -> ([FilteredMemoryEntry], [DiffusionPath]) {
        var l1Results: [FilteredMemoryEntry] = []
        var paths: [DiffusionPath] = []
        
        for l2 in l2Entries {
            // 获取 L2 的源 L1 条目
            var sourceIds = l2.sourceIds
            
            // 如果 L2 是聚合的，可能没有明确的 sourceIds
            // 此时根据概念和关键词搜索相关 L1
            if sourceIds.isEmpty {
                let keywords = l2.concepts.map { $0.name }
                let matches = try await l1Store.queryByKeywords(
                    keywords: keywords,
                    planId: query.filters.planId
                )
                sourceIds = matches.map { $0.id }
            }
            
            // 批量获取 L1 条目
            let l1Batch = try await l1Store.batchGet(ids: sourceIds)
            
            // 相关性过滤
            let filtered = l1Batch.filter { l1 in
                relevanceScore(l1: l1, query: query) > 0.5
            }
            
            l1Results.append(contentsOf: filtered)
            
            paths.append(DiffusionPath(
                l2Id: l2.id,
                l1Ids: filtered.map(\.id),
                l0Ids: [],
                relevanceScore: calculatePathRelevance(l2: l2, l1s: filtered)
            ))
        }
        
        // 去重
        l1Results = Array(Dictionary(grouping: l1Results, by: { $0.id })
            .mapValues { $0.first! }
            .values)
        
        return (l1Results, paths)
    }
    
    private func diffuseToL0(
        from l1Entries: [FilteredMemoryEntry]
    ) async throws -> ([RawMemoryEntry], [DiffusionPath]) {
        var l0Results: [RawMemoryEntry] = []
        var paths: [DiffusionPath] = []
        
        // 按原始 L2 分组
        let groupedByL2 = Dictionary(grouping: l1Entries) { l1 in
            // 找到对应的 L2（简化：通过 planId 和 segmentId 关联）
            l1.id.planId
        }
        
        for (planId, l1s) in groupedByL2 {
            for l1 in l1s {
                if let l0 = try? await l0Store.get(id: l1.sourceId) {
                    l0Results.append(l0)
                }
            }
            
            // 构建扩散路径
            let l1Ids = l1s.map(\.id)
            let l0Ids = l0Results.map(\.id)
            
            // 找到对应的 L2 ID
            if let l2Id = l1s.first?.id.childID(in: .distilled) {
                paths.append(DiffusionPath(
                    l2Id: l2Id,
                    l1Ids: l1Ids,
                    l0Ids: l0Ids,
                    relevanceScore: 0.7
                ))
            }
        }
        
        return (l0Results, paths)
    }
    
    private func relevanceScore(l1: FilteredMemoryEntry, query: RetrievalQuery) -> Double {
        var score: Double = 0
        
        // 关键词匹配
        let queryWords = Set(query.text.lowercased().split(separator: " "))
        let keywordMatches = l1.keywords.filter { keyword in
            queryWords.contains(Substring(keyword.lowercased()))
        }.count
        score += Double(keywordMatches) * 0.2
        
        // 重要性加权
        score += Double(l1.importance.rawValue) * 0.1
        
        // 时间衰减（越新越好）
        let age = Date().timeIntervalSince(l1.timestamp)
        let recency = max(0, 1 - age / (7 * 24 * 3600))  // 7天内满分
        score += recency * 0.2
        
        return min(1.0, score)
    }
    
    private func calculatePathRelevance(
        l2: DistilledMemoryEntry,
        l1s: [FilteredMemoryEntry]
    ) -> Double {
        guard !l1s.isEmpty else { return 0 }
        let avgImportance = l1s.map { Double($0.importance.rawValue) }.reduce(0, +) / Double(l1s.count)
        return avgImportance / 4.0
    }
    
    private func extractConcepts(from text: String) -> [String] {
        // 简单实现：提取名词短语
        // 实际应使用 NLP
        text.split(separator: " ").map(String.init)
    }
    
    private func generateEmbedding(_ text: String) async throws -> EmbeddingVector {
        // 调用嵌入服务
        // 简化实现
        EmbeddingVector(
            model: "mock",
            dimensions: 0,
            vector: [],
            normalized: false
        )
    }
    
    private func estimateTotalTokens(
        _ l2: [DistilledMemoryEntry],
        _ l1: [FilteredMemoryEntry],
        _ l0: [RawMemoryEntry]
    ) -> Int {
        var total = 0
        
        // L2: 概念和信念
        for entry in l2 {
            total += entry.concepts.count * 50
            total += entry.beliefs.count * 100
        }
        
        // L1: 摘要
        for entry in l1 {
            total += entry.summary.count / 4
        }
        
        // L0: 完整响应
        for entry in l0 {
            total += entry.output.response.count / 4
        }
        
        return total
    }
    
    private func mergePaths(_ paths1: [DiffusionPath], _ paths2: [DiffusionPath]) -> [DiffusionPath] {
        // 合并相同 L2 的路径
        var merged: [MemoryID: DiffusionPath] = [:]
        
        for path in paths1 + paths2 {
            if let existing = merged[path.l2Id] {
                merged[path.l2Id] = DiffusionPath(
                    l2Id: path.l2Id,
                    l1Ids: Array(Set(existing.l1Ids + path.l1Ids)),
                    l0Ids: Array(Set(existing.l0Ids + path.l0Ids)),
                    relevanceScore: max(existing.relevanceScore, path.relevanceScore)
                )
            } else {
                merged[path.l2Id] = path
            }
        }
        
        return Array(merged.values)
    }
}

// MARK: - Memory Context Assembler

actor MemoryContextAssembler {
    
    /// 组装检索结果为 LLM 可用上下文
    func assemble(
        retrievalResult: HierarchicalRetrievalResult,
        budget: ContextBudget
    ) -> AssembledContext {
        
        var sections: [ContextSection] = []
        var usedTokens = 0
        
        // 1. L2 核心概念（最高优先级）
        for entry in retrievalResult.l2Entries.prefix(3) {
            let content = formatL2(entry)
            let tokens = estimateTokens(content)
            
            if usedTokens + tokens <= budget.l2Allocation {
                sections.append(ContextSection(
                    title: "认知: \(entry.concepts.first?.name ?? "Concept")",
                    content: content,
                    layer: .distilled,
                    relevanceScore: 0.95,
                    sourceIds: [entry.id]
                ))
                usedTokens += tokens
            }
        }
        
        // 2. L1 关键信息
        let remainingBudget = budget.totalTokens - usedTokens
        let l1Budget = min(budget.l1Allocation, Int(Double(remainingBudget) * 0.7))
        
        for entry in retrievalResult.l1Entries
            .sorted(by: { $0.importance > $1.importance })
            .prefix(5) {
            
            let content = formatL1(entry)
            let tokens = estimateTokens(content)
            
            if usedTokens + tokens <= usedTokens + l1Budget {
                sections.append(ContextSection(
                    title: entry.summary.prefix(30) + "...",
                    content: content,
                    layer: .filtered,
                    relevanceScore: Double(entry.importance.rawValue) / 4.0,
                    sourceIds: [entry.id]
                ))
                usedTokens += tokens
            }
        }
        
        // 3. L0 细节（如果有空间）
        if usedTokens < Int(Double(budget.totalTokens) * 0.9) && !retrievalResult.l0Entries.isEmpty {
            let content = formatL0(retrievalResult.l0Entries)
            sections.append(ContextSection(
                title: "执行记录 (\(retrievalResult.l0Entries.count)条)",
                content: content,
                layer: .raw,
                relevanceScore: 0.5,
                sourceIds: retrievalResult.l0Entries.map(\.id)
            ))
        }
        
        return AssembledContext(
            sections: sections,
            totalTokens: usedTokens,
            coverage: calculateCoverage(sections, retrievalResult)
        )
    }
    
    private func formatL2(_ entry: DistilledMemoryEntry) -> String {
        var parts: [String] = []
        
        // 概念
        for concept in entry.concepts.prefix(3) {
            parts.append("• \(concept.name): \(concept.definition)")
        }
        
        // 信念
        for belief in entry.beliefs.prefix(2) {
            parts.append("• 结论: \(belief.statement) (置信度:\(Int(belief.confidence*100))%)")
        }
        
        // 可执行洞察
        for insight in entry.actionableInsights.prefix(2) {
            parts.append("• 建议: \(insight.insight)")
        }
        
        return parts.joined(separator: "\n")
    }
    
    private func formatL1(_ entry: FilteredMemoryEntry) -> String {
        var parts: [String] = []
        parts.append(entry.summary)
        
        if !entry.keyFacts.isEmpty {
            parts.append("事实: " + entry.keyFacts.map {
                "\($0.subject)\($0.predicate)\($0.object)"
            }.joined(separator: ", "))
        }
        
        return parts.joined(separator: " | ")
    }
    
    private func formatL0(_ entries: [RawMemoryEntry]) -> String {
        let summaries = entries.map { entry in
            "[\(entry.type.rawValue)] \(entry.output.response.prefix(50))..."
        }
        return summaries.joined(separator: "\n")
    }
    
    private func estimateTokens(_ content: String) -> Int {
        content.count / 4
    }
    
    private func calculateCoverage(
        _ sections: [ContextSection],
        _ result: HierarchicalRetrievalResult
    ) -> ContextCoverage {
        ContextCoverage(
            l2Coverage: result.l2Entries.isEmpty ? 1.0 : min(1.0, Double(sections.filter { $0.layer == .distilled }.count) / Double(result.l2Entries.count)),
            l1Coverage: result.l1Entries.isEmpty ? 1.0 : min(1.0, Double(sections.filter { $0.layer == .filtered }.count) / Double(result.l1Entries.count)),
            l0Coverage: result.l0Entries.isEmpty ? 1.0 : (sections.contains { $0.layer == .raw } ? 1.0 : 0.0),
            gaps: []
        )
    }
}
