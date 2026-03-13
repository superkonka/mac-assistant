//
//  InMemoryStores.swift
//  MacAssistant
//
//  In-Memory Implementation for Testing and Development
//

import Foundation

// MARK: - In-Memory L0 Store

actor InMemoryRawStore: RawMemoryStore {
    private var entries: [MemoryID: RawMemoryEntry] = [:]
    private var planIndex: [String: [MemoryID]] = [:]
    private var subscribers: [UUID: AsyncStream<[RawMemoryEntry]>.Continuation] = [:]
    
    func append(_ entry: RawMemoryEntry) async throws {
        entries[entry.id] = entry
        planIndex[entry.planId, default: []].append(entry.id)
        
        // 通知订阅者
        for (_, continuation) in subscribers {
            continuation.yield([entry])
        }
    }
    
    func appendBatch(_ entries: [RawMemoryEntry]) async throws {
        for entry in entries {
            try await self.append(entry)
        }
    }
    
    func get(id: MemoryID) async throws -> RawMemoryEntry? {
        entries[id]
    }
    
    func getExecutionTrace(planId: String, taskId: String?) async throws -> [RawMemoryEntry] {
        let ids = planIndex[planId] ?? []
        return ids.compactMap { entries[$0] }
            .filter { entry in
                if let taskId = taskId {
                    return entry.taskId == taskId
                }
                return true
            }
            .sorted { $0.timestamp < $1.timestamp }
    }
    
    func query(
        planId: String?,
        timeRange: ClosedRange<Date>,
        types: [RawMemoryEntry.RawEntryType]?
    ) async throws -> [RawMemoryEntry] {
        var result = entries.values.filter { entry in
            timeRange.contains(entry.timestamp)
        }
        
        if let planId = planId {
            result = result.filter { $0.planId == planId }
        }
        
        if let types = types {
            result = result.filter { types.contains($0.type) }
        }
        
        return result.sorted { $0.timestamp < $1.timestamp }
    }
    
    func getPlanEntries(planId: String) async throws -> [RawMemoryEntry] {
        let ids = planIndex[planId] ?? []
        return ids.compactMap { entries[$0] }
            .sorted { $0.timestamp < $1.timestamp }
    }
    
    func subscribe(batchSize: Int) -> AsyncStream<[RawMemoryEntry]> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeSubscriber(id: id)
                }
            }
        }
    }
    
    private func removeSubscriber(id: UUID) {
        subscribers.removeValue(forKey: id)
    }
    
    func purgeEntries(olderThan: Date) async throws {
        let toRemove = entries.filter { $0.value.timestamp < olderThan }.keys
        for id in toRemove {
            entries.removeValue(forKey: id)
            planIndex[id.planId]?.removeAll { $0 == id }
        }
    }
    
    func healthCheck() async -> Bool {
        true
    }
    
    // MARK: - Debug Helpers
    
    func entryCount() async -> Int {
        entries.count
    }
    
    func clearAll() async {
        entries.removeAll()
        planIndex.removeAll()
    }
}

// MARK: - In-Memory L1 Store

actor InMemoryFilteredStore: FilteredMemoryStore {
    private var entries: [MemoryID: FilteredMemoryEntry] = [:]
    private var keywordIndex: [String: [MemoryID]] = [:]
    private var entityIndex: [String: [MemoryID]] = [:]
    private var categoryIndex: [MemoryCategory: [MemoryID]] = [:]
    
    func store(_ entry: FilteredMemoryEntry) async throws {
        entries[entry.id] = entry
        
        // 更新索引
        for keyword in entry.keywords {
            keywordIndex[keyword, default: []].append(entry.id)
        }
        
        for entity in entry.entities {
            let key = "\(entity.type.rawValue):\(entity.name)"
            entityIndex[key, default: []].append(entry.id)
        }
        
        categoryIndex[entry.category, default: []].append(entry.id)
    }
    
    func storeBatch(_ entries: [FilteredMemoryEntry]) async throws {
        for entry in entries {
            try await self.store(entry)
        }
    }
    
    func get(id: MemoryID) async throws -> FilteredMemoryEntry? {
        entries[id]
    }
    
    func batchGet(ids: [MemoryID]) async throws -> [FilteredMemoryEntry] {
        ids.compactMap { entries[$0] }
    }
    
    func queryByImportance(
        minImportance: ImportanceScore,
        planId: String?
    ) async throws -> [FilteredMemoryEntry] {
        var result = entries.values.filter { $0.importance >= minImportance }
        if let planId = planId {
            result = result.filter { $0.id.planId == planId }
        }
        return Array(result)
    }
    
    func queryByKeywords(
        keywords: [String],
        planId: String?
    ) async throws -> [FilteredMemoryEntry] {
        var candidateIds: Set<MemoryID> = []
        
        for keyword in keywords {
            if let ids = keywordIndex[keyword] {
                if candidateIds.isEmpty {
                    candidateIds = Set(ids)
                } else {
                    candidateIds.formIntersection(ids)
                }
            }
        }
        
        var result = candidateIds.compactMap { entries[$0] }
        if let planId = planId {
            result = result.filter { $0.id.planId == planId }
        }
        
        return result
    }
    
    func queryByEntity(
        entityName: String,
        entityType: EntityReference.EntityType?
    ) async throws -> [FilteredMemoryEntry] {
        let key = entityType.map { "\($0.rawValue):\(entityName)" } ?? entityName
        let ids = entityIndex[key] ?? []
        return ids.compactMap { entries[$0] }
    }
    
    func queryByCategory(
        category: MemoryCategory,
        timeRange: ClosedRange<Date>?
    ) async throws -> [FilteredMemoryEntry] {
        let ids = categoryIndex[category] ?? []
        var result = ids.compactMap { entries[$0] }
        
        if let timeRange = timeRange {
            result = result.filter { timeRange.contains($0.timestamp) }
        }
        
        return result
    }
    
    func getSourcesForL2(l2Id: MemoryID) async throws -> [FilteredMemoryEntry] {
        // 查询 sourceIds 匹配的所有 L1 条目
        entries.values.filter { entry in
            entry.id.childID(in: .distilled) == l2Id
        }
    }
    
    func purgeEntries(olderThan: Date) async throws {
        let toRemove = entries.filter { $0.value.timestamp < olderThan }
        for (id, _) in toRemove {
            entries.removeValue(forKey: id)
        }
        // 清理索引...
    }
}

