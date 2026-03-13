//
//  StorageProtocols.swift
//  MacAssistant
//
//  Memory Storage Protocols (L0/L1/L2)
//

import Foundation

// MARK: - L0 Storage Protocol

/// L0 原始数据存储
protocol RawMemoryStore: Actor {
    /// 追加原始记录
    func append(_ entry: RawMemoryEntry) async throws
    
    /// 批量追加
    func appendBatch(_ entries: [RawMemoryEntry]) async throws
    
    /// 按 ID 获取
    func get(id: MemoryID) async throws -> RawMemoryEntry?
    
    /// 查询执行链路
    func getExecutionTrace(
        planId: String,
        taskId: String?
    ) async throws -> [RawMemoryEntry]
    
    /// 时间范围查询
    func query(
        planId: String?,
        timeRange: ClosedRange<Date>,
        types: [RawMemoryEntry.RawEntryType]?
    ) async throws -> [RawMemoryEntry]
    
    /// 获取 Plan 的所有原始记录
    func getPlanEntries(planId: String) async throws -> [RawMemoryEntry]
    
    /// 订阅实时流（用于蒸馏管道）
    func subscribe(batchSize: Int) -> AsyncStream<[RawMemoryEntry]>
    
    /// 删除过期数据
    func purgeEntries(olderThan: Date) async throws
    
    /// 健康检查
    func healthCheck() async -> Bool
}

// MARK: - L1 Storage Protocol

/// L1 过滤数据存储
protocol FilteredMemoryStore: Actor {
    /// 存储过滤后的条目
    func store(_ entry: FilteredMemoryEntry) async throws
    
    /// 批量存储
    func storeBatch(_ entries: [FilteredMemoryEntry]) async throws
    
    /// 按 ID 获取
    func get(id: MemoryID) async throws -> FilteredMemoryEntry?
    
    /// 批量获取
    func batchGet(ids: [MemoryID]) async throws -> [FilteredMemoryEntry]
    
    /// 重要性查询
    func queryByImportance(
        minImportance: ImportanceScore,
        planId: String?
    ) async throws -> [FilteredMemoryEntry]
    
    /// 关键词查询
    func queryByKeywords(
        keywords: [String],
        planId: String?
    ) async throws -> [FilteredMemoryEntry]
    
    /// 实体查询
    func queryByEntity(
        entityName: String,
        entityType: EntityReference.EntityType?
    ) async throws -> [FilteredMemoryEntry]
    
    /// 分类查询
    func queryByCategory(
        category: MemoryCategory,
        timeRange: ClosedRange<Date>?
    ) async throws -> [FilteredMemoryEntry]
    
    /// 获取 L2 的源条目
    func getSourcesForL2(l2Id: MemoryID) async throws -> [FilteredMemoryEntry]
    
    /// 删除过期数据
    func purgeEntries(olderThan: Date) async throws
}

// MARK: - L2 Storage Protocol

/// L2 蒸馏数据存储（向量 + 图谱）
protocol DistilledMemoryStore: Actor {
    /// 存储蒸馏条目
    func store(_ entry: DistilledMemoryEntry) async throws
    
    /// 更新现有条目（增量增强）
    func update(id: MemoryID, with entry: DistilledMemoryEntry) async throws
    
    /// 按 ID 获取
    func get(id: MemoryID) async throws -> DistilledMemoryEntry?
    
    /// 语义检索
    func semanticSearch(
        query: String,
        embedding: EmbeddingVector,
        topK: Int,
        filters: RetrievalFilters?
    ) async throws -> [DistilledMemoryEntry]
    
    /// 概念查询
    func queryByConcept(
        conceptName: String
    ) async throws -> [DistilledMemoryEntry]
    
    /// 关系查询
    func queryByRelation(
        conceptId: String,
        relationType: RelationType?
    ) async throws -> [DistilledMemoryEntry]
    
    /// 模式查询
    func queryByPattern(
        patternType: String
    ) async throws -> [DistilledMemoryEntry]
    
    /// 获取热门条目
    func getHotEntries(
        topics: [String],
        limit: Int
    ) async throws -> [DistilledMemoryEntry]
    
    /// 同步到知识图谱
    func syncToKnowledgeGraph(_ entry: DistilledMemoryEntry) async throws
}

// MARK: - Unified Memory Coordinator Protocol

/// 统一记忆协调器
protocol MemoryCoordinating: Actor {
    /// 初始化计划记忆上下文
    func initializePlanContext(
        planId: String,
        mainSessionKey: String
    ) async throws -> PlanMemoryContext
    
    /// 存储原始执行记录（L0）
    func storeRaw(_ entry: RawMemoryEntry) async throws
    
    /// 构建任务执行上下文（聚合 L0/L1/L2）
    func buildTaskContext(
        planId: String,
        taskId: String,
        requiredDepth: RetrievalDepth
    ) async -> TaskExecutionContext
    
    /// 分层检索
    func retrieve(
        query: RetrievalQuery
    ) async throws -> HierarchicalRetrievalResult
    
    /// 组装 LLM 上下文
    func assembleContext(
        retrievalResult: HierarchicalRetrievalResult,
        budget: ContextBudget
    ) async -> AssembledContext
    
    /// 计划完成，最终同步
    func finalizePlan(planId: String) async throws
}

// MARK: - Supporting Types

struct PlanMemoryContext: Sendable {
    let planId: String
    let mainSessionKey: String
    let initializedAt: Date
    let l0EntryCount: Int
}

struct TaskExecutionContext: Sendable {
    let taskId: String
    let planId: String
    let entries: [ContextEntry]
    let concepts: [Concept]
    let patterns: [Pattern]
    let writableScope: MemoryScope
}

struct ContextEntry: Sendable {
    let source: MemoryLayer
    let content: String
    let relevance: Double
    let timestamp: Date
}

struct MemoryScope: Sendable {
    let layer: MemoryLayer
    let planId: String
    let taskId: String?
}

struct ContextBudget: Sendable {
    let totalTokens: Int
    let l2Allocation: Int
    let l1Allocation: Int
    let l0Allocation: Int
    
    static let `default` = ContextBudget(
        totalTokens: 4000,
        l2Allocation: 800,
        l1Allocation: 2400,
        l0Allocation: 800
    )
}

// MARK: - Storage Factory

enum StorageBackend: String, Sendable {
    case clickHouse      // L0: 时序数据
    case postgreSQL      // L1: 结构化数据
    case pinecone        // L2: 向量存储
    case milvus          // L2: 开源替代
    case neo4j           // L2: 图谱存储
    case inMemory        // 测试用
}

actor MemoryStorageFactory {
    static func createRawStore(
        backend: StorageBackend
    ) -> RawMemoryStore {
        switch backend {
        case .clickHouse:
            return ClickHouseRawStore()
        case .inMemory:
            return InMemoryRawStore()
        default:
            fatalError("Unsupported backend for L0: \(backend)")
        }
    }
    
    static func createFilteredStore(
        backend: StorageBackend
    ) -> FilteredMemoryStore {
        switch backend {
        case .postgreSQL:
            return PostgreSQLFilteredStore()
        case .inMemory:
            return InMemoryFilteredStore()
        default:
            fatalError("Unsupported backend for L1: \(backend)")
        }
    }
    
    static func createDistilledStore(
        backend: StorageBackend
    ) -> DistilledMemoryStore {
        switch backend {
        case .pinecone:
            return PineconeDistilledStore()
        case .milvus:
            return MilvusDistilledStore()
        case .inMemory:
            return InMemoryDistilledStore()
        default:
            fatalError("Unsupported backend for L2: \(backend)")
        }
    }
}
