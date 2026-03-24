//
//  NetworkAccessManager.swift
//  MacAssistant
//
//  网络访问管理器 - 管理内外网访问配置
//

import Foundation
import Network
import Combine
import AppKit

// MARK: - 网络访问信息
struct NetworkAccessInfo {
    let serviceID: String
    let serviceName: String
    let port: Int
    
    // 内部访问（本机）
    let internalAccess: InternalAccess
    
    // 外部访问（局域网）
    let externalAccess: ExternalAccess?
    
    struct InternalAccess {
        let host: String = "127.0.0.1"
        let url: String
        let isAccessible: Bool = true  // 本机总是可访问
        
        init(port: Int, protocol: String = "http") {
            self.url = "\(`protocol`)://127.0.0.1:\(port)"
        }
    }
    
    struct ExternalAccess {
        let host: String
        let url: String
        let isAccessible: Bool
        let requiresFirewall: Bool
        let requiresAuth: Bool
        let accessibilityIssues: [AccessibilityIssue]
    }
    
    enum AccessibilityIssue {
        case firewallBlocked      // 防火墙阻止
        case localhostOnly        // 仅绑定到 localhost
        case portNotListening     // 端口未监听
        case networkUnreachable   // 网络不可达
        
        var description: String {
            switch self {
            case .firewallBlocked:
                return "防火墙阻止了外部访问"
            case .localhostOnly:
                return "服务仅绑定到 127.0.0.1"
            case .portNotListening:
                return "端口未监听"
            case .networkUnreachable:
                return "网络不可达"
            }
        }
        
        var fixSuggestion: String {
            switch self {
            case .firewallBlocked:
                return "需要在防火墙中添加例外规则"
            case .localhostOnly:
                return "需要修改服务配置，绑定到 0.0.0.0"
            case .portNotListening:
                return "服务可能未启动"
            case .networkUnreachable:
                return "检查网络连接"
            }
        }
    }
}

// MARK: - 网络环境信息
struct NetworkEnvironment {
    let localIP: String?
    let subnetMask: String?
    let gateway: String?
    let isWiFi: Bool
    let interfaceName: String?
    
    var networkRange: String? {
        guard let localIP = localIP, let subnetMask = subnetMask else { return nil }
        return NetworkAccessManager.calculateNetworkRange(ip: localIP, mask: subnetMask)
    }
}

// MARK: - 网络访问管理器
@MainActor
final class NetworkAccessManager: ObservableObject {
    static let shared = NetworkAccessManager()
    
    // MARK: - Published
    @Published var currentEnvironment: NetworkEnvironment?
    @Published var serviceAccessInfos: [String: NetworkAccessInfo] = [:]
    @Published var isChecking = false
    
