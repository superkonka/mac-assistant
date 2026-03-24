//
//  UnifiedServiceState.swift
//  MacAssistant
//
//  统一服务状态中心 - 解决主会话与服务管理状态不同步问题
//

import Foundation
import Combine

// MARK: - 状态来源
enum StateSource: String, CaseIterable {
    case userAction       // 用户从服务管理入口操作
    case aiOperation      // AI 在主会话或服务管理中操作
    case healthCheck      // 健康检查发现
    case discovery        // 服务发现
    case manual           // 手动刷新
    case autoDetection    // 自动检测（端口扫描等）
    
    var displayName: String {
        switch self {
        case .userAction: return "用户操作"
        case .aiOperation: return "AI 操作"
        case .healthCheck: return "健康检查"
        case .discovery: return "服务发现"
        case .manual: return "手动刷新"
        case .autoDetection: return "自动检测"
        }
    }
}

// MARK: - 统一运行时信息
struct UnifiedServiceRuntimeInfo: Identifiable, Equatable {
    let id: String
    var status: ServiceRuntimeStatus
    var previousStatus: ServiceRuntimeStatus?
    var lastUpdated: Date
    var lastSource: StateSource
    
    // 原有字段兼容
    var pid: Int?
    var port: Int?
    var uptime: TimeInterval?
    var lastStartedAt: Date?
    var errorMessage: String?
    
    // 新增字段
    var metadata: [String: String] = [:]
    var healthHistory: [HealthRecord] = []
    var lastCheckedAt: Date?
    
    // 访问配置
    var internalAccessURL: String?
    var externalAccessURL: String?
    
    init(
        id: String,
        status: ServiceRuntimeStatus = .unknown,
        lastUpdated: Date = Date(),
        lastSource: StateSource = .manual
    ) {
        self.id = id
        self.status = status
        self.lastUpdated = lastUpdated
        self.lastSource = lastSource
    }
    
    // 从原有 ServiceRuntimeInfo 转换
    init(from info: ServiceRuntimeInfo, source: StateSource = .manual) {
        self.id = info.id
        self.status = info.status
        self.lastUpdated = info.lastCheckedAt
        self.lastSource = source
        self.pid = info.pid
        self.port = nil // 从服务定义获取
        self.uptime = info.uptime
        self.lastStartedAt = info.lastStartedAt
        self.errorMessage = info.errorMessage
        self.lastCheckedAt = info.lastCheckedAt
    }
}

// MARK: - 健康记录
struct HealthRecord: Equatable {
    let timestamp: Date
    let status: ServiceRuntimeStatus
    let checkType: String
    let details: String?
    let responseTimeMs: Int?
}

// MARK: - 服务事件
enum ServiceEvent {
    case statusChanged(
        serviceID: String,
        from: ServiceRuntimeStatus?,
        to: ServiceRuntimeStatus,
        source: StateSource,
        timestamp: Date
    )
    case discovered(
        serviceName: String,
        port: Int,
        suggestedID: String
    )
    case healthAlert(
        serviceID: String,
        severity: AlertSeverity,
        message: String
    )
    case accessInfoUpdated(
        serviceID: String,
        internalURL: String?,
        externalURL: String?
    )
}

enum AlertSeverity {
    case info, warning, error, critical
}

// MARK: - 统一服务状态中心
@MainActor
final class UnifiedServiceState: ObservableObject {
    static let shared = UnifiedServiceState()
    
    // MARK: - Published State
    @Published var runtimeInfos: [String: UnifiedServiceRuntimeInfo] = [:]
    @Published var recentEvents: [ServiceEventRecord] = []
    
    // MARK: - Event Bus
    let eventPublisher = PassthroughSubject<ServiceEvent, Never>()
    
    // MARK: - Private
    private var cancellables = Set<AnyCancellable>()
    private let maxRecentEvents = 50
    
    // MARK: - 服务定义缓存（用于名称查找）
    private var serviceNameMap: [String: String] = [:] // name -> id
    
    // MARK: - Initialization
    private init() {
        setupSyncWithServiceManager()
        setupPeriodicReconciliation()
    }
    
    // MARK: - 与 ServiceManager 同步
    private func setupSyncWithServiceManager() {
        let serviceManager = ServiceManager.shared
        
        // 监听 services 变化，更新名称映射
        serviceManager.$services
            .receive(on: RunLoop.main)
            .sink { [weak self] services in
                self?.updateServiceNameMap(services)
                self?.reconcileState()
            }
            .store(in: &cancellables)
        
        // 监听 runtimeInfos 变化
        serviceManager.$runtimeInfos
            .receive(on: RunLoop.main)
            .sink { [weak self] infos in
                self?.syncFromServiceManager(infos)
            }
            .store(in: &cancellables)
    }
    
    /// 更新服务名称映射
    private func updateServiceNameMap(_ services: [ServiceDefinition]) {
        var map: [String: String] = [:]
        for service in services {
            map[service.name] = service.id
            map[service.name.lowercased()] = service.id
            // 支持别名匹配
            let aliases = generateAliases(for: service.name)
            for alias in aliases {
                map[alias] = service.id
                map[alias.lowercased()] = service.id
            }
        }
        serviceNameMap = map
    }
    
