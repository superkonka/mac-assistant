//
//  ServiceDependencyManager.swift
//  MacAssistant
//
//  服务依赖管理器 - 管理服务之间的依赖关系
//

import Foundation

// MARK: - 依赖关系
struct ServiceDependency: Identifiable, Codable, Equatable {
    let id: String
    let serviceID: String          // 主服务
    let dependsOnServiceID: String // 依赖的服务
    let isRequired: Bool           // 是否必需
    let autoStart: Bool            // 是否自动启动依赖
    let startupDelay: TimeInterval // 依赖启动后的延迟时间
    
    init(
        serviceID: String,
        dependsOnServiceID: String,
        isRequired: Bool = true,
        autoStart: Bool = true,
        startupDelay: TimeInterval = 2
    ) {
        self.id = "\(serviceID)->\(dependsOnServiceID)"
        self.serviceID = serviceID
        self.dependsOnServiceID = dependsOnServiceID
        self.isRequired = isRequired
        self.autoStart = autoStart
        self.startupDelay = startupDelay
    }
}

// MARK: - 依赖图
class DependencyGraph {
    private var adjacencyList: [String: [String]] = [:]  // serviceID -> [dependsOnServiceIDs]
    
    func addDependency(from serviceID: String, to dependsOnID: String) {
        if adjacencyList[serviceID] == nil {
            adjacencyList[serviceID] = []
        }
        if !adjacencyList[serviceID]!.contains(dependsOnID) {
            adjacencyList[serviceID]!.append(dependsOnID)
        }
    }
    
    func removeDependency(from serviceID: String, to dependsOnID: String) {
        adjacencyList[serviceID]?.removeAll { $0 == dependsOnID }
    }
    
    func dependencies(of serviceID: String) -> [String] {
        return adjacencyList[serviceID] ?? []
    }
    
    func dependents(of serviceID: String) -> [String] {
        return adjacencyList.filter { $0.value.contains(serviceID) }.map { $0.key }
    }
    
    /// 拓扑排序获取启动顺序
    func topologicalSort(startingFrom serviceID: String) -> [String] {
        var visited: Set<String> = []
        var result: [String] = []
        
        func dfs(_ id: String) {
            guard !visited.contains(id) else { return }
            visited.insert(id)
            
            // 先访问依赖
            for dependency in dependencies(of: id) {
                dfs(dependency)
            }
            
            result.append(id)
        }
        
        dfs(serviceID)
        return result
    }
    
    /// 检测循环依赖
    func detectCycles() -> [[String]] {
        var cycles: [[String]] = []
        var visited: Set<String> = []
        var recursionStack: [String] = []
        
        func dfs(_ id: String, path: [String]) {
            if let index = path.firstIndex(of: id) {
                // 发现循环
                cycles.append(Array(path[index...]) + [id])
                return
            }
            
            guard !visited.contains(id) else { return }
            visited.insert(id)
            
            for dependency in dependencies(of: id) {
                dfs(dependency, path: path + [id])
            }
        }
        
        for serviceID in adjacencyList.keys {
            dfs(serviceID, path: [])
        }
        
        return cycles
    }
}

// MARK: - 服务依赖管理器
@MainActor
final class ServiceDependencyManager: ObservableObject {
    static let shared = ServiceDependencyManager()
    
    // MARK: - Published
    @Published var dependencies: [ServiceDependency] = []
    @Published var isResolving = false
    @Published var resolutionLog: [DependencyResolutionLog] = []
    
    // MARK: - Private
    private var graph = DependencyGraph()
    private let userDefaultsKey = "service_dependencies"
    
    private init() {
        loadDependencies()
        buildGraph()
    }
    
    // MARK: - 依赖管理
    
    /// 添加依赖关系
    func addDependency(_ dependency: ServiceDependency) -> Result<Void, DependencyError> {
        // 检查是否已存在
        guard !dependencies.contains(where: { $0.id == dependency.id }) else {
            return .failure(.alreadyExists)
        }
        
        // 检查循环依赖
        graph.addDependency(from: dependency.serviceID, to: dependency.dependsOnServiceID)
        let cycles = graph.detectCycles()
        
        if !cycles.isEmpty {
            // 回滚
            graph.removeDependency(from: dependency.serviceID, to: dependency.dependsOnServiceID)
            return .failure(.circularDependency(cycles: cycles))
        }
        
        dependencies.append(dependency)
        persistDependencies()
        
        LogInfo("[ServiceDependencyManager] 添加依赖: \(dependency.serviceID) -> \(dependency.dependsOnServiceID)")
        
        return .success(())
    }
    
