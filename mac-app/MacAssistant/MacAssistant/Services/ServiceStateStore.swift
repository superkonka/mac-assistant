//
//  ServiceStateStore.swift
//  MacAssistant
//
//  服务状态的单一数据源，Planner 维护，UI 读取
//

import Foundation
import Combine

/// 服务运行状态
enum ServiceRuntimeState: String, Codable, CaseIterable {
    case defined        // 已定义，未操作
    case checking       // 正在检查状态
    case installing     // 正在安装
    case starting       // 正在启动
    case running        // 运行中
    case stopping       // 正在停止
    case stopped        // 已停止
    case error          // 错误状态
    case notInstalled   // 未安装
}

/// 服务状态快照（存储在 StateStore）
struct ServiceStateSnapshot: Codable, Identifiable, Equatable {
    let id: String              // 服务 ID
    let name: String            // 显示名称
    var state: ServiceRuntimeState
    var adapter: String?        // 当前使用的适配器 (homebrew/docker/native)
    var pid: Int?               // 进程 ID
    var port: Int?              // 监听端口
    var lastError: String?      // 最后错误信息
    var lastOperation: String?  // 最后操作
    var lastUpdated: Date
    var metadata: [String: String] // 扩展信息
    
    var isActive: Bool {
        state == .running || state == .starting || state == .stopping
    }
}

/// 服务状态存储 - Planner 维护，UI 读取
@MainActor
final class ServiceStateStore: ObservableObject {
    static let shared = ServiceStateStore()
    
    /// 所有服务状态（UI 绑定这个）
    @Published private(set) var states: [String: ServiceStateSnapshot] = [:]
    
    /// 持久化存储路径
    private let storagePath: URL
    
    private init() {
        let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storagePath = docs.appendingPathComponent("MacAssistant/service-states.json")
        
        // 加载持久化状态
        loadStates()
    }
    
    // MARK: - 状态查询（UI 调用）
    
    func state(for serviceId: String) -> ServiceStateSnapshot? {
        states[serviceId]
    }
    
    func allStates() -> [ServiceStateSnapshot] {
        Array(states.values).sorted { $0.name < $1.name }
    }
    
    func runningServices() -> [ServiceStateSnapshot] {
        states.values.filter { $0.state == .running }
    }
    
    // MARK: - 状态更新（Planner 调用）
    
    func updateState(_ snapshot: ServiceStateSnapshot) {
        var mutable = snapshot
        mutable.lastUpdated = Date()
        states[snapshot.id] = mutable
        
        // 持久化
        saveStates()
        
        // 通知 Planner 状态变化
        NotificationCenter.default.post(
            name: .serviceStateChanged,
            object: mutable
        )
    }
    
    func updateState(
        id: String,
        state: ServiceRuntimeState? = nil,
        adapter: String? = nil,
        pid: Int? = nil,
        error: String? = nil,
        metadata: [String: String]? = nil
    ) {
        guard var snapshot = states[id] else { return }
        
        if let state = state { snapshot.state = state }
        if let adapter = adapter { snapshot.adapter = adapter }
        if let pid = pid { snapshot.pid = pid }
        if let error = error { snapshot.lastError = error }
        if let metadata = metadata { snapshot.metadata.merge(metadata) { _, new in new } }
        
        updateState(snapshot)
    }
    
    // MARK: - 持久化
    
    private func loadStates() {
        guard FileManager.default.fileExists(atPath: storagePath.path),
              let data = try? Data(contentsOf: storagePath),
              let loaded = try? JSONDecoder().decode([String: ServiceStateSnapshot].self, from: data) else {
            return
        }
        states = loaded
    }
    
    private func saveStates() {
        try? FileManager.default.createDirectory(at: storagePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(states) {
            try? data.write(to: storagePath)
        }
    }
}

// MARK: - ServiceStateSnapshot to ServiceDefinition Conversion
extension ServiceStateSnapshot {
    /// 转换为 ServiceDefinition（用于兼容旧代码）
    func toServiceDefinition() -> ServiceDefinition {
        ServiceDefinition(
            id: id,
            name: name,
            category: .other,
            type: .process,
            description: lastOperation,
            path: nil,
            port: port,
            startCommand: nil,
            stopCommand: nil,
            healthCheck: nil,
            env: nil,
            autoStart: false,
            dependencies: nil
        )
    }
}

extension Notification.Name {
    static let serviceStateChanged = Notification.Name("serviceStateChanged")
}