    /// 生成服务名称别名
    private func generateAliases(for name: String) -> [String] {
        var aliases: [String] = []
        
        // 移除空格和特殊字符
        let normalized = name.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        aliases.append(normalized)
        
        // 常见变体
        if name.contains("MCP") {
            aliases.append(name.replacingOccurrences(of: "MCP", with: "mcp"))
        }
        
        return aliases
    }
    
    /// 从 ServiceManager 同步状态
    private func syncFromServiceManager(_ infos: [String: ServiceRuntimeInfo]) {
        for (id, info) in infos {
            if var unifiedInfo = runtimeInfos[id] {
                // 更新现有记录
                unifiedInfo.previousStatus = unifiedInfo.status
                unifiedInfo.status = info.status
                unifiedInfo.pid = info.pid
                unifiedInfo.uptime = info.uptime
                unifiedInfo.lastStartedAt = info.lastStartedAt
                unifiedInfo.errorMessage = info.errorMessage
                unifiedInfo.lastCheckedAt = info.lastCheckedAt
                unifiedInfo.lastUpdated = Date()
                runtimeInfos[id] = unifiedInfo
            } else {
                // 创建新记录
                runtimeInfos[id] = UnifiedServiceRuntimeInfo(from: info)
            }
        }
    }
    
    /// 状态协调（确保两边一致）
    private func reconcileState() {
        let serviceManager = ServiceManager.shared
        
        // 1. 确保所有已知服务都有运行时信息
        for service in serviceManager.services {
            if runtimeInfos[service.id] == nil {
                runtimeInfos[service.id] = UnifiedServiceRuntimeInfo(
                    id: service.id,
                    status: .unknown,
                    lastSource: .manual
                )
            }
            
            // 更新端口信息
            if let port = service.port {
                runtimeInfos[service.id]?.port = port
            }
        }
        
        // 2. 清理已删除服务的状态
        let validIDs = Set(serviceManager.services.map { $0.id })
        let currentIDs = Set(runtimeInfos.keys)
        let removedIDs = currentIDs.subtracting(validIDs)
        for id in removedIDs {
            runtimeInfos.removeValue(forKey: id)
        }
    }
    