    /// 移除依赖关系
    func removeDependency(from serviceID: String, to dependsOnID: String) {
        dependencies.removeAll { $0.serviceID == serviceID && $0.dependsOnServiceID == dependsOnID }
        graph.removeDependency(from: serviceID, to: dependsOnID)
        persistDependencies()
        
        LogInfo("[ServiceDependencyManager] 移除依赖: \(serviceID) -> \(dependsOnID)")
    }
    
    /// 获取服务的依赖
    func getDependencies(of serviceID: String) -> [ServiceDependency] {
        return dependencies.filter { $0.serviceID == serviceID }
    }
    
    /// 获取依赖该服务的其他服务
    func getDependents(of serviceID: String) -> [ServiceDependency] {
        return dependencies.filter { $0.dependsOnServiceID == serviceID }
    }
    
    /// 检查服务是否有依赖
    func hasDependencies(_ serviceID: String) -> Bool {
        return dependencies.contains { $0.serviceID == serviceID }
    }
    
    /// 检查服务是否被依赖
    func isDepended(by serviceID: String) -> Bool {
        return dependencies.contains { $0.dependsOnServiceID == serviceID }
    }
    
    /// 按依赖顺序排序服务 ID
    func sortByDependencies(_ serviceIDs: [String]) -> [String] {
        // 构建临时图
        let tempGraph = DependencyGraph()
        for id in serviceIDs {
            // 添加所有依赖关系到图中
            for dep in getDependencies(of: id) {
                if serviceIDs.contains(dep.dependsOnServiceID) {
                    tempGraph.addDependency(from: id, to: dep.dependsOnServiceID)
                }
            }
        }
        
        // 如果没有指定起始点，添加所有服务作为起点
        var result: [String] = []
        var visited: Set<String> = []
        
        func dfs(_ id: String) {
            guard !visited.contains(id) else { return }
            visited.insert(id)
            
            for dependency in tempGraph.dependencies(of: id) {
                dfs(dependency)
            }
            
            result.append(id)
        }
        
        for id in serviceIDs {
            dfs(id)
        }
        
        return result
    }
    
    // MARK: - 依赖解析和启动
    
    /// 解析并启动服务及其依赖
    func resolveAndStart(serviceID: String) async -> DependencyResolutionResult {
        isResolving = true
        resolutionLog.removeAll()
        
        defer { isResolving = false }
        
        // 获取启动顺序
        let startupOrder = graph.topologicalSort(startingFrom: serviceID)
        
        var startedServices: [String] = []
        var failedServices: [(serviceID: String, error: String)] = []
        
        for id in startupOrder {
            guard let service = ServiceManager.shared.services.first(where: { $0.id == id }) else {
                log(.error, serviceID: id, message: "服务不存在")
                failedServices.append((id, "服务不存在"))
                continue
            }
            
            // 检查当前状态
            let status = ServiceManager.shared.status(for: id)
            
            if status == .running {
                log(.info, serviceID: id, message: "服务已在运行中")
                startedServices.append(id)
                continue
            }
            
            // 检查依赖是否满足
            let serviceDependencies = getDependencies(of: id)
            let unmetDependencies = serviceDependencies.filter { dep in
                ServiceManager.shared.status(for: dep.dependsOnServiceID) != .running
            }
            
            if !unmetDependencies.isEmpty {
                let requiredUnmet = unmetDependencies.filter { $0.isRequired }
                if !requiredUnmet.isEmpty {
                    let missingNames = requiredUnmet.compactMap { dep in
                        ServiceManager.shared.services.first { $0.id == dep.dependsOnServiceID }?.name
                    }.joined(separator: ", ")
                    
                    log(.error, serviceID: id, message: "缺少必需依赖: \(missingNames)")
                    failedServices.append((id, "缺少依赖: \(missingNames)"))
                    continue
                }
            }
            
            // 启动服务
            log(.info, serviceID: id, message: "正在启动 \(service.name)...")
            
            ServiceManager.shared.startService(service)
            
            // 等待服务启动
            let didStart = await waitForServiceToStart(serviceID: id, timeout: 30)
            
            if didStart {
                log(.success, serviceID: id, message: "\(service.name) 启动成功")
                startedServices.append(id)
                
                // 如果有依赖，等待延迟时间
                if let dep = serviceDependencies.first(where: { $0.dependsOnServiceID == id }) {
                    log(.info, serviceID: id, message: "等待 \(dep.startupDelay) 秒...")
                    try? await Task.sleep(nanoseconds: UInt64(dep.startupDelay * 1_000_000_000))
                }
            } else {
                log(.error, serviceID: id, message: "\(service.name) 启动超时")
                failedServices.append((id, "启动超时"))
            }
        }
        
        return DependencyResolutionResult(
            targetServiceID: serviceID,
            startupOrder: startupOrder,
            startedServices: startedServices,
            failedServices: failedServices,
            success: failedServices.isEmpty
        )
    }
    
