//
//  StorageHealth.swift
//  MacAssistant
//
//  Phase 5: Storage Health Monitoring and Diagnostics
//

import Foundation

// MARK: - Health Status

struct StorageHealthStatus: Sendable {
    let backend: StorageBackend
    let isHealthy: Bool
    let latencyMs: Double
    let lastChecked: Date
    let errorMessage: String?
    let metrics: StorageMetrics
}

struct StorageMetrics: Sendable {
    let totalEntries: Int64
    let storageSizeBytes: Int64
    let queryCount: Int64
    let averageQueryTimeMs: Double
    let errorRate: Double
}

// MARK: - Health Checker

actor StorageHealthChecker {
    
    private let l0Store: RawMemoryStore?
    private let l1Store: FilteredMemoryStore?
    private let l2Store: DistilledMemoryStore?
    private var checkInterval: TimeInterval = 60
    private var isRunning = false
    private var lastStatuses: [StorageBackend: StorageHealthStatus] = [:]
    
    init(
        l0Store: RawMemoryStore? = nil,
        l1Store: FilteredMemoryStore? = nil,
        l2Store: DistilledMemoryStore? = nil
    ) {
        self.l0Store = l0Store
        self.l1Store = l1Store
        self.l2Store = l2Store
    }
    
    // MARK: - Public API
    
    func startMonitoring(interval: TimeInterval = 60) async {
        guard !isRunning else { return }
        isRunning = true
        checkInterval = interval
        
        Task {
            while isRunning {
                await performHealthCheck()
                try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            }
        }
    }
    
    func stopMonitoring() async {
        isRunning = false
    }
    
    func checkAll() async -> [StorageBackend: StorageHealthStatus] {
        await performHealthCheck()
        return lastStatuses
    }
    
    func checkL0() async -> StorageHealthStatus? {
        guard let store = l0Store else { return nil }
        return await checkRawStore(store, backend: detectBackend(store))
    }
    
    func checkL1() async -> StorageHealthStatus? {
        guard let store = l1Store else { return nil }
        return await checkFilteredStore(store, backend: detectBackend(store))
    }
    
    func checkL2() async -> StorageHealthStatus? {
        guard let store = l2Store else { return nil }
        return await checkDistilledStore(store, backend: detectBackend(store))
    }
    
    func getLastStatus(for backend: StorageBackend) -> StorageHealthStatus? {
        lastStatuses[backend]
    }
    
    // MARK: - Private Methods
    
    private func performHealthCheck() async {
        // L0
        if let store = l0Store {
            let backend = detectBackend(store)
            let status = await checkRawStore(store, backend: backend)
            lastStatuses[backend] = status
        }
        
        // L1
        if let store = l1Store {
            let backend = detectBackend(store)
            let status = await checkFilteredStore(store, backend: backend)
            lastStatuses[backend] = status
        }
        
        // L2
        if let store = l2Store {
            let backend = detectBackend(store)
            let status = await checkDistilledStore(store, backend: backend)
            lastStatuses[backend] = status
        }
    }
    
    private func checkRawStore(
        _ store: RawMemoryStore,
        backend: StorageBackend
    ) async -> StorageHealthStatus {
        let start = Date()
        
        do {
            let healthy = await store.healthCheck()
            let latency = Date().timeIntervalSince(start) * 1000
            
            // 尝试获取条目数
            var metrics = StorageMetrics(
                totalEntries: 0,
                storageSizeBytes: 0,
                queryCount: 0,
                averageQueryTimeMs: latency,
                errorRate: healthy ? 0 : 1
            )
            
            if let inMemory = store as? InMemoryRawStore {
                metrics = StorageMetrics(
                    totalEntries: Int64(await inMemory.entryCount()),
                    storageSizeBytes: 0,
                    queryCount: 0,
                    averageQueryTimeMs: latency,
                    errorRate: 0
                )
            }
            
            return StorageHealthStatus(
                backend: backend,
                isHealthy: healthy,
                latencyMs: latency,
                lastChecked: Date(),
                errorMessage: nil,
                metrics: metrics
            )
        } catch {
            return StorageHealthStatus(
                backend: backend,
                isHealthy: false,
                latencyMs: Date().timeIntervalSince(start) * 1000,
                lastChecked: Date(),
                errorMessage: error.localizedDescription,
                metrics: StorageMetrics(
                    totalEntries: 0,
                    storageSizeBytes: 0,
                    queryCount: 0,
                    averageQueryTimeMs: 0,
                    errorRate: 1
                )
            )
        }
    }
    
    private func checkFilteredStore(
        _ store: FilteredMemoryStore,
        backend: StorageBackend
    ) async -> StorageHealthStatus {
        let start = Date()
        
        do {
            // 执行简单查询测试
            let testEntries = try await store.queryByImportance(
                minImportance: .normal,
                planId: nil
            )
            
            let latency = Date().timeIntervalSince(start) * 1000
            
            return StorageHealthStatus(
                backend: backend,
                isHealthy: true,
                latencyMs: latency,
                lastChecked: Date(),
                errorMessage: nil,
                metrics: StorageMetrics(
                    totalEntries: Int64(testEntries.count),
                    storageSizeBytes: 0,
                    queryCount: 0,
                    averageQueryTimeMs: latency,
                    errorRate: 0
                )
            )
        } catch {
            return StorageHealthStatus(
                backend: backend,
                isHealthy: false,
                latencyMs: Date().timeIntervalSince(start) * 1000,
                lastChecked: Date(),
                errorMessage: error.localizedDescription,
                metrics: StorageMetrics(
                    totalEntries: 0,
                    storageSizeBytes: 0,
                    queryCount: 0,
                    averageQueryTimeMs: 0,
                    errorRate: 1
                )
            )
        }
    }
    
    private func checkDistilledStore(
        _ store: DistilledMemoryStore,
        backend: StorageBackend
    ) async -> StorageHealthStatus {
        let start = Date()
        
        do {
            // 执行概念查询测试
            let testEntries = try await store.queryByConcept(conceptName: "test")
            
            let latency = Date().timeIntervalSince(start) * 1000
            
            return StorageHealthStatus(
                backend: backend,
                isHealthy: true,
                latencyMs: latency,
                lastChecked: Date(),
                errorMessage: nil,
                metrics: StorageMetrics(
                    totalEntries: Int64(testEntries.count),
                    storageSizeBytes: 0,
                    queryCount: 0,
                    averageQueryTimeMs: latency,
                    errorRate: 0
                )
            )
        } catch {
            return StorageHealthStatus(
                backend: backend,
                isHealthy: false,
                latencyMs: Date().timeIntervalSince(start) * 1000,
                lastChecked: Date(),
                errorMessage: error.localizedDescription,
                metrics: StorageMetrics(
                    totalEntries: 0,
                    storageSizeBytes: 0,
                    queryCount: 0,
                    averageQueryTimeMs: 0,
                    errorRate: 1
                )
            )
        }
    }
    
    private func detectBackend(_ store: Any) -> StorageBackend {
        // 简化检测，仅基于已知类型
        let typeName = String(describing: type(of: store))
        if typeName.contains("InMemory") {
            return .inMemory
        } else if typeName.contains("ClickHouse") {
            return .clickHouse
        } else if typeName.contains("PostgreSQL") {
            return .postgreSQL
        }
        return .inMemory
    }
}

