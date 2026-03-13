//
//  MemoryMetrics.swift
//  MacAssistant
//
//  Phase 7: Performance Metrics Collection and Reporting
//

import Foundation

// MARK: - Metric Types

enum MetricType: String {
    case counter    // 累计计数
    case gauge      // 瞬时值
    case histogram  // 分布统计
    case timer      // 时间度量
}

// MARK: - Metric Value

struct MetricValue: Sendable {
    let timestamp: Date
    let value: Double
    let labels: [String: String]
}

// MARK: - Memory Metrics Collector

actor MemoryMetricsCollector {
    
    static let shared = MemoryMetricsCollector()
    
    private var counters: [String: UInt64] = [:]
    private var gauges: [String: Double] = [:]
    private var histograms: [String: [Double]] = [:]
    private var timers: [String: [Double]] = [:]
    
    private var metricHistory: [String: [MetricValue]] = [:]
    private let maxHistorySize = 1000
    
    private var isRecording = true
    
    // MARK: - Counter Metrics
    
    func incrementCounter(_ name: String, by value: UInt64 = 1, labels: [String: String] = [:]) {
        guard isRecording else { return }
        
        let key = formatKey(name, labels: labels)
        counters[key, default: 0] += value
        
        recordHistory(key: key, value: Double(value), labels: labels)
    }
    
    func getCounter(_ name: String, labels: [String: String] = [:]) -> UInt64 {
        let key = formatKey(name, labels: labels)
        return counters[key] ?? 0
    }
    
    // MARK: - Gauge Metrics
    
    func setGauge(_ name: String, value: Double, labels: [String: String] = [:]) {
        guard isRecording else { return }
        
        let key = formatKey(name, labels: labels)
        gauges[key] = value
        
        recordHistory(key: key, value: value, labels: labels)
    }
    
    func getGauge(_ name: String, labels: [String: String] = [:]) -> Double? {
        let key = formatKey(name, labels: labels)
        return gauges[key]
    }
    
    // MARK: - Histogram Metrics
    
    func recordHistogram(_ name: String, value: Double, labels: [String: String] = [:]) {
        guard isRecording else { return }
        
        let key = formatKey(name, labels: labels)
        histograms[key, default: []].append(value)
        
        // 限制大小
        if histograms[key]!.count > maxHistorySize {
            histograms[key]!.removeFirst(histograms[key]!.count - maxHistorySize)
        }
        
        recordHistory(key: key, value: value, labels: labels)
    }
    
    func getHistogramStats(_ name: String, labels: [String: String] = [:]) -> HistogramStats? {
        let key = formatKey(name, labels: labels)
        guard let values = histograms[key], !values.isEmpty else { return nil }
        
        let sorted = values.sorted()
        let sum = values.reduce(0, +)
        let count = Double(values.count)
        
        return HistogramStats(
            count: values.count,
            min: sorted.first!,
            max: sorted.last!,
            mean: sum / count,
            p50: percentile(sorted, 0.5),
            p90: percentile(sorted, 0.9),
            p95: percentile(sorted, 0.95),
            p99: percentile(sorted, 0.99)
        )
    }
    
    // MARK: - Timer Metrics
    
    func time<T>(_ name: String, labels: [String: String] = [:], operation: () async throws -> T) async rethrows -> T {
        let startTime = Date()
        defer {
            let duration = Date().timeIntervalSince(startTime) * 1000 // ms
            recordTimer(name, durationMs: duration, labels: labels)
        }
        return try await operation()
    }
    
    func recordTimer(_ name: String, durationMs: Double, labels: [String: String] = [:]) {
        guard isRecording else { return }
        
        let key = formatKey(name, labels: labels)
        timers[key, default: []].append(durationMs)
        
        // 限制大小
        if timers[key]!.count > maxHistorySize {
            timers[key]!.removeFirst(timers[key]!.count - maxHistorySize)
        }
        
        recordHistory(key: key, value: durationMs, labels: labels)
    }
    
    func getTimerStats(_ name: String, labels: [String: String] = [:]) -> TimerStats? {
        let key = formatKey(name, labels: labels)
        guard let values = timers[key], !values.isEmpty else { return nil }
        
        let sorted = values.sorted()
        let sum = values.reduce(0, +)
        let count = Double(values.count)
        
        return TimerStats(
            count: values.count,
            min: sorted.first!,
            max: sorted.last!,
            mean: sum / count,
            p50: percentile(sorted, 0.5),
            p90: percentile(sorted, 0.9),
            p95: percentile(sorted, 0.95),
            p99: percentile(sorted, 0.99)
        )
    }
    
    // MARK: - History
    
    private func recordHistory(key: String, value: Double, labels: [String: String]) {
        let metricValue = MetricValue(
            timestamp: Date(),
            value: value,
            labels: labels
        )
        
        metricHistory[key, default: []].append(metricValue)
        
        // 限制历史大小
        if metricHistory[key]!.count > maxHistorySize {
            metricHistory[key]!.removeFirst(metricHistory[key]!.count - maxHistorySize)
        }
    }
    
    func getHistory(_ name: String, labels: [String: String] = [:], since: Date? = nil) -> [MetricValue] {
        let key = formatKey(name, labels: labels)
        var values = metricHistory[key] ?? []
        
        if let since = since {
            values = values.filter { $0.timestamp >= since }
        }
        
        return values
    }
    
    // MARK: - Control
    
    func startRecording() {
        isRecording = true
    }
    
    func stopRecording() {
        isRecording = false
    }
    
    func reset() {
        counters.removeAll()
        gauges.removeAll()
        histograms.removeAll()
        timers.removeAll()
        metricHistory.removeAll()
    }
    
    // MARK: - Export
    
    func exportMetrics() -> MetricsSnapshot {
        MetricsSnapshot(
            timestamp: Date(),
            counters: counters,
            gauges: gauges,
            histogramStats: histograms.compactMapValues { values in
                guard !values.isEmpty else { return nil }
                let sorted = values.sorted()
                let sum = values.reduce(0, +)
                return HistogramStats(
                    count: values.count,
                    min: sorted.first!,
                    max: sorted.last!,
                    mean: sum / Double(values.count),
                    p50: percentile(sorted, 0.5),
                    p90: percentile(sorted, 0.9),
                    p95: percentile(sorted, 0.95),
                    p99: percentile(sorted, 0.99)
                )
            },
            timerStats: timers.compactMapValues { values in
                guard !values.isEmpty else { return nil }
                let sorted = values.sorted()
                let sum = values.reduce(0, +)
                return TimerStats(
                    count: values.count,
                    min: sorted.first!,
                    max: sorted.last!,
                    mean: sum / Double(values.count),
                    p50: percentile(sorted, 0.5),
                    p90: percentile(sorted, 0.9),
                    p95: percentile(sorted, 0.95),
                    p99: percentile(sorted, 0.99)
                )
            }
        )
    }
    
    // MARK: - Private Methods
    
    private func formatKey(_ name: String, labels: [String: String]) -> String {
        if labels.isEmpty {
            return name
        }
        let labelStr = labels.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return "\(name){\(labelStr)}"
    }
    
    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[index]
    }
}

