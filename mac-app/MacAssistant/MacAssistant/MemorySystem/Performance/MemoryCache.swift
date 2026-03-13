//
//  MemoryCache.swift
//  MacAssistant
//
//  Phase 7: LRU Cache Layer for Memory System
//

import Foundation

// MARK: - Cache Entry

struct CacheEntry<Value> {
    let value: Value
    let key: String
    var lastAccessed: Date
    var accessCount: Int
}

// MARK: - LRU Cache

actor LRUCache<Key: Hashable, Value> {
    private var cache: [Key: CacheEntry<Value>] = [:]
    private var accessOrder: [Key] = []
    private let maxSize: Int
    private let defaultTTL: TimeInterval?
    private var hitCount: UInt64 = 0
    private var missCount: UInt64 = 0
    
    init(maxSize: Int, defaultTTL: TimeInterval? = nil) {
        self.maxSize = max(maxSize, 1)
        self.defaultTTL = defaultTTL
    }
    
    // MARK: - Public API
    
    func get(_ key: Key) -> Value? {
        guard var entry = cache[key] else {
            missCount += 1
            return nil
        }
        
        // 检查 TTL
        if let ttl = defaultTTL,
           Date().timeIntervalSince(entry.lastAccessed) > ttl {
            remove(key)
            missCount += 1
            return nil
        }
        
        // 更新访问信息
        entry.lastAccessed = Date()
        entry.accessCount += 1
        cache[key] = entry
        
        // 更新访问顺序
        updateAccessOrder(key)
        
        hitCount += 1
        return entry.value
    }
    
    func set(_ key: Key, value: Value) {
        let entry = CacheEntry(
            value: value,
            key: String(describing: key),
            lastAccessed: Date(),
            accessCount: 1
        )
        
        // 如果已存在，更新
        if cache[key] != nil {
            cache[key] = entry
            updateAccessOrder(key)
            return
        }
        
        // 如果已满，淘汰最久未使用的
        if cache.count >= maxSize {
            evictLRU()
        }
        
        cache[key] = entry
        accessOrder.append(key)
    }
    
    func remove(_ key: Key) {
        cache.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
    }
    
    func clear() {
        cache.removeAll()
        accessOrder.removeAll()
        hitCount = 0
        missCount = 0
    }
    
    func getStats() -> CacheStats {
        let total = hitCount + missCount
        return CacheStats(
            size: cache.count,
            maxSize: maxSize,
            hitCount: hitCount,
            missCount: missCount,
            hitRate: total > 0 ? Double(hitCount) / Double(total) : 0,
            memoryEstimate: estimateMemory()
        )
    }
    
    func prefetch(keys: [Key], fetcher: @escaping (Key) async -> Value?) async {
        for key in keys {
            if cache[key] == nil {
                if let value = await fetcher(key) {
                    set(key, value: value)
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func updateAccessOrder(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
    
    private func evictLRU() {
        guard let oldestKey = accessOrder.first else { return }
        remove(oldestKey)
    }
    
    private func estimateMemory() -> Int64 {
        // 粗略估算内存使用
        Int64(cache.count * 1024) // 假设每个条目约 1KB
    }
}

// MARK: - Cache Stats

struct CacheStats: Sendable {
    let size: Int
    let maxSize: Int
    let hitCount: UInt64
    let missCount: UInt64
    let hitRate: Double
    let memoryEstimate: Int64
    
    var description: String {
        "Cache: \(size)/\(maxSize) entries, \(String(format: "%.1f", hitRate * 100))% hit rate, ~\(memoryEstimate / 1024)KB"
    }
}

// MARK: - Memory Cache Manager

actor MemoryCacheManager {
    
    static let shared = MemoryCacheManager()
    
    // 各层缓存
    private var l0Cache: LRUCache<MemoryID, RawMemoryEntry>
    private var l1Cache: LRUCache<MemoryID, FilteredMemoryEntry>
    private var l2Cache: LRUCache<MemoryID, DistilledMemoryEntry>
    
    // 查询结果缓存
    private var queryCache: LRUCache<String, [Any]>
    
    // 嵌入向量缓存
    private var embeddingCache: LRUCache<String, EmbeddingVector>
    
    // 上下文缓存
    private var contextCache: LRUCache<String, RetrievedContext>
    
    private init() {
        // 根据数据特性设置不同缓存大小
        // L0: 原始数据大，缓存少量热点
        self.l0Cache = LRUCache(maxSize: 100, defaultTTL: 300) // 5分钟TTL
        
        // L1: 过滤后数据，中等缓存
        self.l1Cache = LRUCache(maxSize: 500, defaultTTL: 600) // 10分钟TTL
        
        // L2: 蒸馏数据小，可以多缓存
        self.l2Cache = LRUCache(maxSize: 1000, defaultTTL: 1800) // 30分钟TTL
        
        // 查询结果缓存
        self.queryCache = LRUCache(maxSize: 200, defaultTTL: 60) // 1分钟TTL
        
        // 嵌入向量缓存（ expensive to compute）
        self.embeddingCache = LRUCache(maxSize: 5000, defaultTTL: 3600) // 1小时TTL
        
        // 上下文缓存
        self.contextCache = LRUCache(maxSize: 50, defaultTTL: 120) // 2分钟TTL
    }
    
    // MARK: - L0 Cache
    
    func getL0Entry(id: MemoryID) async -> RawMemoryEntry? {
        await l0Cache.get(id)
    }
    
    func setL0Entry(_ entry: RawMemoryEntry) async {
        await l0Cache.set(entry.id, value: entry)
    }
    
    // MARK: - L1 Cache
    
    func getL1Entry(id: MemoryID) async -> FilteredMemoryEntry? {
        await l1Cache.get(id)
    }
    
    func setL1Entry(_ entry: FilteredMemoryEntry) async {
        await l1Cache.set(entry.id, value: entry)
    }
    
    // MARK: - L2 Cache
    
    func getL2Entry(id: MemoryID) async -> DistilledMemoryEntry? {
        await l2Cache.get(id)
    }
    
    func setL2Entry(_ entry: DistilledMemoryEntry) async {
        await l2Cache.set(entry.id, value: entry)
    }
    
    // MARK: - Embedding Cache
    
    func getEmbedding(for text: String) async -> EmbeddingVector? {
        let key = text.hashValue.description
        return await embeddingCache.get(key)
    }
    
    func setEmbedding(for text: String, vector: EmbeddingVector) async {
        let key = text.hashValue.description
        await embeddingCache.set(key, value: vector)
    }
    
    // MARK: - Context Cache
    
    func getContext(planId: String, state: MemorySystemState) async -> RetrievedContext? {
        let key = "\(planId):\(state.recentKeywords.joined(separator: ","))"
        return await contextCache.get(key)
    }
    
    func setContext(planId: String, state: MemorySystemState, context: RetrievedContext) async {
        let key = "\(planId):\(state.recentKeywords.joined(separator: ","))"
        await contextCache.set(key, value: context)
    }
    
    // MARK: - Cache Management
    
    func clearAllCaches() async {
        await l0Cache.clear()
        await l1Cache.clear()
        await l2Cache.clear()
        await queryCache.clear()
        await embeddingCache.clear()
        await contextCache.clear()
    }
    
    func getAllStats() async -> [String: CacheStats] {
        [
            "L0": await l0Cache.getStats(),
            "L1": await l1Cache.getStats(),
            "L2": await l2Cache.getStats(),
            "Query": await queryCache.getStats(),
            "Embedding": await embeddingCache.getStats(),
            "Context": await contextCache.getStats()
        ]
    }
}

// MARK: - Cached Store Wrappers

/// 带缓存的 L0 Store
actor CachedRawMemoryStore: RawMemoryStore {
    private let underlying: RawMemoryStore
    private let cache: LRUCache<MemoryID, RawMemoryEntry>
    
    init(underlying: RawMemoryStore, cacheSize: Int = 100) {
        self.underlying = underlying
        self.cache = LRUCache(maxSize: cacheSize, defaultTTL: 300)
    }
    
    func append(_ entry: RawMemoryEntry) async throws {
        try await underlying.append(entry)
        await cache.set(entry.id, value: entry)
    }
    
    func appendBatch(_ entries: [RawMemoryEntry]) async throws {
        try await underlying.appendBatch(entries)
        for entry in entries {
            await cache.set(entry.id, value: entry)
        }
    }
    
    func get(id: MemoryID) async throws -> RawMemoryEntry? {
        // 先查缓存
        if let cached = await cache.get(id) {
            return cached
        }
        // 再查底层存储
        if let entry = try await underlying.get(id: id) {
            await cache.set(id, value: entry)
            return entry
        }
        return nil
    }
    
    func getExecutionTrace(planId: String, taskId: String?) async throws -> [RawMemoryEntry] {
        try await underlying.getExecutionTrace(planId: planId, taskId: taskId)
    }
    
    func query(planId: String?, timeRange: ClosedRange<Date>, types: [RawMemoryEntry.RawEntryType]?) async throws -> [RawMemoryEntry] {
        try await underlying.query(planId: planId, timeRange: timeRange, types: types)
    }
    
    func getPlanEntries(planId: String) async throws -> [RawMemoryEntry] {
        try await underlying.getPlanEntries(planId: planId)
    }
    
    func purgeEntries(olderThan: Date) async throws {
        try await underlying.purgeEntries(olderThan: olderThan)
        // 清理缓存中过期的条目
    }
    
    func healthCheck() async -> Bool {
        await underlying.healthCheck()
    }
    
    func getCacheStats() async -> CacheStats {
        await cache.getStats()
    }
    
    // Note: subscribe method not cached - delegate directly to underlying store
    nonisolated func subscribe(batchSize: Int) -> AsyncStream<[RawMemoryEntry]> {
        // Since underlying is actor-isolated, we need to handle this differently
        // For now, return empty stream - in production, this needs proper implementation
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

/// 带缓存的 L1 Store
actor CachedFilteredMemoryStore: FilteredMemoryStore {
    private let underlying: FilteredMemoryStore
    private let cache: LRUCache<MemoryID, FilteredMemoryEntry>
    private let queryCache: LRUCache<String, [FilteredMemoryEntry]>
    
    init(underlying: FilteredMemoryStore, cacheSize: Int = 500) {
        self.underlying = underlying
        self.cache = LRUCache(maxSize: cacheSize, defaultTTL: 600)
        self.queryCache = LRUCache(maxSize: 100, defaultTTL: 60)
    }
    
    func store(_ entry: FilteredMemoryEntry) async throws {
        try await underlying.store(entry)
        await cache.set(entry.id, value: entry)
    }
    
    func storeBatch(_ entries: [FilteredMemoryEntry]) async throws {
        try await underlying.storeBatch(entries)
        for entry in entries {
            await cache.set(entry.id, value: entry)
        }
    }
    
    func get(id: MemoryID) async throws -> FilteredMemoryEntry? {
        if let cached = await cache.get(id) {
            return cached
        }
        if let entry = try await underlying.get(id: id) {
            await cache.set(id, value: entry)
            return entry
        }
        return nil
    }
    
    func batchGet(ids: [MemoryID]) async throws -> [FilteredMemoryEntry] {
        var results: [FilteredMemoryEntry] = []
        var missingIds: [MemoryID] = []
        
        for id in ids {
            if let cached = await cache.get(id) {
                results.append(cached)
            } else {
                missingIds.append(id)
            }
        }
        
        if !missingIds.isEmpty {
            let fetched = try await underlying.batchGet(ids: missingIds)
            for entry in fetched {
                await cache.set(entry.id, value: entry)
                results.append(entry)
            }
        }
        
        return results
    }
    
    func queryByImportance(minImportance: ImportanceScore, planId: String?) async throws -> [FilteredMemoryEntry] {
        let cacheKey = "importance:\(minImportance.rawValue):\(planId ?? "all")"
        
        if let cached = await queryCache.get(cacheKey) {
            return cached
        }
        
        let results = try await underlying.queryByImportance(minImportance: minImportance, planId: planId)
        await queryCache.set(cacheKey, value: results)
        return results
    }
    
    func queryByKeywords(keywords: [String], planId: String?) async throws -> [FilteredMemoryEntry] {
        let cacheKey = "keywords:\(keywords.sorted().joined(separator: ",")):\(planId ?? "all")"
        
        if let cached = await queryCache.get(cacheKey) {
            return cached
        }
        
        let results = try await underlying.queryByKeywords(keywords: keywords, planId: planId)
        await queryCache.set(cacheKey, value: results)
        return results
    }
    
    func queryByEntity(entityName: String, entityType: EntityReference.EntityType?) async throws -> [FilteredMemoryEntry] {
        try await underlying.queryByEntity(entityName: entityName, entityType: entityType)
    }
    
    func queryByCategory(category: MemoryCategory, timeRange: ClosedRange<Date>?) async throws -> [FilteredMemoryEntry] {
        try await underlying.queryByCategory(category: category, timeRange: timeRange)
    }
    
    func getSourcesForL2(l2Id: MemoryID) async throws -> [FilteredMemoryEntry] {
        try await underlying.getSourcesForL2(l2Id: l2Id)
    }
    
    func purgeEntries(olderThan: Date) async throws {
        try await underlying.purgeEntries(olderThan: olderThan)
    }
    
    func getCacheStats() async -> (entryStats: CacheStats, queryStats: CacheStats) {
        (await cache.getStats(), await queryCache.getStats())
    }
}
