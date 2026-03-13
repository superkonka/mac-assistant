//
//  BatchProcessor.swift
//  MacAssistant
//
//  Phase 7: Batch Processing Optimization
//

import Foundation

// MARK: - Batch Configuration

struct BatchConfig {
    /// 最大批处理大小
    let maxBatchSize: Int
    /// 最大等待时间（毫秒）
    let maxWaitMs: Int
    /// 并发数
    let concurrency: Int
    /// 重试次数
    let retryCount: Int
    /// 重试延迟（毫秒）
    let retryDelayMs: Int
    
    static let `default` = BatchConfig(
        maxBatchSize: 100,
        maxWaitMs: 100,
        concurrency: 4,
        retryCount: 3,
        retryDelayMs: 1000
    )
    
    static let embedding = BatchConfig(
        maxBatchSize: 100,  // OpenAI 限制
        maxWaitMs: 50,
        concurrency: 2,
        retryCount: 3,
        retryDelayMs: 1000
    )
    
    static let storage = BatchConfig(
        maxBatchSize: 500,
        maxWaitMs: 200,
        concurrency: 4,
        retryCount: 3,
        retryDelayMs: 500
    )
    
    static let distillation = BatchConfig(
        maxBatchSize: 50,
        maxWaitMs: 500,
        concurrency: 2,
        retryCount: 2,
        retryDelayMs: 2000
    )
}

// MARK: - Batch Processor