// MARK: - Stats Structures

struct HistogramStats: Sendable {
    let count: Int
    let min: Double
    let max: Double
    let mean: Double
    let p50: Double
    let p90: Double
    let p95: Double
    let p99: Double
}

typealias TimerStats = HistogramStats

struct MetricsSnapshot: Sendable {
    let timestamp: Date
    let counters: [String: UInt64]
    let gauges: [String: Double]
    let histogramStats: [String: HistogramStats]
    let timerStats: [String: TimerStats]
    
    func toJSON() -> String? {
        let dict: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "counters": counters,
            "gauges": gauges,
            "histograms": histogramStats.mapValues {
                [
                    "count": $0.count,
                    "min": $0.min,
                    "max": $0.max,
                    "mean": $0.mean,
                    "p50": $0.p50,
                    "p90": $0.p90,
                    "p95": $0.p95,
                    "p99": $0.p99
                ]
            },
            "timers": timerStats.mapValues {
                [
                    "count": $0.count,
                    "min": $0.min,
                    "max": $0.max,
                    "mean": $0.mean,
                    "p50": $0.p50,
                    "p90": $0.p90,
                    "p95": $0.p95,
                    "p99": $0.p99
                ]
            }
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Memory System Specific Metrics

extension MemoryMetricsCollector {
    
    // L0 Metrics
    func recordL0Store(durationMs: Double, size: Int) {
        recordTimer("l0.store", durationMs: durationMs)
        setGauge("l0.size", value: Double(size))
    }
    
    func recordL0Query(durationMs: Double, resultCount: Int) {
        recordTimer("l0.query", durationMs: durationMs)
        recordHistogram("l0.query.result_count", value: Double(resultCount))
    }
    
    // L1 Metrics
    func recordL1Distillation(durationMs: Double, success: Bool) {
        recordTimer("l1.distill", durationMs: durationMs)
        incrementCounter("l1.distill.total")
        if success {
            incrementCounter("l1.distill.success")
        } else {
            incrementCounter("l1.distill.failed")
        }
    }
    
    func recordL1Store(durationMs: Double) {
        recordTimer("l1.store", durationMs: durationMs)
    }
    
    // L2 Metrics
    func recordL2Distillation(durationMs: Double, conceptCount: Int) {
        recordTimer("l2.distill", durationMs: durationMs)
        recordHistogram("l2.concept_count", value: Double(conceptCount))
    }
    
    // Retrieval Metrics
    func recordRetrieval(durationMs: Double, layer: MemoryLayer, resultCount: Int) {
        recordTimer("retrieval.\(layer.rawValue)", durationMs: durationMs)
        recordHistogram("retrieval.result_count", value: Double(resultCount), labels: ["layer": layer.rawValue])
    }
    
    // Context Injection Metrics
    func recordContextInjection(durationMs: Double, tokenCount: Int) {
        recordTimer("injection", durationMs: durationMs)
        recordHistogram("injection.token_count", value: Double(tokenCount))
    }
    
    // Embedding Metrics
    func recordEmbeddingGeneration(durationMs: Double, batchSize: Int) {
        recordTimer("embedding.generate", durationMs: durationMs)
        recordHistogram("embedding.batch_size", value: Double(batchSize))
    }
    
    // Cache Metrics
    func recordCacheHit(layer: String) {
        incrementCounter("cache.hit", labels: ["layer": layer])
    }
    
    func recordCacheMiss(layer: String) {
        incrementCounter("cache.miss", labels: ["layer": layer])
    }
}

// MARK: - Performance Monitor

actor PerformanceMonitor {
    
    static let shared = PerformanceMonitor()
    
    private var metricsCollector = MemoryMetricsCollector.shared
    private var reportTask: Task<Void, Never>?
    private var reportInterval: TimeInterval = 60 // 1 minute
    
    func startMonitoring(interval: TimeInterval = 60) {
        reportInterval = interval
        reportTask?.cancel()
        
        reportTask = Task {
            while !Task.isCancelled {
                await generateReport()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        
        LogInfo("[PerformanceMonitor] Started with \(interval)s interval")
    }
    
    func stopMonitoring() {
        reportTask?.cancel()
        LogInfo("[PerformanceMonitor] Stopped")
    }
    
    func generateReport() async {
        let snapshot = await metricsCollector.exportMetrics()
        
        // 打印关键指标
        LogInfo("[PerformanceMonitor] ===== Metrics Report =====")
        
        // L0 存储
        if let l0StoreStats = snapshot.timerStats["l0.store"] {
            LogInfo("[PerformanceMonitor] L0 Store: count=\(l0StoreStats.count), avg=\(String(format: "%.1f", l0StoreStats.mean))ms")
        }
        
        // L1 蒸馏
        let l1Total = await metricsCollector.getCounter("l1.distill.total")
        let l1Success = await metricsCollector.getCounter("l1.distill.success")
        if l1Total > 0 {
            let rate = Double(l1Success) / Double(l1Total) * 100
            LogInfo("[PerformanceMonitor] L1 Distillation: total=\(l1Total), success=\(String(format: "%.1f", rate))%")
        }
        
        // 检索
        if let retrievalStats = snapshot.timerStats["retrieval.filtered"] {
            LogInfo("[PerformanceMonitor] L1 Retrieval: count=\(retrievalStats.count), avg=\(String(format: "%.1f", retrievalStats.mean))ms")
        }
        
        // 嵌入生成
        if let embeddingStats = snapshot.timerStats["embedding.generate"] {
            LogInfo("[PerformanceMonitor] Embedding: count=\(embeddingStats.count), avg=\(String(format: "%.1f", embeddingStats.mean))ms")
        }
        
        // 缓存
        for layer in ["L0", "L1", "L2"] {
            let hits = await metricsCollector.getCounter("cache.hit", labels: ["layer": layer])
            let misses = await metricsCollector.getCounter("cache.miss", labels: ["layer": layer])
            let total = hits + misses
            if total > 0 {
                let rate = Double(hits) / Double(total) * 100
                LogInfo("[PerformanceMonitor] \(layer) Cache Hit Rate: \(String(format: "%.1f", rate))%")
            }
        }
        
        LogInfo("[PerformanceMonitor] ======================")
    }
    
    func exportReport() async -> String? {
        let snapshot = await metricsCollector.exportMetrics()
        return snapshot.toJSON()
    }
}