// MARK: - In-Memory L2 Store

actor InMemoryDistilledStore: DistilledMemoryStore {
    private var entries: [MemoryID: DistilledMemoryEntry] = [:]
    private var conceptIndex: [String: [MemoryID]] = [:]
    private var patternIndex: [String: [MemoryID]] = [:]
    
    func store(_ entry: DistilledMemoryEntry) async throws {
        entries[entry.id] = entry
        
        // 索引概念
        for concept in entry.concepts {
            conceptIndex[concept.name, default: []].append(entry.id)
            for alias in concept.aliases {
                conceptIndex[alias, default: []].append(entry.id)
            }
        }
        
        // 索引模式
        for pattern in entry.patterns {
            patternIndex[pattern.name, default: []].append(entry.id)
        }
    }
    
    func update(id: MemoryID, with entry: DistilledMemoryEntry) async throws {
        entries[id] = entry
    }
    
    func get(id: MemoryID) async throws -> DistilledMemoryEntry? {
        entries[id]
    }
    
    func semanticSearch(
        query: String,
        embedding: EmbeddingVector,
        topK: Int,
        filters: RetrievalFilters?
    ) async throws -> [DistilledMemoryEntry] {
        // 简化实现：基于关键词匹配（实际应使用向量相似度）
        let queryKeywords = query.lowercased().split(separator: " ").map(String.init)
        
        var scores: [MemoryID: Double] = [:]
        
        for entry in entries.values {
            var score: Double = 0
            
            // 概念匹配
            for concept in entry.concepts {
                if queryKeywords.contains(where: { 
                    concept.name.lowercased().contains($0) || 
                    $0.contains(concept.name.lowercased())
                }) {
                    score += Double(concept.frequency) * concept.confidence
                }
            }
            
            // 信念匹配
            for belief in entry.beliefs {
                if queryKeywords.contains(where: { 
                    belief.statement.lowercased().contains($0)
                }) {
                    score += belief.confidence
                }
            }
            
            if score > 0 {
                scores[entry.id] = score
            }
        }
        
        // 排序取 TopK
        let sortedIds = scores.sorted { $0.value > $1.value }.prefix(topK).map { $0.key }
        return sortedIds.compactMap { entries[$0] }
    }
    
    func queryByConcept(conceptName: String) async throws -> [DistilledMemoryEntry] {
        let ids = conceptIndex[conceptName] ?? []
        return ids.compactMap { entries[$0] }
    }
    
    func queryByRelation(
        conceptId: String,
        relationType: RelationType?
    ) async throws -> [DistilledMemoryEntry] {
        // 简化实现
        entries.values.filter { entry in
            entry.relations.contains { relation in
                relation.sourceConceptId == conceptId || relation.targetConceptId == conceptId
            }
        }
    }
    
    func queryByPattern(patternType: String) async throws -> [DistilledMemoryEntry] {
        let ids = patternIndex[patternType] ?? []
        return ids.compactMap { entries[$0] }
    }
    
    func getHotEntries(topics: [String], limit: Int) async throws -> [DistilledMemoryEntry] {
        // 基于概念频率计算热度
        let scored = entries.values.map { entry -> (DistilledMemoryEntry, Double) in
            var score: Double = 0
            for topic in topics {
                if let concept = entry.concepts.first(where: { $0.name == topic }) {
                    score += Double(concept.frequency)
                }
            }
            return (entry, score)
        }
        
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }
    
    func syncToKnowledgeGraph(_ entry: DistilledMemoryEntry) async throws {
        // Mock 实现
        LogInfo("[InMemoryDistilledStore] Would sync entry \(entry.id) to knowledge graph")
    }
}

