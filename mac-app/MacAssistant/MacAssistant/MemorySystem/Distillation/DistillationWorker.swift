//
//  DistillationWorker.swift
//  MacAssistant
//
//  Background L0→L1 Distillation Worker (Phase 2)
//

import Foundation

/// 后台蒸馏工作器：持续将 L0 原始数据蒸馏为 L1 过滤数据
actor DistillationWorker {
    
    // MARK: - Configuration
    
    struct Configuration {
        let batchSize: Int
        let pollInterval: TimeInterval
        let maxConcurrentTasks: Int
        let enableRealtimeDistillation: Bool
        
        static let `default` = Configuration(
            batchSize: 10,
            pollInterval: 5.0,
            maxConcurrentTasks: 3,
            enableRealtimeDistillation: true
        )
    }
    
    // MARK: - State
    
    private let config: Configuration
    private let l0Store: RawMemoryStore
    private let l1Store: FilteredMemoryStore
    private let l1Engine: L1DistillationEngine
    
    private var isRunning = false
    private var processedCount: UInt64 = 0
    private var failedCount: UInt64 = 0
    private var lastProcessedID: MemoryID?
    private var workerTask: Task<Void, Never>?
    
    // 统计
    private var stats = DistillationStats()
    
    // MARK: - Initialization
    
    init(
        config: Configuration = .default,
        l0Store: RawMemoryStore,
        l1Store: FilteredMemoryStore,
        l1Engine: L1DistillationEngine = L1DistillationEngine()
    ) {
        self.config = config
        self.l0Store = l0Store
        self.l1Store = l1Store
        self.l1Engine = l1Engine
    }
    
    // MARK: - Control
    
    func start() async {
        guard !isRunning else {
            LogInfo("[DistillationWorker] Already running")
            return
        }
        
        isRunning = true
        LogInfo("[DistillationWorker] Starting with config: batchSize=\(config.batchSize), interval=\(config.pollInterval)")
        
        workerTask = Task {
            await runLoop()
        }
    }
    
    func stop() async {
        isRunning = false
        workerTask?.cancel()
        workerTask = nil
        LogInfo("[DistillationWorker] Stopped. Processed: \(processedCount), Failed: \(failedCount)")
    }
    
    func restart() async {
        await stop()
        await start()
    }
    
    // MARK: - Main Loop
    
    private func runLoop() async {
        while isRunning && !Task.isCancelled {
            do {
                // 获取待处理的 L0 条目
                let pendingEntries = try await fetchPendingEntries()
                
                if pendingEntries.isEmpty {
                    // 没有新数据，等待
                    try? await Task.sleep(nanoseconds: UInt64(config.pollInterval * 1_000_000_000))
                    continue
                }
                
                // 批量蒸馏
                let results = try await processBatch(pendingEntries)
                
                // 存储到 L1
                try await storeResults(results)
                
                // 更新统计
                await updateStats(processed: results.success.count, failed: results.failed.count)
                
                LogDebug("[DistillationWorker] Processed batch: \(results.success.count) success, \(results.failed.count) failed")
                
            } catch {
                LogError("[DistillationWorker] Error in run loop: \(error)")
                // 错误后等待更长时间
                try? await Task.sleep(nanoseconds: UInt64(10 * 1_000_000_000))
            }
        }
    }
    
    // MARK: - Processing
    
    private func fetchPendingEntries() async throws -> [RawMemoryEntry] {
        // 简化实现：获取最近的 L0 条目
        // 实际实现应记录上次处理的 ID，只获取新条目
        let recentTime = Date().addingTimeInterval(-3600) // 最近1小时
        return try await l0Store.query(
            planId: nil,
            timeRange: recentTime...Date(),
            types: [.llmCall, .userInput]
        )
    }
    
    private func processBatch(_ entries: [RawMemoryEntry]) async throws -> BatchResult {
        var success: [FilteredMemoryEntry] = []
        var failed: [(RawMemoryEntry, Error)] = []
        
        // 并发处理（限制并发数）
        await withTaskGroup(of: (RawMemoryEntry, FilteredMemoryEntry?, Error?).self) { group in
            for entry in entries.prefix(config.maxConcurrentTasks) {
                group.addTask {
                    do {
                        if let distilled = try await self.l1Engine.distill(entry) {
                            return (entry, distilled, nil)
                        } else {
                            // 重要性不足被过滤
                            return (entry, nil, nil)
                        }
                    } catch {
                        return (entry, nil, error)
                    }
                }
            }
            
            for await (entry, distilled, error) in group {
                if let distilled = distilled {
                    success.append(distilled)
                } else if let error = error {
                    failed.append((entry, error))
                }
                // distilled == nil 且 error == nil 表示被过滤，不计入失败
            }
        }
        
        return BatchResult(success: success, failed: failed)
    }
    
    private func storeResults(_ results: BatchResult) async throws {
        if !results.success.isEmpty {
            try await l1Store.storeBatch(results.success)
            
            // 更新最后处理 ID
            if let last = results.success.last {
                lastProcessedID = last.sourceId
            }
        }
    }
    
    // MARK: - Real-time Distillation
    
    /// 实时蒸馏单个条目（用于高优先级场景）
    func distillRealtime(_ entry: RawMemoryEntry) async throws -> FilteredMemoryEntry? {
        guard config.enableRealtimeDistillation else {
            return nil
        }
        
        // 直接蒸馏，不走批量队列
        if let distilled = try await l1Engine.distill(entry) {
            try await l1Store.store(distilled)
            processedCount += 1
            return distilled
        }
        
        return nil
    }
    
    // MARK: - Stats
    
    private func updateStats(processed: Int, failed: Int) async {
        processedCount += UInt64(processed)
        failedCount += UInt64(failed)
        
        stats.totalProcessed = processedCount
        stats.totalFailed = failedCount
        stats.successRate = processedCount > 0 ? Double(processedCount) / Double(processedCount + failedCount) : 0
        stats.lastUpdate = Date()
    }
    
    func getStats() async -> DistillationStats {
        stats
    }
    
    // MARK: - Manual Trigger
    
    /// 手动触发全量蒸馏（用于初始化或修复）
    func triggerFullDistillation(planId: String?) async throws -> Int {
        LogInfo("[DistillationWorker] Starting full distillation for plan: \(planId ?? "all")")
        
        var totalDistilled = 0
        var hasMore = true
        
        while hasMore {
            // 获取一批未处理的 L0 条目
            let entries = try await l0Store.query(
                planId: planId,
                timeRange: Date.distantPast...Date(),
                types: nil
            ).prefix(config.batchSize)
            
            guard !entries.isEmpty else {
                hasMore = false
                break
            }
            
            // 处理这批
            let results = try await processBatch(Array(entries))
            try await storeResults(results)
            
            totalDistilled += results.success.count
            
            // 短暂休息，避免占用过多资源
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        LogInfo("[DistillationWorker] Full distillation completed: \(totalDistilled) entries")
        return totalDistilled
    }
}

// MARK: - Supporting Types

struct BatchResult {
    let success: [FilteredMemoryEntry]
    let failed: [(RawMemoryEntry, Error)]
}

struct DistillationStats: Sendable {
    var totalProcessed: UInt64 = 0
    var totalFailed: UInt64 = 0
    var successRate: Double = 0
    var lastUpdate: Date?
    var averageProcessingTimeMs: Double = 0
    
    var description: String {
        """
        [Distillation Stats]
        Processed: \(totalProcessed)
        Failed: \(totalFailed)
        Success Rate: \(Int(successRate * 100))%
        Last Update: \(lastUpdate?.description ?? "Never")
        """
    }
}

// MARK: - Convenience Extensions

extension DistillationWorker {
    /// 创建并启动默认 Worker
    static func createAndStart(
        l0Store: RawMemoryStore,
        l1Store: FilteredMemoryStore
    ) async -> DistillationWorker {
        let worker = DistillationWorker(
            l0Store: l0Store,
            l1Store: l1Store
        )
        await worker.start()
        return worker
    }
}
