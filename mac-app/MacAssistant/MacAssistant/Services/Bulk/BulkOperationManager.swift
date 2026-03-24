//
//  BulkOperationManager.swift
//  MacAssistant
//
//  批量操作管理器 - 管理多个服务的批量操作
//

import Foundation

// MARK: - 批量操作类型
enum BulkOperationType: String {
    case start = "start"
    case stop = "stop"
    case restart = "restart"
    case checkStatus = "checkStatus"
    case update = "update"
    case clean = "clean"
    
    var displayName: String {
        switch self {
        case .start: return "启动"
        case .stop: return "停止"
        case .restart: return "重启"
        case .checkStatus: return "检查状态"
        case .update: return "更新"
        case .clean: return "清理"
        }
    }
    
    var icon: String {
        switch self {
        case .start: return "play.fill"
        case .stop: return "stop.fill"
        case .restart: return "arrow.clockwise"
        case .checkStatus: return "checkmark.circle"
        case .update: return "arrow.down.circle"
        case .clean: return "trash"
        }
    }
}

// MARK: - 批量操作配置
struct BulkOperationConfig {
    let type: BulkOperationType
    let targetServices: [String]  // service IDs
    let parallel: Bool            // 是否并行执行
    let stopOnError: Bool         // 错误时停止
    let timeout: TimeInterval     // 每个服务的超时时间
    let delay: TimeInterval       // 服务间延迟
    let confirmRequired: Bool     // 是否需要确认
    let rollbackOnFailure: Bool   // 失败时回滚
}

// MARK: - 操作结果
struct BulkOperationResult {
    let serviceID: String
    let success: Bool
    let message: String
    let duration: TimeInterval
    let timestamp: Date
}

// MARK: - 批量操作状态
enum BulkOperationState {
    case idle
    case preparing
    case executing(progress: Double, current: String)
    case completed(results: [BulkOperationResult])
    case failed(error: String, completed: [BulkOperationResult])
    case cancelling
    
    var isRunning: Bool {
        switch self {
        case .preparing, .executing, .cancelling:
            return true
        default:
            return false
        }
    }
    
    var progress: Double? {
        switch self {
        case .executing(let progress, _):
            return progress
        default:
            return nil
        }
    }
    
    var currentService: String? {
        switch self {
        case .executing(_, let current):
            return current
        default:
            return nil
        }
    }
}

// MARK: - 批量操作管理器
@MainActor
final class BulkOperationManager: ObservableObject {
    static let shared = BulkOperationManager()
    
    // MARK: - Published
    @Published var currentState: BulkOperationState = .idle
    @Published var operationHistory: [BulkOperationRecord] = []
    
    // MARK: - Private
    private var operationTask: Task<Void, Never>?
    private var cancellationToken = false
    
    struct BulkOperationRecord: Identifiable {
        let id = UUID()
        let timestamp: Date
        let type: BulkOperationType
        let targetCount: Int
        let successCount: Int
        let failCount: Int
        let duration: TimeInterval
    }
    
    // MARK: - 执行批量操作
    
    func execute(config: BulkOperationConfig) async {
        // 检查是否需要确认
        if config.confirmRequired {
            // 这里应该调用确认对话框，简化处理
            // 实际应该通过 delegate 或 notification 请求确认
        }
        
        operationTask?.cancel()
        cancellationToken = false
        
        currentState = .preparing
        
        let startTime = Date()
        var results: [BulkOperationResult] = []
        
        let services = config.targetServices.compactMap { id in
            ServiceManager.shared.services.first { $0.id == id }
        }
        
        if services.isEmpty {
            currentState = .failed(error: "没有找到目标服务", completed: [])
            return
        }
        
        LogInfo("[BulkOperationManager] 开始批量操作: \(config.type.displayName), 目标服务: \(services.count)")
        
        if config.parallel {
            // 并行执行
            await executeParallel(services: services, config: config, results: &results)
        } else {
            // 串行执行
            await executeSequential(services: services, config: config, results: &results)
        }
        
        guard !Task.isCancelled && !cancellationToken else {
            currentState = .idle
            return
        }
        
        let duration = Date().timeIntervalSince(startTime)
        let successCount = results.filter { $0.success }.count
        let failCount = results.count - successCount
        
        // 记录历史
        let record = BulkOperationRecord(
            timestamp: Date(),
            type: config.type,
            targetCount: services.count,
            successCount: successCount,
            failCount: failCount,
            duration: duration
        )
        operationHistory.insert(record, at: 0)
        
        // 限制历史记录数量
        if operationHistory.count > 50 {
            operationHistory = Array(operationHistory.prefix(50))
        }
        
        if failCount > 0 {
            currentState = .failed(
                error: "\(failCount) 个服务操作失败",
                completed: results
            )
        } else {
            currentState = .completed(results: results)
        }
        
        LogInfo("[BulkOperationManager] 批量操作完成: 成功 \(successCount), 失败 \(failCount)")
    }
    
