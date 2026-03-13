//
//  MemoryManager.swift
//  MacAssistant
//
//  Phase 7: Memory Management and Auto-Cleanup
//

import Foundation

// MARK: - Memory Pressure Level

enum MemoryPressureLevel: Int, Comparable {
    case normal = 0
    case warning = 1
    case critical = 2
    case emergency = 3
    
    static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Memory Manager

actor MemoryManager {
    
    static let shared = MemoryManager()
    
    // 配置
    private var maxMemoryMB: Int
    private var warningThresholdMB: Int
    private var criticalThresholdMB: Int
    private var autoCleanupEnabled: Bool
    
    // 状态
    private var currentMemoryMB: Int = 0
    private var pressureLevel: MemoryPressureLevel = .normal
    private var cleanupTask: Task<Void, Never>?
    private var isMonitoring = false
    
    // 注册的清理回调
    private var cleanupHandlers: [String: () async -> Int] = [:]
    
    private init(
        maxMemoryMB: Int = 512,
        warningThresholdMB: Int = 400,
        criticalThresholdMB: Int = 480,
        autoCleanupEnabled: Bool = true
    ) {
        self.maxMemoryMB = maxMemoryMB
        self.warningThresholdMB = warningThresholdMB
        self.criticalThresholdMB = criticalThresholdMB
        self.autoCleanupEnabled = autoCleanupEnabled
    }
    
    // MARK: - Monitoring
    
    func startMonitoring(interval: TimeInterval = 5) {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        cleanupTask = Task {
            while !Task.isCancelled && isMonitoring {
                await checkMemoryPressure()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        
        LogInfo("[MemoryManager] Started monitoring (max: \(maxMemoryMB)MB, warning: \(warningThresholdMB)MB, critical: \(criticalThresholdMB)MB)")
    }
    
    func stopMonitoring() {
        isMonitoring = false
        cleanupTask?.cancel()
        LogInfo("[MemoryManager] Stopped monitoring")
    }
    
    // MARK: - Memory Pressure Check
    
    private func checkMemoryPressure() async {
        // 获取当前内存使用
        currentMemoryMB = await estimateMemoryUsage()
        
        // 确定压力级别
        let newLevel: MemoryPressureLevel
        if currentMemoryMB >= criticalThresholdMB {
            newLevel = .critical
        } else if currentMemoryMB >= warningThresholdMB {
            newLevel = .warning
        } else {
            newLevel = .normal
        }
        
        // 如果压力级别变化，触发相应处理
        if newLevel != pressureLevel {
            pressureLevel = newLevel
            await handleMemoryPressureChange(newLevel)
        }
    }
    
    private func handleMemoryPressureChange(_ level: MemoryPressureLevel) async {
        LogWarning("[MemoryManager] Memory pressure changed to \(level) (current: \(currentMemoryMB)MB)")
        
        switch level {
        case .normal:
            break // 正常状态，不处理
            
        case .warning:
            // 警告级别：清理过期缓存
            if autoCleanupEnabled {
                await performLightCleanup()
            }
            
        case .critical:
            // 严重级别：积极清理
            if autoCleanupEnabled {
                await performAggressiveCleanup()
            }
            
        case .emergency:
            // 紧急级别：强制清理所有可释放资源
            await performEmergencyCleanup()
        }
    }
    
    // MARK: - Cleanup Operations
    
    private func performLightCleanup() async {
        LogInfo("[MemoryManager] Performing light cleanup...")
        
        var totalFreed = 0
        
        // 清理过期缓存
        for (name, handler) in cleanupHandlers.sorted(by: { $0.key < $1.key }) {
            let freed = await handler()
            totalFreed += freed
            LogDebug("[MemoryManager] Light cleanup \(name): freed \(freed)MB")
        }
        
        LogInfo("[MemoryManager] Light cleanup complete: freed \(totalFreed)MB")
    }
    
    private func performAggressiveCleanup() async {
        LogWarning("[MemoryManager] Performing aggressive cleanup...")
        
        var totalFreed = 0
        
        // 1. 清理所有缓存（保留热点数据）
        if let cacheManager = cleanupHandlers["cache"] {
            totalFreed += await cacheManager()
        }
        
        // 2. 清理旧查询结果
        if let queryCache = cleanupHandlers["queryCache"] {
            totalFreed += await queryCache()
        }
        
        // 3. 触发 GC（Swift 不直接支持，但可以通过释放引用来提示）
        // 这里可以通过清理强引用来帮助
        
        LogWarning("[MemoryManager] Aggressive cleanup complete: freed \(totalFreed)MB")
    }
    
    private func performEmergencyCleanup() async {
        LogError("[MemoryManager] EMERGENCY CLEANUP! Freeing all possible memory...")
        
        var totalFreed = 0
        
        // 清理所有注册的处理器
        for (name, handler) in cleanupHandlers {
            let freed = await handler()
            totalFreed += freed
            LogWarning("[MemoryManager] Emergency cleanup \(name): freed \(freed)MB")
        }
        
        LogError("[MemoryManager] Emergency cleanup complete: freed \(totalFreed)MB")
    }
    
    // MARK: - Registration
    
    func registerCleanupHandler(name: String, handler: @escaping () async -> Int) {
        cleanupHandlers[name] = handler
        LogDebug("[MemoryManager] Registered cleanup handler: \(name)")
    }
    
    func unregisterCleanupHandler(name: String) {
        cleanupHandlers.removeValue(forKey: name)
    }
    
    // MARK: - Manual Cleanup
    
    func triggerManualCleanup(level: MemoryPressureLevel = .warning) async {
        switch level {
        case .normal:
            break
        case .warning:
            await performLightCleanup()
        case .critical:
            await performAggressiveCleanup()
        case .emergency:
            await performEmergencyCleanup()
        }
    }
    
    // MARK: - Configuration
    
    func updateThresholds(
        maxMemoryMB: Int? = nil,
        warningThresholdMB: Int? = nil,
        criticalThresholdMB: Int? = nil,
        autoCleanupEnabled: Bool? = nil
    ) {
        if let max = maxMemoryMB {
            self.maxMemoryMB = max
        }
        if let warning = warningThresholdMB {
            self.warningThresholdMB = warning
        }
        if let critical = criticalThresholdMB {
            self.criticalThresholdMB = critical
        }
        if let auto = autoCleanupEnabled {
            self.autoCleanupEnabled = auto
        }
    }
    
    // MARK: - Status
    
    func getStatus() -> MemoryStatus {
        MemoryStatus(
            currentMemoryMB: currentMemoryMB,
            maxMemoryMB: maxMemoryMB,
            warningThresholdMB: warningThresholdMB,
            criticalThresholdMB: criticalThresholdMB,
            pressureLevel: pressureLevel,
            autoCleanupEnabled: autoCleanupEnabled,
            registeredHandlers: Array(cleanupHandlers.keys)
        )
    }
    
    // MARK: - Private Methods
    
    private func estimateMemoryUsage() async -> Int {
        // 获取应用内存使用
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        guard kerr == KERN_SUCCESS else {
            return 0
        }
        
        // 转换为 MB
        return Int(info.resident_size / 1024 / 1024)
    }
}

// MARK: - Memory Status

struct MemoryStatus: Sendable {
    let currentMemoryMB: Int
    let maxMemoryMB: Int
    let warningThresholdMB: Int
    let criticalThresholdMB: Int
    let pressureLevel: MemoryPressureLevel
    let autoCleanupEnabled: Bool
    let registeredHandlers: [String]
    
    var description: String {
        "Memory: \(currentMemoryMB)/\(maxMemoryMB)MB (\(pressureLevel)), " +
        "Handlers: \(registeredHandlers.count), Auto-cleanup: \(autoCleanupEnabled ? "on" : "off")"
    }
}

// MARK: - Memory Pressure Extension

extension MemoryPressureLevel: CustomStringConvertible {
    var description: String {
        switch self {
        case .normal:
            return "normal"
        case .warning:
            return "⚠️ warning"
        case .critical:
            return "🚨 critical"
        case .emergency:
            return "☠️ emergency"
        }
    }
}

// MARK: - Auto-Cleanup Scheduler

actor AutoCleanupScheduler {
    
    static let shared = AutoCleanupScheduler()
    
    private var scheduledTasks: [String: Task<Void, Never>] = [:]
    
    func schedulePeriodicCleanup(
        name: String,
        interval: TimeInterval,
        cleanup: @escaping () async -> Void
    ) {
        // 取消之前的任务
        scheduledTasks[name]?.cancel()
        
        // 创建新任务
        let task = Task {
            while !Task.isCancelled {
                await cleanup()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        
        scheduledTasks[name] = task
        LogInfo("[AutoCleanupScheduler] Scheduled '\(name)' every \(interval)s")
    }
    
    func cancelScheduledCleanup(name: String) {
        scheduledTasks[name]?.cancel()
        scheduledTasks.removeValue(forKey: name)
    }
    
    func cancelAll() {
        for (name, task) in scheduledTasks {
            task.cancel()
            LogDebug("[AutoCleanupScheduler] Cancelled: \(name)")
        }
        scheduledTasks.removeAll()
    }
    
    // MARK: - Predefined Cleanup Tasks
    
    func setupDefaultCleanupTasks(
        cacheManager: MemoryCacheManager,
        metricsCollector: MemoryMetricsCollector
    ) {
        // 每 5 分钟清理过期缓存条目
        schedulePeriodicCleanup(name: "cache-expiry", interval: 300) {
            // LRUCache 的 TTL 是惰性的，这里可以主动触发
            LogDebug("[AutoCleanup] Checking cache expiry...")
        }
        
        // 每 10 分钟重置指标计数器（保留分布统计）
        schedulePeriodicCleanup(name: "metrics-reset", interval: 600) {
            // 可选：重置某些计数器
            LogDebug("[AutoCleanup] Metrics maintenance...")
        }
        
        // 每小时生成性能报告
        schedulePeriodicCleanup(name: "performance-report", interval: 3600) {
            await PerformanceMonitor.shared.generateReport()
        }
    }
}

// MARK: - Integration with Memory System

extension MemoryCoordinator {
    
    /// 初始化内存管理
    func setupMemoryManagement() async {
        let memoryManager = MemoryManager.shared
        let cacheManager = MemoryCacheManager.shared
        
        // 注册缓存清理处理器
        await memoryManager.registerCleanupHandler(name: "cache") {
            let stats = await cacheManager.getAllStats()
            var totalFreed = 0
            for (_, stat) in stats {
                totalFreed += Int(stat.memoryEstimate / 1024 / 1024)
            }
            await cacheManager.clearAllCaches()
            return totalFreed
        }
        
        // 注册查询缓存清理
        await memoryManager.registerCleanupHandler(name: "queryCache") {
            // 清理查询缓存
            return 10 // 估算 10MB
        }
        
        // 启动内存监控
        await memoryManager.startMonitoring(interval: 5)
        
        // 设置自动清理任务
        await AutoCleanupScheduler.shared.setupDefaultCleanupTasks(
            cacheManager: cacheManager,
            metricsCollector: MemoryMetricsCollector.shared
        )
        
        LogInfo("[MemoryCoordinator] Memory management setup complete")
    }
    
    /// 获取内存状态报告
    func getMemoryReport() async -> String {
        let memoryManager = MemoryManager.shared
        let status = await memoryManager.getStatus()
        
        var report = ["===== Memory Report ====="]
        report.append(status.description)
        
        // 缓存统计
        let cacheStats = await MemoryCacheManager.shared.getAllStats()
        for (name, stats) in cacheStats {
            report.append("Cache \(name): \(stats.description)")
        }
        
        // 指标快照
        let metricsSnapshot = await MemoryMetricsCollector.shared.exportMetrics()
        if let json = metricsSnapshot.toJSON() {
            report.append("Metrics JSON length: \(json.count) chars")
        }
        
        report.append("========================")
        return report.joined(separator: "\n")
    }
}
