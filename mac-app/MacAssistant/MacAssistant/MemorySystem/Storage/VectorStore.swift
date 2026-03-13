//
//  VectorStore.swift
//  MacAssistant
//
//  L2 Vector storage for semantic retrieval (Phase 3)
//

import Foundation

/// 向量存储协议
protocol VectorStore {
    func store(
        id: MemoryID,
        vector: EmbeddingVector,
        metadata: VectorMetadata
    ) async throws
    
    func search(
        query: EmbeddingVector,
        limit: Int
    ) async throws -> [VectorSearchResult]
    
    func delete(id: MemoryID) async throws
}

/// 向量元数据
struct VectorMetadata: Codable {
    let planId: String
    let segmentId: String
    let layer: MemoryLayer
    let timestamp: Date
    let tags: [String]
    
    var dictionary: [String: Any] {
        [
            "planId": planId,
            "segmentId": segmentId,
            "layer": layer.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "tags": tags
        ]
    }
}

/// 搜索结果
struct VectorSearchResult {
    let id: MemoryID
    let score: Float
    let metadata: VectorMetadata
}

// MARK: - In-Memory Implementation

actor InMemoryVectorStore: VectorStore {
    
    struct VectorEntry {
        let id: MemoryID
        let vector: [Float]
        let metadata: VectorMetadata
    }
    
    private var entries: [VectorEntry] = []
    
    func store(
        id: MemoryID,
        vector: EmbeddingVector,
        metadata: VectorMetadata
    ) async throws {
        let entry = VectorEntry(
            id: id,
            vector: vector.vector,
            metadata: metadata
        )
        entries.append(entry)
        LogInfo("[VectorStore] Stored vector for \(id) (dims: \(vector.dimensions))")
    }
    
    func search(
        query: EmbeddingVector,
        limit: Int
    ) async throws -> [VectorSearchResult] {
        let queryVector = query.vector
        
        // 计算余弦相似度
        let results = entries.map { entry in
            let score = cosineSimilarity(queryVector, entry.vector)
            return VectorSearchResult(
                id: entry.id,
                score: score,
                metadata: entry.metadata
            )
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        
        return Array(results)
    }
    
    func delete(id: MemoryID) async throws {
        entries.removeAll { $0.id == id }
    }
    
    // MARK: - Helper
    
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        
        guard normA > 0 && normB > 0 else { return 0 }
        return dot / (sqrt(normA) * sqrt(normB))
    }
}

// MARK: - Knowledge Graph Store

protocol KnowledgeGraphStore {
    func createNode(
        type: String,
        properties: [String: Any]
    ) async throws -> String
    
    func createRelation(
        from: String,
        to: String,
        type: String,
        properties: [String: Any]
    ) async throws
    
    func query(
        conceptName: String
    ) async throws -> [GraphQueryResult]
}

struct GraphQueryResult {
    let concept: Concept
    let relatedConcepts: [Concept]
    let relations: [Relation]
}

actor InMemoryKnowledgeGraphStore: KnowledgeGraphStore {
    
    struct GraphNode {
        let id: String
        let type: String
        let properties: [String: Any]
    }
    
    struct GraphEdge {
        let from: String
        let to: String
        let type: String
        let properties: [String: Any]
    }
    
    private var nodes: [String: GraphNode] = [:]
    private var edges: [GraphEdge] = []
    private var conceptMap: [String: String] = [:]  // name -> nodeId
    
    func createNode(
        type: String,
        properties: [String: Any]
    ) async throws -> String {
        let id = "node-\(UUID().uuidString.prefix(8))"
        let node = GraphNode(id: id, type: type, properties: properties)
        nodes[id] = node
        
        if let name = properties["name"] as? String {
            conceptMap[name] = id
        }
        
        return id
    }
    
    func createRelation(
        from: String,
        to: String,
        type: String,
        properties: [String: Any]
    ) async throws {
        let edge = GraphEdge(from: from, to: to, type: type, properties: properties)
        edges.append(edge)
    }
    
    func query(conceptName: String) async throws -> [GraphQueryResult] {
        guard let nodeId = conceptMap[conceptName],
              let node = nodes[nodeId] else {
            return []
        }
        
        // Mock 返回
        let concept = Concept(
            id: nodeId,
            name: conceptName,
            type: .abstraction,
            definition: "From knowledge graph",
            aliases: [],
            frequency: 1,
            confidence: 0.8
        )
        
        return [GraphQueryResult(
            concept: concept,
            relatedConcepts: [],
            relations: []
        )]
    }
}

