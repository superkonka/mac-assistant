//
//  L2Distiller.swift
//  MacAssistant
//
//  L2: Filtered to Distilled Cognition (Phase 3)
//

import Foundation

/// L2 认知蒸馏引擎：从 L1 提取概念、关系、模式
actor L2DistillationEngine {
    
    // MARK: - Components
    
    private let conceptExtractor: ConceptExtractor
    private let relationBuilder: RelationGraphBuilder
    private let patternRecognizer: PatternRecognizer
    private let embeddingGenerator: EmbeddingGenerator
    
    init() {
        self.conceptExtractor = ConceptExtractor()
        self.relationBuilder = RelationGraphBuilder()
        self.patternRecognizer = PatternRecognizer()
        self.embeddingGenerator = EmbeddingGenerator()
    }
    
    // MARK: - Main API
    
    /// 从 L1 条目聚合蒸馏 L2 认知
    func distill(
        from entries: [FilteredMemoryEntry],
        planId: String,
        segmentId: String
    ) async throws -> DistilledMemoryEntry {
        
        LogInfo("[L2Distiller] Distilling \(entries.count) L1 entries into L2 cognition")
        
        // 1. 概念提取与消歧
        let concepts = await conceptExtractor.extract(from: entries)
        
        // 2. 构建关系图谱
        let relations = await relationBuilder.build(
            concepts: concepts,
            from: entries
        )
        
        // 3. 模式识别
        let patterns = await patternRecognizer.recognize(in: entries)
        
        // 4. 形成信念
        let beliefs = await formBeliefs(
            from: entries,
            concepts: concepts,
            relations: relations
        )
        
        // 5. 生成可执行洞察
        let insights = await generateActionableInsights(
            patterns: patterns,
            beliefs: beliefs
        )
        
        // 6. 生成向量嵌入
        let embedding = await embeddingGenerator.generate(
            for: concepts,
            relations: relations,
            summary: generateCognitiveSummary(concepts, relations)
        )
        
        // 7. 同步到知识图谱
        let graphNodeId = await syncToKnowledgeGraph(
            concepts: concepts,
            relations: relations,
            source: entries.map(\.id)
        )
        
        return DistilledMemoryEntry(
            id: MemoryID(
                planId: planId,
                layer: .distilled,
                segmentId: segmentId,
                entryId: "aggregate-\(UUID().uuidString.prefix(8))"
            ),
            sourceIds: entries.map(\.id),
            timeRange: (entries.map(\.timestamp).min()!)...(entries.map(\.timestamp).max()!),
            updateCount: 1,
            concepts: concepts,
            relations: relations,
            patterns: patterns,
            beliefs: beliefs,
            embedding: embedding,
            actionableInsights: insights,
            graphNodeId: graphNodeId
        )
    }
    
    /// 增量增强现有 L2 条目
    func enhance(
        existing: DistilledMemoryEntry,
        with newEntries: [FilteredMemoryEntry]
    ) async throws -> DistilledMemoryEntry {
        
        // 合并条目
        let allEntries = newEntries  // 简化：实际应合并历史
        
        // 重新蒸馏
        var updated = try await distill(
            from: allEntries,
            planId: existing.id.planId,
            segmentId: existing.id.segmentId
        )
        
        // 保留原有 ID，增加更新计数
        updated = DistilledMemoryEntry(
            id: existing.id,
            sourceIds: updated.sourceIds,
            timeRange: updated.timeRange,
            updateCount: existing.updateCount + 1,
            concepts: updated.concepts,
            relations: updated.relations,
            patterns: updated.patterns,
            beliefs: updated.beliefs,
            embedding: updated.embedding,
            actionableInsights: updated.actionableInsights,
            graphNodeId: updated.graphNodeId
        )
        
        return updated
    }
    
    // MARK: - Private Methods
    
    private func formBeliefs(
        from entries: [FilteredMemoryEntry],
        concepts: [Concept],
        relations: [Relation]
    ) async -> [Belief] {
        var beliefs: [Belief] = []
        
        // 从高置信度的事实中提取信念
        for entry in entries {
            for fact in entry.keyFacts where fact.confidence > 0.8 {
                let belief = Belief(
                    id: "belief-\(UUID().uuidString.prefix(8))",
                    statement: "\(fact.subject) \(fact.predicate) \(fact.object)",
                    confidence: fact.confidence,
                    supportingEvidence: [entry.id],
                    contradictingEvidence: [],
                    lastVerified: entry.timestamp,
                    verificationCount: 1
                )
                beliefs.append(belief)
            }
        }
        
        // 从关系中提取信念
        for relation in relations where relation.strength > 0.7 {
            let belief = Belief(
                id: "belief-rel-\(UUID().uuidString.prefix(8))",
                statement: "\(relation.sourceConceptId) \(relation.type.rawValue) \(relation.targetConceptId)",
                confidence: relation.strength,
                supportingEvidence: relation.evidence.compactMap { MemoryID($0) },
                contradictingEvidence: [],
                lastVerified: Date(),
                verificationCount: 1
            )
            beliefs.append(belief)
        }
        
        // 去重（基于 statement）
        var seenStatements: Set<String> = []
        beliefs = beliefs.filter { belief in
            if seenStatements.contains(belief.statement) {
                return false
            }
            seenStatements.insert(belief.statement)
            return true
        }
        
        return beliefs
    }
    
    private func generateActionableInsights(
        patterns: [Pattern],
        beliefs: [Belief]
    ) async -> [ActionableInsight] {
        
        patterns.compactMap { pattern in
            guard pattern.successRate > 0.5 else { return nil }
            
            return ActionableInsight(
                id: "insight-\(UUID().uuidString.prefix(8))",
                insight: pattern.patternType,
                applicability: pattern.contextConstraints,
                implementation: pattern.actionSequence.joined(separator: " → "),
                riskAssessment: "Success rate: \(Int(pattern.successRate * 100))%",
                expectedOutcome: nil,
                sourcePatterns: [pattern.id]
            )
        }
    }
    
    private func generateCognitiveSummary(
        _ concepts: [Concept],
        _ relations: [Relation]
    ) -> String {
        var parts: [String] = []
        
        parts.append("核心概念: \(concepts.prefix(3).map(\.name).joined(separator: ", "))")
        parts.append("关系数量: \(relations.count)")
        
        return parts.joined(separator: "; ")
    }
    
    private func syncToKnowledgeGraph(
        concepts: [Concept],
        relations: [Relation],
        source: [MemoryID]
    ) async -> String {
        // Mock 实现
        let nodeId = "graph-\(UUID().uuidString.prefix(8))"
        LogInfo("[L2Distiller] Synced \(concepts.count) concepts, \(relations.count) relations to knowledge graph: \(nodeId)")
        return nodeId
    }
}