// MARK: - Placeholder Implementations for Real Backends

actor ClickHouseRawStore: RawMemoryStore {
    func append(_ entry: RawMemoryEntry) async throws {
        fatalError("ClickHouse not implemented. Use InMemoryRawStore for now.")
    }
    func appendBatch(_ entries: [RawMemoryEntry]) async throws {}
    func get(id: MemoryID) async throws -> RawMemoryEntry? { nil }
    func getExecutionTrace(planId: String, taskId: String?) async throws -> [RawMemoryEntry] { [] }
    func query(planId: String?, timeRange: ClosedRange<Date>, types: [RawMemoryEntry.RawEntryType]?) async throws -> [RawMemoryEntry] { [] }
    func getPlanEntries(planId: String) async throws -> [RawMemoryEntry] { [] }
    func subscribe(batchSize: Int) -> AsyncStream<[RawMemoryEntry]> { AsyncStream { _ in } }
    func purgeEntries(olderThan: Date) async throws {}
    func healthCheck() async -> Bool { false }
}

actor PostgreSQLFilteredStore: FilteredMemoryStore {
    func store(_ entry: FilteredMemoryEntry) async throws {
        fatalError("PostgreSQL not implemented. Use InMemoryFilteredStore for now.")
    }
    func storeBatch(_ entries: [FilteredMemoryEntry]) async throws {}
    func get(id: MemoryID) async throws -> FilteredMemoryEntry? { nil }
    func batchGet(ids: [MemoryID]) async throws -> [FilteredMemoryEntry] { [] }
    func queryByImportance(minImportance: ImportanceScore, planId: String?) async throws -> [FilteredMemoryEntry] { [] }
    func queryByKeywords(keywords: [String], planId: String?) async throws -> [FilteredMemoryEntry] { [] }
    func queryByEntity(entityName: String, entityType: EntityReference.EntityType?) async throws -> [FilteredMemoryEntry] { [] }
    func queryByCategory(category: MemoryCategory, timeRange: ClosedRange<Date>?) async throws -> [FilteredMemoryEntry] { [] }
    func getSourcesForL2(l2Id: MemoryID) async throws -> [FilteredMemoryEntry] { [] }
    func purgeEntries(olderThan: Date) async throws {}
}

actor PineconeDistilledStore: DistilledMemoryStore {
    func store(_ entry: DistilledMemoryEntry) async throws {
        fatalError("Pinecone not implemented. Use InMemoryDistilledStore for now.")
    }
    func update(id: MemoryID, with entry: DistilledMemoryEntry) async throws {}
    func get(id: MemoryID) async throws -> DistilledMemoryEntry? { nil }
    func semanticSearch(query: String, embedding: EmbeddingVector, topK: Int, filters: RetrievalFilters?) async throws -> [DistilledMemoryEntry] { [] }
    func queryByConcept(conceptName: String) async throws -> [DistilledMemoryEntry] { [] }
    func queryByRelation(conceptId: String, relationType: RelationType?) async throws -> [DistilledMemoryEntry] { [] }
    func queryByPattern(patternType: String) async throws -> [DistilledMemoryEntry] { [] }
    func getHotEntries(topics: [String], limit: Int) async throws -> [DistilledMemoryEntry] { [] }
    func syncToKnowledgeGraph(_ entry: DistilledMemoryEntry) async throws {}
}

actor MilvusDistilledStore: DistilledMemoryStore {
    func store(_ entry: DistilledMemoryEntry) async throws {
        fatalError("Milvus not implemented. Use InMemoryDistilledStore for now.")
    }
    func update(id: MemoryID, with entry: DistilledMemoryEntry) async throws {}
    func get(id: MemoryID) async throws -> DistilledMemoryEntry? { nil }
    func semanticSearch(query: String, embedding: EmbeddingVector, topK: Int, filters: RetrievalFilters?) async throws -> [DistilledMemoryEntry] { [] }
    func queryByConcept(conceptName: String) async throws -> [DistilledMemoryEntry] { [] }
    func queryByRelation(conceptId: String, relationType: RelationType?) async throws -> [DistilledMemoryEntry] { [] }
    func queryByPattern(patternType: String) async throws -> [DistilledMemoryEntry] { [] }
    func getHotEntries(topics: [String], limit: Int) async throws -> [DistilledMemoryEntry] { [] }
    func syncToKnowledgeGraph(_ entry: DistilledMemoryEntry) async throws {}
}