    // MARK: - Private
    private var monitor: NWPathMonitor?
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupNetworkMonitor()
        setupUnifiedStateSync()
    }
    
    // MARK: - 网络监控
    private func setupNetworkMonitor() {
        monitor = NWPathMonitor()
        monitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handleNetworkChange(path)
            }
        }
        monitor?.start(queue: DispatchQueue.global(qos: .background))
    }
    
    private func handleNetworkChange(_ path: NWPath) {
        // 网络变化时更新环境信息
        updateNetworkEnvironment()
        
        // 重新检查所有服务的外部访问性
        Task {
            await checkAllServicesExternalAccess()
        }
    }
    
    private func updateNetworkEnvironment() {
        let env = getCurrentNetworkEnvironment()
        currentEnvironment = env
        
        LogInfo("[NetworkAccessManager] 网络环境更新: \(env.localIP ?? "unknown")")
    }
    
    // MARK: - 统一状态同步
    private func setupUnifiedStateSync() {
        UnifiedServiceState.shared.eventPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                switch event {
                case .statusChanged(let serviceID, _, let to, _, _):
                    if to == .running {
                        // 服务启动后检查访问性
                        Task {
                            await self?.checkServiceAccess(serviceID: serviceID)
                        }
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 公共 API
    
    /// 检查所有服务的网络访问
    func checkAllServicesExternalAccess() async {
        isChecking = true
        defer { isChecking = false }
        
        for service in ServiceManager.shared.services {
            await checkServiceAccess(serviceID: service.id)
        }
    }
    
    /// 检查指定服务的网络访问
    func checkServiceAccess(serviceID: String) async {
        guard let service = ServiceManager.shared.services.first(where: { $0.id == serviceID }),
              let port = service.port else {
            return
        }
        
        let internalAccess = NetworkAccessInfo.InternalAccess(port: port)
        
        // 检查外部访问
        let externalAccess = await checkExternalAccess(port: port)
        
        let info = NetworkAccessInfo(
            serviceID: serviceID,
            serviceName: service.name,
            port: port,
            internalAccess: internalAccess,
            externalAccess: externalAccess
        )
        
        serviceAccessInfos[serviceID] = info
        
        // 同步到 UnifiedServiceState
        UnifiedServiceState.shared.updateServiceState(
            serviceID: serviceID,
            status: UnifiedServiceState.shared.status(for: serviceID),
            source: .autoDetection,
            metadata: [
                "internal_url": internalAccess.url,
                "external_url": externalAccess?.url ?? "",
                "external_accessible": externalAccess?.isAccessible.description ?? "false"
            ],
            notify: false
        )
    }
    
    /// 获取服务的访问信息
    func accessInfo(for serviceID: String) -> NetworkAccessInfo? {
        return serviceAccessInfos[serviceID]
    }
    
    /// 获取访问 URL（优先外部，其次内部）
    func accessibleURL(for serviceID: String) -> String? {
        guard let info = serviceAccessInfos[serviceID] else { return nil }
        
        // 如果外部可访问，返回外部 URL
        if let external = info.externalAccess, external.isAccessible {
            return external.url
        }
        
        // 否则返回内部 URL
        return info.internalAccess.url
    }
    
    /// 修复外部访问问题
    func fixExternalAccess(for serviceID: String) async -> FixResult {
        guard let info = serviceAccessInfos[serviceID],
              let issues = info.externalAccess?.accessibilityIssues else {
            return .noIssues
        }
        
        var fixedIssues: [NetworkAccessInfo.AccessibilityIssue] = []
        var failedIssues: [(issue: NetworkAccessInfo.AccessibilityIssue, error: String)] = []
        
        for issue in issues {
            switch issue {
            case .firewallBlocked:
                // 尝试添加防火墙规则
                let result = await FirewallManager.shared.addRule(port: info.port)
                if result {
                    fixedIssues.append(issue)
                } else {
                    failedIssues.append((issue, "需要管理员权限"))
                }
                
            case .localhostOnly:
                // 提示用户修改配置
                failedIssues.append((issue, "需要手动修改服务配置"))
                
            case .portNotListening:
                // 服务未启动，无法修复
                failedIssues.append((issue, "服务未启动"))
                
            case .networkUnreachable:
                // 网络问题，无法修复
                failedIssues.append((issue, "网络连接问题"))
            }
        }
        
        // 重新检查
        await checkServiceAccess(serviceID: serviceID)
        
        if failedIssues.isEmpty {
            return .fixed(issues: fixedIssues)
        } else if fixedIssues.isEmpty {
            return .failed(errors: failedIssues.map { ($0.issue, $0.error) })
        } else {
            return .partial(fixed: fixedIssues, failed: failedIssues.map { ($0.issue, $0.error) })
        }
    }
    
    /// 复制访问 URL 到剪贴板
    func copyAccessURL(for serviceID: String, preferExternal: Bool = false) {
        guard let info = serviceAccessInfos[serviceID] else { return }
        
        let url: String
        if preferExternal, let external = info.externalAccess, external.isAccessible {
            url = external.url
        } else {
            url = info.internalAccess.url
        }
        
        // 复制到剪贴板
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    
    // MARK: - 私有方法
    
    private func checkExternalAccess(port: Int) async -> NetworkAccessInfo.ExternalAccess? {
        guard let localIP = currentEnvironment?.localIP else {
            return nil
        }
        
        var issues: [NetworkAccessInfo.AccessibilityIssue] = []
        var isAccessible = false
        var requiresFirewall = false
        
        // 1. 检查防火墙
        let firewallStatus = await FirewallManager.shared.checkPortStatus(port: port)
        if firewallStatus == .blocked {
            issues.append(.firewallBlocked)
            requiresFirewall = true
        }
        
        // 2. 检查端口监听
        let isListening = await checkPortListening(port: port)
        if !isListening {
            issues.append(.portNotListening)
        }
        
        // 3. 检查绑定地址
        let bindStatus = await checkBindAddress(port: port)
        if bindStatus == .localhostOnly {
            issues.append(.localhostOnly)
        }
        
        // 4. 综合判断是否可访问
        if isListening && bindStatus != .localhostOnly && firewallStatus != .blocked {
            isAccessible = true
        }
        
        return NetworkAccessInfo.ExternalAccess(
            host: localIP,
            url: "http://\(localIP):\(port)",
            isAccessible: isAccessible,
            requiresFirewall: requiresFirewall,
            requiresAuth: false,  // 默认不需要认证
            accessibilityIssues: issues
        )
    }
    
    private func checkPortListening(port: Int) async -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/nc"
        task.arguments = ["-z", "127.0.0.1", String(port)]
        
        return await withCheckedContinuation { continuation in
            task.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }
            
            do {
                try task.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
    
    private func checkBindAddress(port: Int) async -> BindStatus {
        // 使用 lsof 检查绑定地址
        let task = Process()
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = ["-i", ":\(port)", "-n", "-P"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        return await withCheckedContinuation { continuation in
            task.terminationHandler = { process in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                
                // 检查是否绑定到 * 或 0.0.0.0
                if output.contains("*:\(port)") || output.contains("0.0.0.0:\(port)") {
                    continuation.resume(returning: .allInterfaces)
                } else if output.contains("127.0.0.1:\(port)") {
                    continuation.resume(returning: .localhostOnly)
                } else {
                    continuation.resume(returning: .unknown)
                }
            }
            
            do {
                try task.run()
            } catch {
                continuation.resume(returning: .unknown)
            }
        }
    }
    
    private func getCurrentNetworkEnvironment() -> NetworkEnvironment {
        // 获取网络接口信息
        var localIP: String?
        var subnetMask: String?
        var isWiFi = false
        var interfaceName: String?
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            return NetworkEnvironment(localIP: nil, subnetMask: nil, gateway: nil, isWiFi: false, interfaceName: nil)
        }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            let interface = ptr!.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                
                // 优先使用 Wi-Fi (en0) 或以太网 (en1)
                if name == "en0" || name == "en1" {
                    var addr = interface.ifa_addr.pointee
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST)
                    localIP = String(cString: hostname)
                    
                    // 获取子网掩码
                    if let netmask = interface.ifa_netmask {
                        var maskname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(netmask, socklen_t(netmask.pointee.sa_len),
                                   &maskname, socklen_t(maskname.count),
                                   nil, 0, NI_NUMERICHOST)
                        subnetMask = String(cString: maskname)
                    }
                    
                    isWiFi = (name == "en0")
                    interfaceName = name
                    break
                }
            }
            ptr = interface.ifa_next
        }
        
        return NetworkEnvironment(
            localIP: localIP,
            subnetMask: subnetMask,
            gateway: nil,
            isWiFi: isWiFi,
            interfaceName: interfaceName
        )
    }
    
    nonisolated static func calculateNetworkRange(ip: String, mask: String) -> String? {
        // 简化实现：返回 IP 的前三段
        let parts = ip.components(separatedBy: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2]).0/24"
    }
}