// MARK: - Components

actor ConceptExtractor {
    func extract(from entries: [FilteredMemoryEntry]) async -> [Concept] {
        var conceptMap: [String: Concept] = [:]
        
        // 从实体提取概念
        for entry in entries {
            for entity in entry.entities {
                let key = "\(entity.type.rawValue).\(entity.name)"
                
                if var existing = conceptMap[key] {
                    // 更新频率
                    existing.frequency += entity.mentions
                    conceptMap[key] = existing
                } else {
                    // 创建新概念
                    let concept = Concept(
                        id: "concept-\(UUID().uuidString.prefix(8))",
                        name: entity.name,
                        type: mapEntityType(entity.type),
                        definition: "Extracted from \(entry.id)",
                        aliases: [],
                        frequency: entity.mentions,
                        confidence: 0.8
                    )
                    conceptMap[key] = concept
                }
            }
        }
        
        // 从关键词提取概念（简单启发式）
        for entry in entries {
            for keyword in entry.keywords.prefix(5) {
                let key = "keyword.\(keyword)"
                if conceptMap[key] == nil {
                    let concept = Concept(
                        id: "concept-\(UUID().uuidString.prefix(8))",
                        name: keyword,
                        type: .abstraction,
                        definition: "Keyword from L1",
                        aliases: [],
                        frequency: 1,
                        confidence: 0.6
                    )
                    conceptMap[key] = concept
                }
            }
        }
        
        return Array(conceptMap.values)
    }
    
    func deduplicate(_ concepts: [Concept]) async -> [Concept] {
        // 基于名称相似度去重
        var unique: [Concept] = []
        var seenNames: Set<String> = []
        
        for concept in concepts.sorted(by: { $0.confidence > $1.confidence }) {
            let normalizedName = concept.name.lowercased()
            if !seenNames.contains(normalizedName) {
                seenNames.insert(normalizedName)
                unique.append(concept)
            }
        }
        
        return unique
    }
    
    private func mapEntityType(_ type: EntityReference.EntityType) -> Concept.ConceptType {
        switch type {
        case .person: return .entity
        case .project: return .entity
        case .technology: return .abstraction
        case .tool: return .entity
        case .concept: return .abstraction
        case .file: return .entity
        case .api: return .entity
        }
    }
}

