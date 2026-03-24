//
//  ServiceManager.swift
//  MacAssistant
//
//  服务管理器 - 管理服务配置和状态
//

import Foundation
import Combine

@MainActor
final class ServiceManager: ObservableObject {
    static let shared = ServiceManager()
    
    // MARK: - Published State
    @Published var services: [ServiceDefinition] = []
    @Published var runtimeInfos: [String: ServiceRuntimeInfo] = [:]
    @Published var isLoading = false
    @Published var selectedCategory: ServiceDefinition.ServiceCategory?
    
    // MARK: - Private
    private var checkTimer: Timer?
    private let checkInterval: TimeInterval = 30  // 30秒检查一次
    
    // MARK: - Initialization
    private init() {
        Task {
            await loadConfiguration()
            await checkAllServicesStatus()
            startPeriodicCheck()
        }
    }
    
    // MARK: - Configuration
    
    /// 加载服务配置
    func loadConfiguration() async {
        isLoading = true
        defer { isLoading = false }
        
        let workspaceConfigPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("workspace/service-management/services.json")
            .path
        
        if FileManager.default.fileExists(atPath: workspaceConfigPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: workspaceConfigPath))
                let decoder = JSONDecoder()
                let config = try decoder.decode(ServicesConfiguration.self, from: data)
                
                await MainActor.run {
                    self.services = config.services
                }
                
