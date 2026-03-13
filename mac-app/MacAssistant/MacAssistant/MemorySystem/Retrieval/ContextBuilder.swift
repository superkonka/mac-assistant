//
//  ContextBuilder.swift
//  MacAssistant
//
//  Phase 3: L2 Cognition-aware Context Building
//

import Foundation

/// 上下文构建器：从三层记忆中检索相关信息
actor MemoryContextBuilder {
    
    // MARK: - Storage References
    
    private let l0Store: RawMemoryStore
    private let l1Store: FilteredMemoryStore
    private let l2Store: DistilledMemoryStore
    private let vectorStore: VectorStore?
    private let graphStore: KnowledgeGraphStore?
    
    init(
        l0Store: RawMemoryStore,
        l1Store: FilteredMemoryStore,
        l2Store: DistilledMemoryStore,
        vectorStore: VectorStore? = nil,
        graphStore: KnowledgeGraphStore? = nil
    ) {
        self.l0Store = l0Store
        self.l1Store = l1Store
        self.l2Store = l2Store
        self.vectorStore = vectorStore
        self.graphStore = graphStore
    }
    
    // MARK: - Main API
    
    /// 根据当前状态构建上下文
    func buildContext(
        for state: MemorySystemState,
        preferences: ContextPreferences = .default
    ) async throws -> RetrievedContext {
        
        LogInfo("[ContextBuilder] Building context for plan: \(state.planId ?? "nil")")
        
        // 1. L2 认知层检索（高层次洞察）
        let cognition = try await retrieveL2Cognition(state, preferences)
        
        // 2. L1 过滤层检索（相关事实）
        let facts = try await retrieveL1Facts(state, preferences)
        
        // 3. L0 原始层检索（近期原始数据）
        let recent = try await retrieveL0Recent(state, preferences)
        
        // 4. 语义检索（向量相似度）
        let semantic = try await retrieveSemantic(state, preferences)
        
        // 5. 图谱推理（知识图扩展）
        let graph = try await retrieveGraph(state, preferences)
        
        // 6. 组装上下文
        return RetrievedContext(
            cognition: cognition,
            facts: facts,
            recent: recent,
            semantic: semantic,
            graph: graph,
            timestamp: Date(),
            tokenEstimate: estimateTokens(cognition, facts, recent, semantic, graph)
        )
    }
    
    /// 检索相似模式
    func findSimilarPatterns(
        to entry: FilteredMemoryEntry,
        limit: Int = 5
    ) async throws -> [PatternMatch] {
        
        // 基于 L2 的模式匹配
        let l2Entries = l2Store.entries
        var matches: [PatternMatch] = []
        
        for l2Entry in l2Entries {
            // 概念重叠度
            let commonConcepts = Set(l2Entry.concepts.map(\.name))
                .intersection(entry.keywords)
            
            if !commonConcepts.isEmpty {
                // 找到匹配的模式
                for pattern in l2Entry.patterns {
                    let match = PatternMatch(
                        pattern: pattern,
                        matchScore: Double(commonConcepts.count) / Double(entry.keywords.count),
                        applicableContexts: pattern.contextConstraints,
                        source: l2Entry.id
                    )
                    matches.append(match)
                }
            }
        }
        
        return matches
            .sorted { $0.matchScore > $1.matchScore }
            .prefix(limit)
            .map { $0 }
    }
    
    // MARK: - Retrieval Methods
    
    private func retrieveL2Cognition(
        _ state: MemorySystemState,
        _ prefs: ContextPreferences
    ) async throws -> L2CognitionContext {
        
        var concepts: [Concept] = []
        var beliefs: [Belief] = []
        var insights: [ActionableInsight] = []
        
        for entry in l2Store.entries {
            concepts.append(contentsOf: entry.concepts)
            beliefs.append(contentsOf: entry.beliefs)
            insights.append(contentsOf: entry.actionableInsights)
        }
        
        // 去重和筛选
        concepts = Array(Set(concepts.map(\.id)).compactMap { id in
            concepts.first { $0.id == id }
        }.sorted { $0.confidence > $1.confidence }
        .prefix(prefs.maxConcepts))
        
        beliefs = beliefs
            .filter { $0.confidence >= prefs.minConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(prefs.maxBeliefs)
            .map { $0 }
        
        insights = insights
            .prefix(prefs.maxInsights)
            .map { $0 }
        
        return L2CognitionContext(
            concepts: concepts,
            beliefs: beliefs,
            insights: insights,
            relations: []  // 简化：不返回所有关系
        )
    }
    
    private func retrieveL1Facts(
        _ state: MemorySystemState,
        _ prefs: ContextPreferences
    ) async throws -> [RelevantFact] {
        
        let entries = try await l1Store.queryByImportance(
            minImportance: prefs.minImportance,
            planId: state.planId
        )
        
        return entries
            .flatMap { entry -> [RelevantFact] in
                entry.keyFacts.compactMap { fact in
                    guard fact.confidence >= prefs.minConfidence else { return nil }
                    
                    return RelevantFact(
                        statement: "\(fact.subject) \(fact.predicate) \(fact.object)",
                        confidence: fact.confidence,
                        source: entry.id,
                        timestamp: entry.timestamp
                    )
                }
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(prefs.maxFacts)
            .map { $0 }
    }
    
    private func retrieveL0Recent(
        _ state: MemorySystemState,
        _ prefs: ContextPreferences
    ) async throws -> [RecentActivity] {
        
        let cutoff = Date().addingTimeInterval(-prefs.recentTimeWindow)
        var activities: [RecentActivity] = []
        
        for (planId, entries) in l0Store.entries {
            guard state.planId == nil || planId == state.planId else { continue }
            
            for entry in entries.filter({ $0.timestamp >= cutoff }) {
                let activity = RecentActivity(
                    description: entry.summary.truncated(to: 100),
                    timestamp: entry.timestamp,
                    planId: entry.id.planId,
                    type: entry.type
                )
                activities.append(activity)
            }
        }
        
        return activities
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(prefs.maxRecentItems)
            .map { $0 }
    }
    
    private func retrieveSemantic(
        _ state: MemorySystemState,
        _ prefs: ContextPreferences
    ) async throws -> [SemanticMatch] {
        
        guard let vectorStore = vectorStore else {
            return []
        }
        
        // Mock：假设有查询向量
        // 实际应基于当前输入生成嵌入
        let mockQuery = EmbeddingVector(
            model: "mock",
            dimensions: 1536,
            vector: (0..<1536).map { _ in Float.random(in: -1...1) },
            normalized: true
        )
        
        let results = try await vectorStore.search(
            query: mockQuery,
            limit: prefs.maxSemanticResults
        )
        
        return results.map { result in
            SemanticMatch(
                entryId: result.id,
                similarity: result.score,
                layer: result.metadata.layer
            )
        }
    }
    
    private func retrieveGraph(
        _ state: MemorySystemState,
        _ prefs: ContextPreferences
    ) async throws -> GraphContext {
        
        guard let graphStore = graphStore else {
            return GraphContext(entities: [], paths: [])
        }
        
        // Mock：简化实现
        return GraphContext(
            entities: [],
            paths: []
        )
    }
    
    // MARK: - Helper
    
    private func estimateTokens(
        _ cognition: L2CognitionContext,
        _ facts: [RelevantFact],
        _ recent: [RecentActivity],
        _ semantic: [SemanticMatch],
        _ graph: GraphContext
    ) -> Int {
        // 简单估算
        var count = 0
        
        count += cognition.concepts.count * 10
        count += cognition.beliefs.count * 20
        count += cognition.insights.count * 30
        count += facts.count * 15
        count += recent.count * 10
        count += semantic.count * 5
        count += graph.entities.count * 8
        
        return count
    }
}

// MARK: - Context Types

struct MemorySystemState {
    let planId: String?
    let taskId: String?
    let agentId: String?
    let recentKeywords: [String]
    let currentIntent: String?
}

struct ContextPreferences {
    var maxConcepts: Int = 10
    var maxBeliefs: Int = 5
    var maxInsights: Int = 3
    var maxFacts: Int = 10
    var maxRecentItems: Int = 5
    var maxSemanticResults: Int = 5
    var minConfidence: Double = 0.7
    var minImportance: ImportanceScore = .normal
    var recentTimeWindow: TimeInterval = 3600  // 1 hour
    
    static let `default` = ContextPreferences()
    static let minimal = ContextPreferences(
        maxConcepts: 5,
        maxBeliefs: 2,
        maxInsights: 1,
        maxFacts: 5,
        maxRecentItems: 3,
        minConfidence: 0.8
    )
}

struct RetrievedContext {
    let cognition: L2CognitionContext
    let facts: [RelevantFact]
    let recent: [RecentActivity]
    let semantic: [SemanticMatch]
    let graph: GraphContext
    let timestamp: Date
    let tokenEstimate: Int
}

struct L2CognitionContext {
    let concepts: [Concept]
    let beliefs: [Belief]
    let insights: [ActionableInsight]
    let relations: [Relation]
}

struct RelevantFact {
    let statement: String
    let confidence: Double
    let source: MemoryID
    let timestamp: Date
}

struct RecentActivity {
    let description: String
    let timestamp: Date
    let planId: String
    let type: MemoryType
}

struct SemanticMatch {
    let entryId: MemoryID
    let similarity: Float
    let layer: MemoryLayer
}

struct GraphContext {
    let entities: [GraphEntity]
    let paths: [RelationPath]
}

struct GraphEntity {
    let id: String
    let name: String
    let type: String
}

struct RelationPath {
    let source: String
    let target: String
    let path: [String]
    let confidence: Double
}

struct PatternMatch {
    let pattern: Pattern
    let matchScore: Double
    let applicableContexts: [String]
    let source: MemoryID
}

// MARK: - String Extension

extension String {
    func truncated(to length: Int) -> String {
        if self.count > length {
            return String(self.prefix(length)) + "..."
        }
        return self
    }
}