actor BatchProcessor<Input, Output> {
    private let config: BatchConfig
    private let processor: ([Input]) async throws -> [Output]
    private var buffer: [Input] = []
    private var continuations: [CheckedContinuation<Output, Error>] = []
    private var processingTask: Task<Void, Never>?
    private let flushInterval: Duration
    
    init(
        config: BatchConfig = .default,
        processor: @escaping ([Input]) async throws -> [Output]
    ) {
        self.config = config
        self.processor = processor
        self.flushInterval = .milliseconds(config.maxWaitMs)
    }
    
    /// 提交单个项目进行处理
    func submit(_ input: Input) async throws -> Output {
        // 如果正在处理中，添加到缓冲区
        buffer.append(input)
        
        // 如果达到批处理大小，立即处理
        if buffer.count >= config.maxBatchSize {
            await flush()
        } else {
            // 启动延迟处理任务
            startDelayedFlush()
        }
        
        // 等待结果
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }
    
    /// 批量提交
    func submitBatch(_ inputs: [Input]) async throws -> [Output] {
        // 分批处理
        var results: [Output] = []
        
        for chunk in inputs.chunked(into: config.maxBatchSize) {
            let chunkResults = try await processBatchWithRetry(chunk)
            results.append(contentsOf: chunkResults)
        }
        
        return results
    }
    
    /// 立即刷新缓冲区
    func flush() async {
        guard !buffer.isEmpty else { return }
        
        let batch = buffer
        let batchContinuations = continuations
        buffer.removeAll()
        continuations.removeAll()
        
        do {
            let results = try await processBatchWithRetry(batch)
            
            // 分发结果
            for (index, continuation) in batchContinuations.enumerated() {
                if index < results.count {
                    continuation.resume(returning: results[index])
                } else {
                    continuation.resume(throwing: BatchError.mismatchedResultCount)
                }
            }
        } catch {
            // 所有项目都失败
            for continuation in batchContinuations {
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// 关闭处理器
    func shutdown() async {
        await flush()
        processingTask?.cancel()
    }
    
    // MARK: - Private Methods
    
    private func startDelayedFlush() {
        // 取消之前的延迟任务
        processingTask?.cancel()
        
        // 创建新的延迟任务
        processingTask = Task {
            do {
                try await Task.sleep(for: flushInterval)
                if !Task.isCancelled {
                    await flush()
                }
            } catch {
                // Task cancelled or sleep error
            }
        }
    }
    
    private func processBatchWithRetry(_ batch: [Input]) async throws -> [Output] {
        var lastError: Error?
        
        for attempt in 0..<config.retryCount {
            do {
                return try await processor(batch)
            } catch {
                lastError = error
                LogWarning("[BatchProcessor] Attempt \(attempt + 1) failed: \(error)")
                
                if attempt < config.retryCount - 1 {
                    try await Task.sleep(nanoseconds: UInt64(config.retryDelayMs) * 1_000_000)
                }
            }
        }
        
        throw lastError ?? BatchError.unknown
    }
}

// MARK: - Batch Error

enum BatchError: Error {
    case mismatchedResultCount
    case unknown
    case timeout
}

// MARK: - Memory System Batch Processors

/// 批量嵌入处理器
actor BatchEmbeddingProcessor {
    private let service: EmbeddingService
    private let processor: BatchProcessor<String, EmbeddingVector>
    private var processingCount = 0
    
    init(service: EmbeddingService) {
        self.service = service
        self.processor = BatchProcessor(config: .embedding) { [service] texts in
            return try await service.embedBatch(texts: texts)
        }
    }
    
    func embed(_ text: String) async throws -> EmbeddingVector {
        processingCount += 1
        defer { processingCount -= 1 }
        return try await processor.submit(text)
    }
    
    func embedBatch(_ texts: [String]) async throws -> [EmbeddingVector] {
        try await processor.submitBatch(texts)
    }
    
    func shutdown() async {
        await processor.shutdown()
    }
    
    func isProcessing() -> Bool {
        processingCount > 0
    }
}

/// 批量存储处理器
actor BatchStorageProcessor {
    private let l0Store: RawMemoryStore
    private let l1Store: FilteredMemoryStore
    
    private let l0Processor: BatchProcessor<RawMemoryEntry, Void>
    private let l1Processor: BatchProcessor<FilteredMemoryEntry, Void>
    
    init(l0Store: RawMemoryStore, l1Store: FilteredMemoryStore) {
        self.l0Store = l0Store
        self.l1Store = l1Store
        
        self.l0Processor = BatchProcessor(config: .storage) { entries in
            try await l0Store.appendBatch(entries)
            return Array(repeating: (), count: entries.count)
        }
        
        self.l1Processor = BatchProcessor(config: .storage) { entries in
            try await l1Store.storeBatch(entries)
            return Array(repeating: (), count: entries.count)
        }
    }
    
    func appendL0(_ entry: RawMemoryEntry) async throws {
        try await l0Processor.submit(entry)
    }
    
    func appendL0Batch(_ entries: [RawMemoryEntry]) async throws {
        _ = try await l0Processor.submitBatch(entries)
    }
    
    func storeL1(_ entry: FilteredMemoryEntry) async throws {
        try await l1Processor.submit(entry)
    }
    
    func storeL1Batch(_ entries: [FilteredMemoryEntry]) async throws {
        _ = try await l1Processor.submitBatch(entries)
    }
    
    func shutdown() async {
        await l0Processor.shutdown()
        await l1Processor.shutdown()
    }
}

/// 批量蒸馏处理器
actor BatchDistillationProcessor {
    private let l0Store: RawMemoryStore
    private let l1Store: FilteredMemoryStore
    private let l1Engine: L1DistillationEngine
    private let processor: BatchProcessor<RawMemoryEntry, FilteredMemoryEntry?>
    
    private var stats = BatchDistillationStats()
    
    init(l0Store: RawMemoryStore, l1Store: FilteredMemoryStore) {
        self.l0Store = l0Store
        self.l1Store = l1Store
        self.l1Engine = L1DistillationEngine()
        
        self.processor = BatchProcessor(config: .distillation) { [l1Engine, l1Store] entries in
            var results: [FilteredMemoryEntry?] = []
            
            for entry in entries {
                if let distilled = try? await l1Engine.distill(entry) {
                    try? await l1Store.store(distilled)
                    results.append(distilled)
                } else {
                    results.append(nil)
                }
            }
            
            return results
        }
    }
    
    func distill(_ entry: RawMemoryEntry) async throws -> FilteredMemoryEntry? {
        let startTime = Date()
        let result = try await processor.submit(entry)
        let duration = Date().timeIntervalSince(startTime)
        
        await stats.record(success: result != nil, durationMs: Int(duration * 1000))
        return result
    }
    
    func distillBatch(_ entries: [RawMemoryEntry]) async throws -> [FilteredMemoryEntry?] {
        let startTime = Date()
        let results = try await processor.submitBatch(entries)
        let duration = Date().timeIntervalSince(startTime)
        
        let successCount = results.compactMap { $0 }.count
        await stats.recordBatch(successCount: successCount, totalCount: results.count, durationMs: Int(duration * 1000))
        return results
    }
    
    func getStats() async -> BatchDistillationStats {
        stats
    }
    
    func shutdown() async {
        await processor.shutdown()
    }
}

// MARK: - Batch Distillation Stats

actor BatchDistillationStats {
    private(set) var totalProcessed: Int = 0
    private(set) var totalFailed: Int = 0
    private(set) var totalDurationMs: Int = 0
    private(set) var batchCount: Int = 0
    
    func record(success: Bool, durationMs: Int) {
        totalProcessed += 1
        if !success {
            totalFailed += 1
        }
        totalDurationMs += durationMs
    }
    
    func recordBatch(successCount: Int, totalCount: Int, durationMs: Int) {
        totalProcessed += successCount
        totalFailed += (totalCount - successCount)
        totalDurationMs += durationMs
        batchCount += 1
    }
    
    var averageLatencyMs: Double {
        totalProcessed > 0 ? Double(totalDurationMs) / Double(totalProcessed) : 0
    }
    
    var throughputPerSecond: Double {
        totalDurationMs > 0 ? Double(totalProcessed) / (Double(totalDurationMs) / 1000.0) : 0
    }
    
    var description: String {
        "Processed: \(totalProcessed), Failed: \(totalFailed), " +
        "Avg Latency: \(String(format: "%.1f", averageLatencyMs))ms, " +
        "Throughput: \(String(format: "%.1f", throughputPerSecond))/s"
    }
}

// MARK: - Pipeline Optimizer

/// 流水线优化器 - 协调多个批处理器的执行
actor PipelineOptimizer {
    
    private var processors: [String: Any] = [:]
    private var isRunning = false
    
    func registerProcessor<T, U>(_ processor: BatchProcessor<T, U>, name: String) {
        processors[name] = processor
    }
    
    func start() {
        isRunning = true
        LogInfo("[PipelineOptimizer] Pipeline started")
    }
    
    func stop() async {
        isRunning = false
        
        // 关闭所有处理器
        for (name, processor) in processors {
            if let p = processor as? BatchProcessor<RawMemoryEntry, Void> {
                await p.shutdown()
            } else if let p = processor as? BatchProcessor<FilteredMemoryEntry, Void> {
                await p.shutdown()
            } else if let p = processor as? BatchProcessor<String, EmbeddingVector> {
                await p.shutdown()
            }
            LogDebug("[PipelineOptimizer] Shutdown: \(name)")
        }
        
        LogInfo("[PipelineOptimizer] Pipeline stopped")
    }
    
    func flushAll() async {
        for (name, processor) in processors {
            if let p = processor as? BatchProcessor<RawMemoryEntry, Void> {
                await p.flush()
            } else if let p = processor as? BatchProcessor<FilteredMemoryEntry, Void> {
                await p.flush()
            } else if let p = processor as? BatchProcessor<String, EmbeddingVector> {
                await p.flush()
            }
            LogDebug("[PipelineOptimizer] Flushed: \(name)")
        }
    }
    
    func getStatus() -> [String: String] {
        var status: [String: String] = [:]
        status["running"] = isRunning ? "yes" : "no"
        status["processors"] = "\(processors.count)"
        return status
    }
}