// MARK: - 绑定状态
enum BindStatus {
    case localhostOnly    // 仅绑定到 127.0.0.1
    case allInterfaces    // 绑定到 * 或 0.0.0.0
    case unknown         // 未知
}

// MARK: - 修复结果
enum FixResult {
    case noIssues
    case fixed(issues: [NetworkAccessInfo.AccessibilityIssue])
    case partial(fixed: [NetworkAccessInfo.AccessibilityIssue], failed: [(issue: NetworkAccessInfo.AccessibilityIssue, error: String)])
    case failed(errors: [(issue: NetworkAccessInfo.AccessibilityIssue, error: String)])
    
    var isSuccess: Bool {
        switch self {
        case .noIssues, .fixed:
            return true
        default:
            return false
        }
    }
    
    var message: String {
        switch self {
        case .noIssues:
            return "没有问题需要修复"
        case .fixed(let issues):
            return "已修复 \(issues.count) 个问题"
        case .partial(let fixed, let failed):
            return "已修复 \(fixed.count) 个问题，\(failed.count) 个问题需要手动处理"
        case .failed:
            return "修复失败"
        }
    }
}

// MARK: - 防火墙管理器
@MainActor
final class FirewallManager: ObservableObject {
    static let shared = FirewallManager()
    
    /// 检查端口防火墙状态
    func checkPortStatus(port: Int) async -> FirewallStatus {
        // 使用 socketfilterfw 检查
        let task = Process()
        task.launchPath = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        task.arguments = ["--getglobalstate"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        return await withCheckedContinuation { continuation in
            task.terminationHandler = { process in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                
                // 防火墙是否启用
                let isEnabled = output.contains("enabled")
                
                if !isEnabled {
                    // 防火墙未启用，端口可访问
                    continuation.resume(returning: .allowed)
                    return
                }
                
                // 防火墙启用，需要检查具体规则
                // 简化处理：假设需要添加规则
                continuation.resume(returning: .blocked)
            }
            
            do {
                try task.run()
            } catch {
                continuation.resume(returning: .unknown)
            }
        }
    }
    
    /// 添加防火墙规则
    func addRule(port: Int) async -> Bool {
        // 注意：这需要管理员权限
        let task = Process()
        task.launchPath = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        task.arguments = ["--add", String(port)]
        
        return await withCheckedContinuation { continuation in
            task.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }
            
            do {
                try task.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
    
    /// 移除防火墙规则
    func removeRule(port: Int) async -> Bool {
        let task = Process()
        task.launchPath = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        task.arguments = ["--remove", String(port)]
        
        return await withCheckedContinuation { continuation in
            task.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }
            
            do {
                try task.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}

// MARK: - 防火墙状态
enum FirewallStatus {
    case allowed      // 允许访问
    case blocked      // 被阻止
    case unknown      // 未知
}