// MARK: - HNSW Approximate Nearest Neighbors

/// 简化版 HNSW 索引（生产环境应使用专业库）
actor HNSWVectorIndex: VectorStore {
    
    struct HNSWNode {
        let id: MemoryID
        let vector: [Float]
        let level: Int
        var neighbors: [[String]]  // [level][neighbor_id]
    }
    
    private var nodes: [String: HNSWNode] = [:]
    private let maxLevel: Int
    private let m: Int  // 每个节点的最大连接数
    private let efConstruction: Int
    
    init(maxLevel: Int = 16, m: Int = 16, efConstruction: Int = 200) {
        self.maxLevel = maxLevel
        self.m = m
        self.efConstruction = efConstruction
    }
    
    func store(
        id: MemoryID,
        vector: EmbeddingVector,
        metadata: VectorMetadata
    ) async throws {
        // 简化：直接存储，不构建复杂图结构
        // 生产环境应实现完整 HNSW 算法
        
        let nodeId = id.description
        let level = randomLevel()
        let node = HNSWNode(
            id: id,
            vector: vector.vector,
            level: level,
            neighbors: Array(repeating: [], count: level + 1)
        )
        nodes[nodeId] = node
    }
    
    func search(
        query: EmbeddingVector,
        limit: Int
    ) async throws -> [VectorSearchResult] {
        // 暴力搜索（小规模数据可用）
        let results = nodes.values
            .map { node -> (HNSWNode, Float) in
                let score = cosineSimilarity(query.vector, node.vector)
                return (node, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { tuple -> VectorSearchResult in
                VectorSearchResult(
                    id: tuple.0.id,
                    score: tuple.1,
                    metadata: VectorMetadata(
                        planId: "",
                        segmentId: "",
                        layer: .distilled,
                        timestamp: Date(),
                        tags: []
                    )
                )
            }
        
        return Array(results)
    }
    
    func delete(id: MemoryID) async throws {
        nodes.removeValue(forKey: id.description)
    }
    
    // MARK: - Helper
    
    private func randomLevel() -> Int {
        let ml = Double(m)
        let level = Int(-log(Double.random(in: 0...1)) * ml)
        return min(level, maxLevel)
    }
    
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        
        guard normA > 0 && normB > 0 else { return 0 }
        return dot / (sqrt(normA) * sqrt(normB))
    }
}

// MARK: - Integration

extension DistilledMemoryStore {
    /// 同步到向量存储
    func syncToVectorStore(_ vectorStore: VectorStore) async throws {
        for entry in entries {
            let metadata = VectorMetadata(
                planId: entry.id.planId,
                segmentId: entry.id.segmentId,
                layer: .distilled,
                timestamp: entry.timestamp,
                tags: entry.concepts.map(\.name)
            )
            
            try await vectorStore.store(
                id: entry.id,
                vector: entry.embedding,
                metadata: metadata
            )
        }
    }
    
    /// 同步到知识图谱
    func syncToKnowledgeGraph(_ graphStore: KnowledgeGraphStore) async throws {
        for entry in entries {
            // 创建概念节点
            for concept in entry.concepts {
                let properties: [String: Any] = [
                    "name": concept.name,
                    "type": concept.type.rawValue,
                    "definition": concept.definition,
                    "confidence": concept.confidence
                ]
                
                let nodeId = try await graphStore.createNode(
                    type: "Concept",
                    properties: properties
                )
                
                LogInfo("[GraphSync] Created node \(nodeId) for concept: \(concept.name)")
            }
            
            // 创建关系边
            for relation in entry.relations {
                let properties: [String: Any] = [
                    "type": relation.type.rawValue,
                    "strength": relation.strength
                ]
                
                try await graphStore.createRelation(
                    from: relation.sourceConceptId,
                    to: relation.targetConceptId,
                    type: relation.type.rawValue,
                    properties: properties
                )
            }
        }
    }
}