    // MARK: - 取消操作
    func cancel() {
        cancellationToken = true
        operationTask?.cancel()
        currentState = .cancelling
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.currentState = .idle
        }
    }
    
    // MARK: - 快捷操作
    
    func startAll() async {
        let config = BulkOperationConfig(
            type: .start,
            targetServices: ServiceManager.shared.services.map(\.id),
            parallel: true,
            stopOnError: false,
            timeout: 60,
            delay: 0,
            confirmRequired: true,
            rollbackOnFailure: false
        )
        await execute(config: config)
    }
    
    func stopAll() async {
        let config = BulkOperationConfig(
            type: .stop,
            targetServices: ServiceManager.shared.services.map(\.id),
            parallel: true,
            stopOnError: false,
            timeout: 30,
            delay: 0,
            confirmRequired: true,
            rollbackOnFailure: false
        )
        await execute(config: config)
    }
    
    func restartAll() async {
        let config = BulkOperationConfig(
            type: .restart,
            targetServices: ServiceManager.shared.services.map(\.id),
            parallel: false,  // 重启需要顺序执行
            stopOnError: false,
            timeout: 120,
            delay: 2,
            confirmRequired: true,
            rollbackOnFailure: false
        )
        await execute(config: config)
    }
    
    func checkAllStatus() async {
        let config = BulkOperationConfig(
            type: .checkStatus,
            targetServices: ServiceManager.shared.services.map(\.id),
            parallel: true,
            stopOnError: false,
            timeout: 30,
            delay: 0,
            confirmRequired: false,
            rollbackOnFailure: false
        )
        await execute(config: config)
    }
    
    // MARK: - 智能批量操作
    
    func smartStart(_ serviceIDs: [String]) async {
        // 按依赖顺序启动服务
        let sortedServices = ServiceDependencyManager.shared.sortByDependencies(serviceIDs)
        
        let config = BulkOperationConfig(
            type: .start,
            targetServices: sortedServices,
            parallel: false,  // 依赖顺序需要串行
            stopOnError: false,
            timeout: 60,
            delay: 1,
            confirmRequired: false,
            rollbackOnFailure: true
        )
        await execute(config: config)
    }
    
    func smartStop(_ serviceIDs: [String]) async {
        // 按依赖反向顺序停止服务
        let sortedServices = ServiceDependencyManager.shared.sortByDependencies(serviceIDs).reversed()
        
        let config = BulkOperationConfig(
            type: .stop,
            targetServices: Array(sortedServices),
            parallel: true,
            stopOnError: false,
            timeout: 30,
            delay: 0,
            confirmRequired: false,
            rollbackOnFailure: false
        )
        await execute(config: config)
    }
    
    // MARK: - 私有方法
    
    private func executeSequential(
        services: [ServiceDefinition],
        config: BulkOperationConfig,
        results: inout [BulkOperationResult]
    ) async {
        for (index, service) in services.enumerated() {
            guard !Task.isCancelled && !cancellationToken else { break }
            
            let progress = Double(index + 1) / Double(services.count)
            currentState = .executing(
                progress: progress,
                current: service.name
            )
            
            let result = await executeOperation(on: service, type: config.type, timeout: config.timeout)
            results.append(result)
            
            if !result.success && config.stopOnError {
                currentState = .failed(
                    error: "服务 \(service.name) 操作失败: \(result.message)",
                    completed: results
                )
                return
            }
            
            if config.delay > 0 && index < services.count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(config.delay * 1_000_000_000))
            }
        }
    }
    
    private func executeParallel(
        services: [ServiceDefinition],
        config: BulkOperationConfig,
        results: inout [BulkOperationResult]
    ) async {
        await withTaskGroup(of: BulkOperationResult.self) { group in
            for service in services {
                guard !Task.isCancelled && !cancellationToken else { break }
                
                group.addTask {
                    await self.executeOperation(on: service, type: config.type, timeout: config.timeout)
                }
            }
            
            var completed = 0
            for await result in group {
                results.append(result)
                completed += 1
                
                let progress = Double(completed) / Double(services.count)
                currentState = .executing(
                    progress: progress,
                    current: "已完成 \(completed)/\(services.count)"
                )
            }
        }
    }
    
    private func executeOperation(
        on service: ServiceDefinition,
        type: BulkOperationType,
        timeout: TimeInterval
    ) async -> BulkOperationResult {
        let startTime = Date()
        var success = false
        var message = ""
        
        switch type {
        case .start:
            success = await startService(service, timeout: timeout)
            message = success ? "启动成功" : "启动失败"
            
        case .stop:
            success = await stopService(service, timeout: timeout)
            message = success ? "停止成功" : "停止失败"
            
        case .restart:
            _ = await stopService(service, timeout: timeout / 2)
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1秒延迟
            success = await startService(service, timeout: timeout / 2)
            message = success ? "重启成功" : "重启失败"
            
        case .checkStatus:
            let status = await checkServiceStatus(service)
            success = true
            message = status
            
        case .update:
            success = await updateService(service, timeout: timeout)
            message = success ? "更新成功" : "更新失败"
            
        case .clean:
            success = await cleanService(service)
            message = success ? "清理成功" : "清理失败"
        }
        
        return BulkOperationResult(
            serviceID: service.id,
            success: success,
            message: message,
            duration: Date().timeIntervalSince(startTime),
            timestamp: Date()
        )
    }
    
    // MARK: - 服务操作实现
    
    private func startService(_ service: ServiceDefinition, timeout: TimeInterval) async -> Bool {
        // 使用 ServiceManager 启动服务
        await MainActor.run {
            ServiceManager.shared.startService(service)
        }
        
        // 等待服务启动并检查结果
        try? await Task.sleep(nanoseconds: UInt64(min(timeout, 5.0) * 1_000_000_000))
        
        let status = await MainActor.run {
            UnifiedServiceState.shared.runtimeInfos[service.id]?.status ?? .unknown
        }
        return status == .running
    }
    
    private func stopService(_ service: ServiceDefinition, timeout: TimeInterval) async -> Bool {
        // 使用 ServiceManager 停止服务
        await MainActor.run {
            ServiceManager.shared.stopService(service)
        }
        
        // 等待服务停止并检查结果
        try? await Task.sleep(nanoseconds: UInt64(min(timeout, 3.0) * 1_000_000_000))
        
        let status = await MainActor.run {
            UnifiedServiceState.shared.runtimeInfos[service.id]?.status ?? .unknown
        }
        return status == .stopped || status == .unknown
    }
    
    private func checkServiceStatus(_ service: ServiceDefinition) async -> String {
        // 触发状态检查
        await MainActor.run {
            ServiceManager.shared.checkServiceStatus(service)
        }
        
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
        
        return await MainActor.run {
            UnifiedServiceState.shared.runtimeInfos[service.id]?.status.displayName ?? "未知"
        }
    }
    
    private func updateService(_ service: ServiceDefinition, timeout: TimeInterval) async -> Bool {
        // 检查是否有更新命令
        guard service.updateCommand != nil else {
            return false
        }
        // 更新功能暂不支持
        return false
    }
    
    private func cleanService(_ service: ServiceDefinition) async -> Bool {
        // 清理临时文件、缓存等
        var success = true
        
        // 清理常见临时目录
        let pathsToClean = [
            "\(service.path ?? "~")/tmp",
            "\(service.path ?? "~")/logs/*.log.old"
        ]
        
        for path in pathsToClean {
            let expanded = path.replacingOccurrences(of: "~", with: NSHomeDirectory())
            let task = Process()
            task.launchPath = "/bin/rm"
            task.arguments = ["-rf", expanded]
            
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                success = false
            }
        }
        
        return success
    }
    
    // MARK: - 工具方法
    
    private func withTimeout<T>(_ timeout: TimeInterval, operation: @escaping () async -> T) async -> T? {
        try? await withThrowingTaskGroup(of: T?.self) { group in
            // 操作任务
            group.addTask {
                let result = await operation()
                return result
            }
            
            // 超时任务
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - 扩展
extension ServiceDefinition {
    /// 获取更新命令（从环境变量或配置中）
    var updateCommand: String? {
        return env?["update_command"]
    }
}