actor RelationGraphBuilder {
    func build(
        concepts: [Concept],
        from entries: [FilteredMemoryEntry]
    ) async -> [Relation] {
        var relations: [Relation] = []
        let conceptNames = Set(concepts.map(\.name))
        
        // 从共现构建关系
        for entry in entries {
            let entryConcepts = entry.entities
                .filter { conceptNames.contains($0.name) }
                .map(\.name)
            
            // 为共现的概念创建关系
            for i in 0..<entryConcepts.count {
                for j in (i+1)..<entryConcepts.count {
                    if let sourceConcept = concepts.first(where: { $0.name == entryConcepts[i] }),
                       let targetConcept = concepts.first(where: { $0.name == entryConcepts[j] }) {
                        
                        let relation = Relation(
                            id: "rel-\(UUID().uuidString.prefix(8))",
                            sourceConceptId: sourceConcept.id,
                            targetConceptId: targetConcept.id,
                            type: .similarTo,  // 共现 = 相似
                            strength: 0.6,
                            evidence: [entry.id.description]
                        )
                        relations.append(relation)
                    }
                }
            }
        }
        
        return relations
    }
}

actor PatternRecognizer {
    func recognize(in entries: [FilteredMemoryEntry]) async -> [Pattern] {
        var patterns: [Pattern] = []
        
        // 识别成功模式
        let successEntries = entries.filter { $0.outcomes.contains { $0.success } }
        if successEntries.count >= 3 {
            let pattern = Pattern(
                id: "pattern-success-\(UUID().uuidString.prefix(8))",
                name: "Success Pattern",
                description: "Recurring successful execution",
                triggerConditions: ["Input matches: \(successEntries.first?.keywords.joined(separator: ", ") ?? "")"],
                actionSequence: ["Execute", "Verify", "Store"],
                successRate: Double(successEntries.count) / Double(entries.count),
                contextConstraints: ["Similar context"],
                sourceEvidence: successEntries.map(\.id.description)
            )
            patterns.append(pattern)
        }
        
        // 识别错误恢复模式
        let errorEntries = entries.filter { $0.category == .errorResolution }
        if errorEntries.count >= 2 {
            let pattern = Pattern(
                id: "pattern-recovery-\(UUID().uuidString.prefix(8))",
                name: "Error Recovery Pattern",
                description: "Common error resolution steps",
                triggerConditions: ["Error occurs"],
                actionSequence: ["Identify", "Recover", "Verify"],
                successRate: 0.8,
                contextConstraints: ["Error context"],
                sourceEvidence: errorEntries.map(\.id.description)
            )
            patterns.append(pattern)
        }
        
        return patterns
    }
}

actor EmbeddingGenerator {
    func generate(
        for concepts: [Concept],
        relations: [Relation],
        summary: String
    ) async -> EmbeddingVector {
        // Mock 实现
        // 实际应调用嵌入服务（OpenAI、本地模型等）
        
        let text = summary + " " + concepts.map(\.definition).joined(separator: " ")
        
        // 生成随机向量作为占位（实际应为真实嵌入）
        let dimensions = 1536
        let vector = (0..<dimensions).map { _ in Float.random(in: -1...1) }
        
        return EmbeddingVector(
            model: "mock-embedding",
            dimensions: dimensions,
            vector: vector,
            normalized: false
        )
    }
}

// MARK: - L2 Worker

actor L2DistillationWorker {
    private let engine: L2DistillationEngine
    private let l1Store: FilteredMemoryStore
    private let l2Store: DistilledMemoryStore
    
    init(
        l1Store: FilteredMemoryStore,
        l2Store: DistilledMemoryStore
    ) {
        self.engine = L2DistillationEngine()
        self.l1Store = l1Store
        self.l2Store = l2Store
    }
    
    /// 从 L1 批量生成 L2
    func processBatch(planId: String) async throws -> DistilledMemoryEntry? {
        // 获取该 Plan 的 L1 条目
        let l1Entries = try await l1Store.queryByImportance(
            minImportance: .significant,
            planId: planId
        )
        
        guard l1Entries.count >= 3 else {
            LogInfo("[L2Worker] Not enough L1 entries (need 3+, got \(l1Entries.count))")
            return nil
        }
        
        // 蒸馏 L2
        let l2Entry = try await engine.distill(
            from: l1Entries,
            planId: planId,
            segmentId: "batch-\(Date().timeIntervalSince1970)"
        )
        
        // 存储
        try await l2Store.store(l2Entry)
        
        LogInfo("[L2Worker] Created L2 entry with \(l2Entry.concepts.count) concepts, \(l2Entry.relations.count) relations")
        
        return l2Entry
    }
}