    /// 停止服务及其依赖（反向）
    func stopWithDependents(serviceID: String) {
        let startupOrder = graph.topologicalSort(startingFrom: serviceID)
        let stopOrder = startupOrder.reversed()
        
        for id in stopOrder {
            guard let service = ServiceManager.shared.services.first(where: { $0.id == id }) else { continue }
            
            let status = ServiceManager.shared.status(for: id)
            if status == .running {
                log(.info, serviceID: id, message: "正在停止 \(service.name)...")
                ServiceManager.shared.stopService(service)
            }
        }
    }
    
    /// 检查是否可以安全停止服务（检查是否有依赖它的服务正在运行）
    func canSafelyStop(serviceID: String) -> (canStop: Bool, blockingServices: [String]) {
        let dependents = getDependents(of: serviceID)
        let runningDependents = dependents.filter { dep in
            ServiceManager.shared.status(for: dep.serviceID) == .running
        }
        
        let blockingNames = runningDependents.compactMap { dep in
            ServiceManager.shared.services.first { $0.id == dep.serviceID }?.name
        }
        
        return (runningDependents.isEmpty, blockingNames)
    }
    
    // MARK: - 私有方法
    
    private func waitForServiceToStart(serviceID: String, timeout: TimeInterval) async -> Bool {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            if ServiceManager.shared.status(for: serviceID) == .running {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 秒检查一次
        }
        
        return false
    }
    
    private func log(_ level: DependencyLogLevel, serviceID: String, message: String) {
        let entry = DependencyResolutionLog(
            timestamp: Date(),
            level: level,
            serviceID: serviceID,
            message: message
        )
        resolutionLog.append(entry)
        
        LogInfo("[ServiceDependencyManager] [\(level.rawValue)] \(message)")
    }
    
    private func buildGraph() {
        graph = DependencyGraph()
        for dep in dependencies {
            graph.addDependency(from: dep.serviceID, to: dep.dependsOnServiceID)
        }
    }
    
    // MARK: - 持久化
    
    private func persistDependencies() {
        if let data = try? JSONEncoder().encode(dependencies) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }
    
    private func loadDependencies() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let deps = try? JSONDecoder().decode([ServiceDependency].self, from: data) else {
            return
        }
        dependencies = deps
    }
}

// MARK: - 依赖解析结果
struct DependencyResolutionResult {
    let targetServiceID: String
    let startupOrder: [String]
    let startedServices: [String]
    let failedServices: [(serviceID: String, error: String)]
    let success: Bool
    
    var summary: String {
        if success {
            return "成功启动 \(startedServices.count) 个服务"
        } else {
            return "启动 \(startedServices.count) 个服务，失败 \(failedServices.count) 个"
        }
    }
}

// MARK: - 日志级别
enum DependencyLogLevel: String {
    case info = "INFO"
    case success = "SUCCESS"
    case warning = "WARNING"
    case error = "ERROR"
}

// MARK: - 依赖解析日志
struct DependencyResolutionLog: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: DependencyLogLevel
    let serviceID: String
    let message: String
    
    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

// MARK: - ServiceDefinition 扩展
@MainActor
extension ServiceDefinition {
    /// 获取依赖该服务的其他服务
    var dependents: [ServiceDefinition] {
        get async {
            let dependentIDs = await ServiceDependencyManager.shared.getDependents(of: id).map { $0.serviceID }
            return await ServiceManager.shared.services.filter { dependentIDs.contains($0.id) }
        }
    }
    
    /// 获取该服务依赖的其他服务
    var dependencyServices: [ServiceDefinition] {
        get async {
            let dependencyIDs = await ServiceDependencyManager.shared.getDependencies(of: id).map { $0.dependsOnServiceID }
            return await ServiceManager.shared.services.filter { dependencyIDs.contains($0.id) }
        }
    }
    
    /// 是否可以安全停止
    var canSafelyStop: Bool {
        get async {
            await ServiceDependencyManager.shared.canSafelyStop(serviceID: id).canStop
        }
    }
}