                LogInfo("[ServiceManager] 从 \(workspaceConfigPath) 加载了 \(config.services.count) 个服务配置")
                return
            } catch {
                LogError("[ServiceManager] 加载配置失败: \(error)")
            }
        }
        
        await MainActor.run {
            self.services = Self.defaultServices
        }
        LogInfo("[ServiceManager] 使用默认服务配置")
    }
    
    // MARK: - 服务操作（委托给 ServiceTaskManager）
    
    /// 启动服务
    func startService(_ service: ServiceDefinition) {
        ServiceTaskManager.shared.startService(service)
    }
    
    /// 停止服务
    func stopService(_ service: ServiceDefinition) {
        ServiceTaskManager.shared.stopService(service)
    }
    
    /// 重启服务
    func restartService(_ service: ServiceDefinition) {
        ServiceTaskManager.shared.restartService(service)
    }
    
    /// 检查服务状态
    func checkServiceStatus(_ service: ServiceDefinition) {
        ServiceTaskManager.shared.checkServiceStatus(service)
    }
    
    // MARK: - AI 结果处理
    
    /// 处理 AI 操作结果
    func handleAIOperationResult(_ result: ServiceAIOperationResult) {
        var info = runtimeInfos[result.serviceId] ?? ServiceRuntimeInfo(
            id: result.serviceId,
            status: result.status,
            lastCheckedAt: Date()
        )
        
        info.status = result.status
        info.lastCheckedAt = Date()
        
        if let pid = result.pid {
            info.pid = pid
        }
        
        if result.status == .running {
            if info.lastStartedAt == nil {
                info.lastStartedAt = Date()
            }
            if let startTime = info.lastStartedAt {
                info.uptime = Date().timeIntervalSince(startTime)
            }
        } else if result.status == .stopped {
            info.pid = nil
            info.uptime = nil
            info.lastStartedAt = nil
        }
        
        if let error = result.error {
            info.errorMessage = error
        }
        
        runtimeInfos[result.serviceId] = info
        
        LogInfo("[ServiceManager] 服务状态更新: \(result.serviceId) -> \(result.status)")
    }
    
    // MARK: - 本地状态检查（轻量级）
    
    /// 启动定期检查
    private func startPeriodicCheck() {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkAllServicesStatus()
            }
        }
    }
    
    /// 检查所有服务状态
    func checkAllServicesStatus() async {
        for service in services {
            // 跳过正在进行任务的服务
            guard !ServiceTaskManager.shared.hasActiveTask(for: service.id) else { continue }
            await checkServiceStatusInternal(service)
        }
    }
    
    /// 本地检查单个服务状态
    private func checkServiceStatusInternal(_ service: ServiceDefinition) async {
        let healthCheck = service.healthCheck
        
        var isRunning = false
        
        switch healthCheck?.type {
        case .http:
            if let port = service.port {
                isRunning = await checkPortIsOpen(port: port)
            }
        case .port:
            if let port = service.port {
                isRunning = await checkPortIsOpen(port: port)
            }
        case .process:
            if let command = service.startCommand {
                isRunning = await checkProcessRunning(command: command)
            }
        default:
            break
        }
        
        var info = runtimeInfos[service.id]
        let currentStatus = info?.status
        
        if isRunning && currentStatus != .running && currentStatus != .starting {
            info?.status = .running
            info?.lastCheckedAt = Date()
            if let startTime = info?.lastStartedAt {
                info?.uptime = Date().timeIntervalSince(startTime)
            }
            runtimeInfos[service.id] = info
        } else if !isRunning && currentStatus != .stopped && currentStatus != .stopping && currentStatus != .starting {
            info?.status = .stopped
            info?.pid = nil
            info?.uptime = nil
            info?.lastCheckedAt = Date()
            runtimeInfos[service.id] = info
        }
    }
    
    // MARK: - 本地检查辅助方法
    
    private func checkPortIsOpen(port: Int) async -> Bool {
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
    
    private func checkProcessRunning(command: String) async -> Bool {
        let processName = command.components(separatedBy: " ").first ?? command
        
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", processName]
        
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
    
    // MARK: - 状态同步（供 UnifiedServiceState 调用）
    
    /// 更新运行时信息（从 UnifiedServiceState 同步回来）
    func updateRuntimeInfo(_ info: ServiceRuntimeInfo) {
        var existing = runtimeInfos[info.id]
        
        if existing == nil {
            existing = ServiceRuntimeInfo(
                id: info.id,
                status: info.status,
                pid: info.pid,
                lastCheckedAt: info.lastCheckedAt,
                errorMessage: info.errorMessage,
                uptime: info.uptime,
                lastStartedAt: info.lastStartedAt
            )
        } else {
            // 合并更新，保留原有字段
            existing?.status = info.status
            if let pid = info.pid {
                existing?.pid = pid
            }
            existing?.lastCheckedAt = info.lastCheckedAt
            if let error = info.errorMessage {
                existing?.errorMessage = error
            }
            if let uptime = info.uptime {
                existing?.uptime = uptime
            }
            if let lastStarted = info.lastStartedAt {
                existing?.lastStartedAt = lastStarted
            }
        }
        
        runtimeInfos[info.id] = existing
        
        LogInfo("[ServiceManager] 同步状态更新: \(info.id) -> \(info.status.displayName)")
    }
    
    /// 添加新服务（供服务发现使用）
    func addService(_ service: ServiceDefinition) {
        // 检查是否已存在
        guard !services.contains(where: { $0.id == service.id }) else {
            LogWarning("[ServiceManager] 服务已存在: \(service.id)")
            return
        }
        
        // 添加到服务列表
        services.append(service)
        
        // 初始化运行时信息
        runtimeInfos[service.id] = ServiceRuntimeInfo(
            id: service.id,
            status: .unknown,
            lastCheckedAt: Date()
        )
        
        // 保存到配置文件（可选）
        Task {
            await saveConfiguration()
        }
        
        LogInfo("[ServiceManager] 添加新服务: \(service.name) (\(service.id))")
    }
    
    /// 保存配置到文件
    private func saveConfiguration() async {
        let config = ServicesConfiguration(
            version: ServicesConfiguration.defaultVersion,
            services: services
        )
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            
            let configPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("workspace/service-management/services.json")
            
            try? FileManager.default.createDirectory(
                at: configPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            
            try data.write(to: configPath)
            LogInfo("[ServiceManager] 配置已保存到 \(configPath.path)")
        } catch {
            LogError("[ServiceManager] 保存配置失败: \(error)")
        }
    }
    
    // MARK: - 查询方法
    
    func status(for serviceId: String) -> ServiceRuntimeStatus {
        return runtimeInfos[serviceId]?.status ?? .unknown
    }
    
    func runtimeInfo(for serviceId: String) -> ServiceRuntimeInfo? {
        return runtimeInfos[serviceId]
    }
    
    var runningCount: Int {
        services.filter { status(for: $0.id) == .running }.count
    }
    
    var errorCount: Int {
        services.filter { status(for: $0.id) == .error }.count
    }
    
    func services(in category: ServiceDefinition.ServiceCategory?) -> [ServiceDefinition] {
        guard let category = category else { return services }
        return services.filter { $0.category == category }
    }
    
    /// 检查服务是否有活跃任务
    func hasActiveTask(for serviceId: String) -> Bool {
        return ServiceTaskManager.shared.hasActiveTask(for: serviceId)
    }
}

// MARK: - 默认服务配置

extension ServiceManager {
    static var defaultServices: [ServiceDefinition] {
        [
            ServiceDefinition(
                id: "xiaohongshu-mcp",
                name: "小红书 MCP",
                category: .mcp,
                type: .http,
                description: "小红书内容抓取服务",
                path: "~/workspace/xiaohongshu-mcp/",
                port: 18060,
                startCommand: "./xiaohongshu-mcp-darwin-arm64",
                stopCommand: nil,
                healthCheck: HealthCheckConfig(type: .http, endpoint: "/health"),
                env: nil,
                autoStart: false,
                dependencies: nil
            ),
            ServiceDefinition(
                id: "futu-mcp",
                name: "富途 MCP",
                category: .mcp,
                type: .http,
                description: "富途交易接口 MCP",
                path: "~/Code/mcp_futu/",
                port: 8001,
                startCommand: "python main_enhanced.py",
                stopCommand: nil,
                healthCheck: HealthCheckConfig(type: .http, endpoint: "/health"),
                env: nil,
                autoStart: false,
                dependencies: nil
            ),
            ServiceDefinition(
                id: "github-mcp-http",
                name: "GitHub MCP HTTP",
                category: .mcp,
                type: .http,
                description: "GitHub 操作 MCP (HTTP模式)",
                path: "~/Code/github-mcp-server/",
                port: 9002,
                startCommand: "./start-http.sh",
                stopCommand: nil,
                healthCheck: HealthCheckConfig(type: .http, endpoint: "/health"),
                env: nil,
                autoStart: false,
                dependencies: nil
            ),
            ServiceDefinition(
                id: "github-mcp-stdio",
                name: "GitHub MCP stdio",
                category: .mcp,
                type: .stdio,
                description: "GitHub 操作 MCP (STDIO模式)",
                path: "~/Code/github-mcp-server/",
                port: nil,
                startCommand: "./start-stdio.sh",
                stopCommand: nil,
                healthCheck: HealthCheckConfig(type: .process),
                env: nil,
                autoStart: false,
                dependencies: nil
            ),
            ServiceDefinition(
                id: "whatsapp-mcp",
                name: "WhatsApp MCP",
                category: .mcp,
                type: .stdio,
                description: "WhatsApp 桥接服务",
                path: "~/workspace/whatsapp-mcp/",
                port: nil,
                startCommand: "./start-bridge.sh",
                stopCommand: nil,
                healthCheck: HealthCheckConfig(type: .process),
                env: nil,
                autoStart: false,
                dependencies: nil
            ),
            ServiceDefinition(
                id: "futu-opend",
                name: "富途 OpenD",
                category: .desktop,
                type: .app,
                description: "富途交易接口桌面应用",
                path: nil,
                port: 35352,
                startCommand: "open -a FutuOpenD",
                stopCommand: "killall FutuOpenD",
                healthCheck: HealthCheckConfig(type: .port),
                env: nil,
                autoStart: false,
                dependencies: nil
            ),
            ServiceDefinition(
                id: "mongodb",
                name: "MongoDB",
                category: .other,
                type: .process,
                description: "MongoDB 数据库服务",
                path: nil,
                port: 27017,
                startCommand: "mongod --dbpath ~/data/db",
                stopCommand: nil,
                healthCheck: HealthCheckConfig(type: .port),
                env: nil,
                autoStart: false,
                dependencies: nil
            )
        ]
    }
}