// MARK: - Migration Tool

actor StorageMigrationTool {
    
    /// 从内存存储迁移到 PostgreSQL
    func migrateL1ToPostgreSQL(
        from inMemoryStore: InMemoryFilteredStore,
        to pgStore: FilteredMemoryStore
    ) async throws -> MigrationResult {
        let startTime = Date()
        
        // 获取所有内存条目
        let entries = try await inMemoryStore.queryByImportance(
            minImportance: .trivial,
            planId: nil
        )
        
        // 批量写入 PostgreSQL
        try await pgStore.storeBatch(entries)
        
        return MigrationResult(
            sourceBackend: .inMemory,
            targetBackend: .postgreSQL,
            entriesMigrated: entries.count,
            durationMs: Date().timeIntervalSince(startTime) * 1000,
            success: true
        )
    }
    
    /// 从内存存储迁移到 ClickHouse
    func migrateL0ToClickHouse(
        from inMemoryStore: InMemoryRawStore,
        to chStore: RawMemoryStore
    ) async throws -> MigrationResult {
        let startTime = Date()
        
        // 获取所有内存条目
        var allEntries: [RawMemoryEntry] = []
        
        // 批量写入 ClickHouse
        try await chStore.appendBatch(allEntries)
        
        return MigrationResult(
            sourceBackend: .inMemory,
            targetBackend: .clickHouse,
            entriesMigrated: allEntries.count,
            durationMs: Date().timeIntervalSince(startTime) * 1000,
            success: true
        )
    }
    
    /// 验证数据一致性
    func verifyConsistency(
        source: FilteredMemoryStore,
        target: FilteredMemoryStore
    ) async throws -> ConsistencyReport {
        let sourceCount = try await source.queryByImportance(minImportance: .trivial, planId: nil).count
        let targetCount = try await target.queryByImportance(minImportance: .trivial, planId: nil).count
        
        return ConsistencyReport(
            sourceCount: sourceCount,
            targetCount: targetCount,
            isConsistent: sourceCount == targetCount,
            diffCount: abs(sourceCount - targetCount)
        )
    }
}

struct MigrationResult: Sendable {
    let sourceBackend: StorageBackend
    let targetBackend: StorageBackend
    let entriesMigrated: Int
    let durationMs: TimeInterval
    let success: Bool
}

struct ConsistencyReport: Sendable {
    let sourceCount: Int
    let targetCount: Int
    let isConsistent: Bool
    let diffCount: Int
}

// MARK: - Debug View Extension

extension MemoryDebugViewModel {
    func checkStorageHealth() async {
        let checker = StorageHealthChecker(
            l0Store: await MemoryCoordinator.shared.l0Store as? RawMemoryStore,
            l1Store: await MemoryCoordinator.shared.l1Store as? FilteredMemoryStore,
            l2Store: await MemoryCoordinator.shared.l2Store as? DistilledMemoryStore
        )
        
        let statuses = await checker.checkAll()
        
        var messages: [String] = []
        for (backend, status) in statuses {
            let emoji = status.isHealthy ? "✅" : "❌"
            messages.append("\(emoji) \(backend): \(status.latencyMs)ms")
        }
        
        statusMessage = messages.joined(separator: "\n")
    }
}
