//
//  ServiceDiscoveryManager.swift
//  MacAssistant
//
//  服务发现管理器
//

import Foundation
import Combine

// MARK: - 服务发现管理器
@MainActor
final class ServiceDiscoveryManager: ObservableObject {
    static let shared = ServiceDiscoveryManager()
    
    // MARK: - 配置
    @Published var discoveryMode: DiscoveryMode = .passive
    @Published var isScanning = false
    @Published var scanProgress: (completed: Int, total: Int) = (0, 0)
    
    // MARK: - 发现的服务
    @Published var discoveredServices: [DiscoveredService] = []
    @Published var pendingConfirmations: [DiscoveredService] = []
    
    // MARK: - 事件流
    let eventPublisher = PassthroughSubject<ServiceDiscoveryEvent, Never>()
    
    // MARK: - Private
    private let portScanner = PortScanner()
    private var scanTask: Task<Void, Never>?
    private var processMonitorTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    
    private let userDefaultsKey = "discovered_services"
    private let ignoredServicesKey = "ignored_discovered_services"
    
    // MARK: - Initialization
    private init() {
        loadPersistedServices()
        setupUnifiedStateSync()
    }
    
    // MARK: - 统一状态同步
    private func setupUnifiedStateSync() {
        // 监听服务状态变化，自动移除已停止的服务
        UnifiedServiceState.shared.eventPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                switch event {
                case .statusChanged(let serviceID, _, let to, _, _):
                    if to == .stopped {
                        // 可选：从发现列表中移除或标记
                        self?.markServiceAsStopped(port: self?.portForServiceID(serviceID))
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }
    
    private func portForServiceID(_ serviceID: String) -> Int? {
        return ServiceManager.shared.services.first { $0.id == serviceID }?.port
    }
    
    private func markServiceAsStopped(port: Int?) {
        guard let port = port else { return }
        if let index = discoveredServices.firstIndex(where: { $0.port == port }) {
            // 更新元数据标记为已停止
            discoveredServices[index].metadata["stopped_at"] = ISO8601DateFormatter().string(from: Date())
        }
    }
    
    // MARK: - 公共 API
    
    /// 手动触发端口扫描
    func scanPorts(config: PortScanConfig = .default) async {
        guard !isScanning else { return }
        
        isScanning = true
        scanProgress = (0, config.endPort - config.startPort)
        
        let startTime = Date()
        
        // 执行扫描
        let results = await portScanner.scanPorts(
            range: config.startPort...config.endPort,
            config: config,
            progressHandler: { [weak self] completed, total in
                Task { @MainActor in
                    self?.scanProgress = (completed, total)
                }
            }
        )
        
        // 处理结果
        let newServices = results.map { result -> DiscoveredService in
            DiscoveredService(
                id: UUID().uuidString,
                name: CommonServicePorts.suggestServiceName(port: result.port, type: result.serviceType),
                port: result.port,
                pid: result.processInfo?.pid,
                processName: result.processInfo?.name,
                serviceType: result.serviceType,
                discoveredAt: Date(),
                discoveryMethod: .portScan,
                confirmedStatus: .pending,
                metadata: [
                    "response_time_ms": String(result.responseTimeMs ?? 0),
                    "process_path": result.processInfo?.path ?? "",
                    "process_user": result.processInfo?.user ?? "",
                    "suggested_id": "discovered-\(result.port)"
                ]
            )
        }
        
        // 过滤已存在的和已忽略的
        let filteredServices = filterNewServices(newServices)
        
        // 添加到发现列表
        for service in filteredServices {
            addDiscoveredService(service)
        }
        
        isScanning = false
        
        let duration = Date().timeIntervalSince(startTime)
        eventPublisher.send(.scanCompleted(
            found: filteredServices.count,
            total: results.count,
            duration: duration
        ))
        
        LogInfo("[ServiceDiscoveryManager] 扫描完成: 发现 \(filteredServices.count) 个新服务，耗时 \(String(format: "%.1f", duration))s")
        
        // 通知主会话有新发现
        if !filteredServices.isEmpty {
            notifyMainSessionOfDiscovery(filteredServices)
        }
    }
    
    /// 快速扫描已知服务端口
    func quickScan() async {
        let results = await portScanner.scanKnownServicePorts()
        
        let newServices = results.compactMap { result -> DiscoveredService? in
            guard result.isOpen else { return nil }
            
            return DiscoveredService(
                id: UUID().uuidString,
                name: CommonServicePorts.suggestServiceName(port: result.port, type: result.serviceType),
                port: result.port,
                pid: result.processInfo?.pid,
                processName: result.processInfo?.name,
                serviceType: result.serviceType,
                discoveredAt: Date(),
                discoveryMethod: .portScan,
                confirmedStatus: .pending,
                metadata: [
                    "response_time_ms": String(result.responseTimeMs ?? 0),
                    "suggested_id": "discovered-\(result.port)"
                ]
            )
        }
        
        let filteredServices = filterNewServices(newServices)
        
        for service in filteredServices {
            addDiscoveredService(service)
        }
        
        if !filteredServices.isEmpty {
            notifyMainSessionOfDiscovery(filteredServices)
        }
    }
    
    /// 停止扫描
    func stopScan() {
        scanTask?.cancel()
        isScanning = false
    }
    
    /// 确认添加服务到管理
    func confirmService(_ service: DiscoveredService, addToManagement: Bool = true) {
        guard let index = discoveredServices.firstIndex(where: { $0.id == service.id }) else {
            return
        }
        
        var updatedService = service
        updatedService.confirmedStatus = addToManagement ? .confirmed : .ignored
        discoveredServices[index] = updatedService
        
        // 从待确认列表移除
        pendingConfirmations.removeAll { $0.id == service.id }
        
        if addToManagement {
            // 添加到 ServiceManager
            let serviceDef = updatedService.toServiceDefinition()
            ServiceManager.shared.addService(serviceDef)
            
            eventPublisher.send(.addedToManagement(service: updatedService))
            
            // 同步到 UnifiedServiceState
            UnifiedServiceState.shared.updateServiceState(
                serviceID: serviceDef.id,
                status: .running,
                source: .discovery,
                metadata: [
                    "port": String(service.port),
                    "pid": service.pid?.description ?? "",
                    "process_name": service.processName ?? ""
                ]
            )
            
            LogInfo("[ServiceDiscoveryManager] 服务已添加到管理: \(service.name)")
        } else {
            // 标记为忽略
            addToIgnored(service.port)
            eventPublisher.send(.ignored(serviceID: service.id))
        }
        
        persistServices()
    }
    
    /// 忽略服务
    func ignoreService(_ service: DiscoveredService) {
        confirmService(service, addToManagement: false)
    }
    
    /// 稍后处理（保留在待确认列表）
    func postponeService(_ service: DiscoveredService) {
        // 不做任何操作，保持在发现列表中
    }
    
    /// 手动添加服务
    func manuallyAddService(port: Int, name: String, serviceType: DiscoveredServiceType) {
        let service = DiscoveredService(
            id: UUID().uuidString,
            name: name,
            port: port,
            pid: nil,
            processName: nil,
            serviceType: serviceType,
            discoveredAt: Date(),
            discoveryMethod: .manualAdd,
            confirmedStatus: .pending,
            metadata: ["suggested_id": "manual-\(port)"]
        )
        
        addDiscoveredService(service)
        persistServices()
    }
    
    /// 清理已停止的服务
    func cleanupStoppedServices() {
        // 检查每个发现的服务是否还在运行
        Task {
            for service in discoveredServices {
                let result = await portScanner.scanPort(service.port, timeout: 1)
                if !result.isOpen && service.confirmedStatus != .ignored {
                    // 服务已停止
                    if let index = discoveredServices.firstIndex(where: { $0.id == service.id }) {
                        discoveredServices[index].metadata["stopped_at"] = ISO8601DateFormatter().string(from: Date())
                    }
                }
            }
        }
    }
    
    /// 获取分组的服务
    func groupedServices() -> [DiscoveredServiceGroup] {
        let grouped = Dictionary(grouping: discoveredServices) { $0.serviceType }
        
        return grouped.map { type, services in
            DiscoveredServiceGroup(type: type, services: services)
        }.sorted { $0.type.displayName < $1.type.displayName }
    }
    
    /// 获取待确认的服务
    func pendingServices() -> [DiscoveredService] {
        return discoveredServices.filter { $0.confirmedStatus == .pending }
    }
    
    // MARK: - 私有方法
    
    private func filterNewServices(_ services: [DiscoveredService]) -> [DiscoveredService] {
        let ignoredPorts = loadIgnoredPorts()
        let managedPorts = Set(ServiceManager.shared.services.compactMap { $0.port })
        let existingPorts = Set(discoveredServices.map { $0.port })
        
        return services.filter { service in
            // 排除已管理的
            guard !managedPorts.contains(service.port) else { return false }
            
            // 排除已发现的
            guard !existingPorts.contains(service.port) else { return false }
            
            // 排除已忽略的
            guard !ignoredPorts.contains(service.port) else { return false }
            
            return true
        }
    }
    
    private func addDiscoveredService(_ service: DiscoveredService) {
        discoveredServices.append(service)
        
        if service.confirmedStatus == .pending {
            pendingConfirmations.append(service)
        }
        
        eventPublisher.send(.discovered(service: service))
    }
    
    private func notifyMainSessionOfDiscovery(_ services: [DiscoveredService]) {
        let serviceList = services.map { "• \($0.name) (端口: \($0.port))" }.joined(separator: "\n")
        
        let notification: [String: Any] = [
            "type": "service_discovered",
            "count": services.count,
            "services": services.map { [
                "id": $0.id,
                "name": $0.name,
                "port": $0.port,
                "type": $0.serviceType.rawValue
            ] },
            "message": "发现 \(services.count) 个新服务:\n\(serviceList)"
        ]
        
        NotificationCenter.default.post(
            name: .serviceDiscovered,
            object: nil,
            userInfo: notification
        )
        
        LogInfo("[ServiceDiscoveryManager] 已通知主会话发现 \(services.count) 个新服务")
    }
    
    // MARK: - 持久化
    
    private func persistServices() {
        if let data = try? JSONEncoder().encode(discoveredServices) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }
    
    private func loadPersistedServices() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let services = try? JSONDecoder().decode([DiscoveredService].self, from: data) else {
            return
        }
        
        // 过滤掉太旧的已停止服务（7天前）
        let cutoffDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        discoveredServices = services.filter { service in
            if let stoppedAtString = service.metadata["stopped_at"],
               let stoppedAt = ISO8601DateFormatter().date(from: stoppedAtString) {
                return stoppedAt > cutoffDate
            }
            return true
        }
        
        pendingConfirmations = discoveredServices.filter { $0.confirmedStatus == .pending }
    }
    
    private func addToIgnored(_ port: Int) {
        var ignored = loadIgnoredPorts()
        ignored.insert(port)
        UserDefaults.standard.set(Array(ignored), forKey: ignoredServicesKey)
    }
    
    private func loadIgnoredPorts() -> Set<Int> {
        let ignored = UserDefaults.standard.array(forKey: ignoredServicesKey) as? [Int] ?? []
        return Set(ignored)
    }
}

// MARK: - 发现模式
enum DiscoveryMode {
    case passive      // 被动：只在用户点击"刷新"时扫描
    case active       // 主动：定期扫描 + 系统通知
    case disabled     // 关闭（默认）
}

// MARK: - 通知名称
extension Notification.Name {
    static let serviceDiscovered = Notification.Name("serviceDiscovered")
}