    /// 定期协调（处理可能的同步遗漏）
    private func setupPeriodicReconciliation() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reconcileState()
            }
        }
    }
    
    // MARK: - 公共 API
    
    /// 统一状态更新入口（所有状态变更都经过这里）
    func updateServiceState(
        serviceID: String,
        status: ServiceRuntimeStatus,
        source: StateSource,
        metadata: [String: String] = [:],
        notify: Bool = true
    ) {
        var info = runtimeInfos[serviceID] ?? UnifiedServiceRuntimeInfo(
            id: serviceID,
            status: status,
            lastSource: source
        )
        
        // 保存历史状态
        if info.status != status {
            info.previousStatus = info.status
            info.status = status
            
            // 记录健康历史
            let record = HealthRecord(
                timestamp: Date(),
                status: status,
                checkType: source.rawValue,
                details: metadata["details"],
                responseTimeMs: Int(metadata["responseTimeMs"] ?? "")
            )
            info.healthHistory.append(record)
            
            // 限制历史记录数量
            if info.healthHistory.count > 20 {
                info.healthHistory.removeFirst(info.healthHistory.count - 20)
            }
        }
        
        info.lastUpdated = Date()
        info.lastSource = source
        
        // 合并元数据
        for (key, value) in metadata {
            info.metadata[key] = value
        }
        
        // 解析 PID
        if let pidStr = metadata["pid"], let pid = Int(pidStr) {
            info.pid = pid
        }
        
        // 解析端口
        if let portStr = metadata["port"], let port = Int(portStr) {
            info.port = port
        }
        
        // 更新访问 URL
        updateAccessURLs(for: &info)
        
        runtimeInfos[serviceID] = info
        
        // 发布事件
        if notify {
            eventPublisher.send(.statusChanged(
                serviceID: serviceID,
                from: info.previousStatus,
                to: status,
                source: source,
                timestamp: Date()
            ))
            
            // 记录事件
            recordEvent(serviceID: serviceID, event: .statusChanged(
                serviceID: serviceID,
                from: info.previousStatus,
                to: status,
                source: source,
                timestamp: Date()
            ))
        }
        
        // 同步回 ServiceManager（保持兼容）
        syncBackToServiceManager(serviceID: serviceID, info: info)
        
        LogInfo("[UnifiedServiceState] 状态更新: \(serviceID) -> \(status.displayName) [来源: \(source.displayName)]")
    }
    
    /// 更新访问 URL
    private func updateAccessURLs(for info: inout UnifiedServiceRuntimeInfo) {
        guard let port = info.port else { return }
        
        // 内部访问
        info.internalAccessURL = "http://127.0.0.1:\(port)"
        
        // 外部访问（需要获取本机 IP）
        if let localIP = NetworkEnvironmentManager.shared.localIPAddress {
            info.externalAccessURL = "http://\(localIP):\(port)"
        }
    }
    
    /// 同步回 ServiceManager
    private func syncBackToServiceManager(serviceID: String, info: UnifiedServiceRuntimeInfo) {
        let serviceManager = ServiceManager.shared
        
        // 转换为原有格式
        let runtimeInfo = ServiceRuntimeInfo(
            id: info.id,
            status: info.status,
            pid: info.pid,
            lastCheckedAt: info.lastUpdated,
            errorMessage: info.errorMessage,
            uptime: info.uptime,
            lastStartedAt: info.lastStartedAt
        )
        
        // 更新 ServiceManager
        serviceManager.updateRuntimeInfo(runtimeInfo)
    }
    
    /// 从主会话接收服务操作结果
    func handleMainSessionOperation(
        serviceName: String,
        operation: ServiceOperation,
        result: String
    ) {
        // 查找服务 ID
        guard let serviceID = findServiceID(byName: serviceName) else {
            LogWarning("[UnifiedServiceState] 未找到服务: \(serviceName)")
            return
        }
        
        // 解析操作结果
        let parser = ServiceStateParser()
        let parsed = parser.parse(result: result, for: serviceName)
        
        // 根据操作类型确定状态
        let status: ServiceRuntimeStatus
        switch operation {
        case .start, .restart:
            status = parsed.isSuccess ? .running : .error
        case .stop:
            status = parsed.isSuccess ? .stopped : .error
        case .check:
            status = parsed.status ?? .unknown
        }
        
        // 更新状态
        updateServiceState(
            serviceID: serviceID,
            status: status,
            source: .aiOperation,
            metadata: [
                "operation": operation.rawValue,
                "pid": parsed.pid?.description ?? "",
                "port": parsed.port?.description ?? "",
                "message": parsed.message ?? "",
                "rawResult": String(result.prefix(500)) // 限制长度
            ]
        )
    }
    
    /// 根据名称查找服务 ID
    func findServiceID(byName name: String) -> String? {
        // 直接匹配
        if let id = serviceNameMap[name] {
            return id
        }
        
        // 模糊匹配
        let normalizedName = name.lowercased()
        for (key, id) in serviceNameMap {
            if key.lowercased().contains(normalizedName) ||
               normalizedName.contains(key.lowercased()) {
                return id
            }
        }
        
        return nil
    }
    
    /// 获取服务状态
    func status(for serviceID: String) -> ServiceRuntimeStatus {
        return runtimeInfos[serviceID]?.status ?? .unknown
    }
    
    /// 获取服务信息
    func info(for serviceID: String) -> UnifiedServiceRuntimeInfo? {
        return runtimeInfos[serviceID]
    }
    
    /// 获取最近事件
    func recentEvents(for serviceID: String? = nil, limit: Int = 10) -> [ServiceEventRecord] {
        var events = recentEvents
        
        if let serviceID = serviceID {
            events = events.filter { $0.serviceID == serviceID }
        }
        
        return Array(events.prefix(limit))
    }
    
    // MARK: - 事件记录
    private func recordEvent(serviceID: String, event: ServiceEvent) {
        let record = ServiceEventRecord(
            id: UUID().uuidString,
            serviceID: serviceID,
            event: event,
            timestamp: Date()
        )
        
        recentEvents.insert(record, at: 0)
        
        // 限制数量
        if recentEvents.count > maxRecentEvents {
            recentEvents.removeLast(recentEvents.count - maxRecentEvents)
        }
    }
}

// MARK: - 服务事件记录
struct ServiceEventRecord: Identifiable {
    let id: String
    let serviceID: String
    let event: ServiceEvent
    let timestamp: Date
}

// MARK: - 服务操作类型
enum ServiceOperation: String {
    case start = "start"
    case stop = "stop"
    case restart = "restart"
    case check = "check"
}

// MARK: - 解析结果
struct ServiceParseResult {
    let isSuccess: Bool
    let status: ServiceRuntimeStatus?
    let pid: Int?
    let port: Int?
    let message: String?
}

// MARK: - 网络环境管理器（简化版）
@MainActor
final class NetworkEnvironmentManager {
    static let shared = NetworkEnvironmentManager()
    
    private var cachedIP: String?
    private var lastIPUpdate: Date?
    
    /// 获取本机局域网 IP（带缓存）
    var localIPAddress: String? {
        // 缓存 60 秒
        if let cached = cachedIP,
           let lastUpdate = lastIPUpdate,
           Date().timeIntervalSince(lastUpdate) < 60 {
            return cached
        }
        
        let ip = getLocalIPAddress()
        cachedIP = ip
        lastIPUpdate = Date()
        return ip
    }
    
    /// 获取本机局域网 IP
    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            let interface = ptr!.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // en0 = Wi-Fi, en1 = 以太网
                if name == "en0" || name == "en1" {
                    var addr = interface.ifa_addr.pointee
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
            ptr = interface.ifa_next
        }
        
        return address
    }
}
