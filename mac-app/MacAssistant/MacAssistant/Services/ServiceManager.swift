//
//  ServiceManager.swift
//  MacAssistant
//
//  UI 入口 - 读取 StateStore 状态，调用 Planner 执行
//

import Foundation
import Combine

/// 服务管理器 - UI 层入口
@MainActor
final class ServiceManager: ObservableObject {
    static let shared = ServiceManager()
    
    // MARK: - 依赖
    
    private let stateStore = ServiceStateStore.shared
    private let planner = ServicePlanner.shared
    
    // MARK: - Published（UI 绑定）
    
    /// 所有服务状态列表
    @Published var services: [ServiceStateSnapshot] = []
    
    /// 是否有活跃操作
    @Published var isOperating = false
    
    /// 当前操作日志（实时显示）
    @Published var operationLogs: [String] = []
    
    /// 运行时信息（兼容旧代码）
    @Published var runtimeInfos: [String: ServiceRuntimeInfo] = [:]
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        // 监听 StateStore 变化
        stateStore.$states
            .map { Array($0.values).sorted { $0.name < $1.name } }
            .assign(to: &$services)
        
        // 监听状态变化通知
        NotificationCenter.default.publisher(for: .serviceStateChanged)
            .sink { [weak self] _ in
                // 可以在这里做额外的 UI 刷新
            }
            .store(in: &cancellables)
    }
    
    // MARK: - UI 调用的方法
    
    /// 启动服务（UI 按钮调用）
    func startService(_ serviceId: String) async {
        guard !planner.hasActiveTask(for: serviceId) else {
            log("\(serviceId) 正在执行其他操作")
            return
        }
        
        isOperating = true
        operationLogs = []
        
        let result = await planner.execute(
            serviceId: serviceId,
            operation: .start
        ) { [weak self] progress in
            self?.log(progress)
        }
        
        log(result.message)
        isOperating = false
    }
    
    /// 停止服务
    func stopService(_ serviceId: String) async {
        guard !planner.hasActiveTask(for: serviceId) else {
            log("\(serviceId) 正在执行其他操作")
            return
        }
        
        isOperating = true
        operationLogs = []
        
        let result = await planner.execute(
            serviceId: serviceId,
            operation: .stop
        ) { [weak self] progress in
            self?.log(progress)
        }
        
        log(result.message)
        isOperating = false
    }
    
    /// 重启服务
    func restartService(_ serviceId: String) async {
        isOperating = true
        operationLogs = []
        
        let result = await planner.execute(
            serviceId: serviceId,
            operation: .restart
        ) { [weak self] progress in
            self?.log(progress)
        }
        
        log(result.message)
        isOperating = false
    }
    
    /// 检查服务状态
    func checkService(_ serviceId: String) async {
        _ = await planner.execute(
            serviceId: serviceId,
            operation: .check
        ) { [weak self] progress in
            self?.log(progress)
        }
    }
    
    /// 批量检查所有服务状态
    func checkAllServices() async {
        for service in services {
            await checkService(service.id)
        }
    }
    
    /// 注册新服务（添加到状态管理）
    func registerService(
        id: String,
        name: String,
        port: Int? = nil,
        preferredAdapter: String? = nil
    ) {
        let snapshot = ServiceStateSnapshot(
            id: id,
            name: name,
            state: .defined,
            adapter: preferredAdapter,
            pid: nil,
            port: port,
            lastError: nil,
            lastOperation: nil,
            lastUpdated: Date(),
            metadata: [:]
        )
        stateStore.updateState(snapshot)
    }
    
    /// 更新运行时信息（兼容旧代码）
    func updateRuntimeInfo(id: String, info: ServiceRuntimeInfo) {
        runtimeInfos[id] = info
    }
    
    // MARK: - 辅助
    
    private func log(_ message: String) {
        operationLogs.append("[\(Date().formatted(date: .omitted, time: .shortened))] \(message)")
    }
}

// MARK: - 预置常用服务

extension ServiceManager {
    
    /// 注册常用服务到状态管理
    func registerCommonServices() {
        let commonServices: [(id: String, name: String, port: Int?, adapter: String?)] = [
            ("postgresql", "PostgreSQL", 5432, "homebrew"),
            ("redis", "Redis", 6379, "homebrew"),
            ("mysql", "MySQL", 3306, "homebrew"),
            ("mongodb", "MongoDB", 27017, "homebrew"),
            ("nginx", "Nginx", 80, "homebrew"),
            ("rabbitmq", "RabbitMQ", 5672, "homebrew"),
        ]
        
        for service in commonServices {
            // 只注册不存在的服务
            if stateStore.state(for: service.id) == nil {
                registerService(
                    id: service.id,
                    name: service.name,
                    port: service.port,
                    preferredAdapter: service.adapter
                )
            }
        }
    }
}
