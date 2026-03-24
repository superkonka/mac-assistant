//
//  DiscoveredService.swift
//  MacAssistant
//
//  发现的服务模型
//

import Foundation

// MARK: - 发现的服务
struct DiscoveredService: Identifiable, Codable, Equatable {
    let id: String                    // 生成的唯一 ID
    let name: String                  // 服务名称
    let port: Int                     // 端口
    let pid: Int?                     // 进程 ID
    let processName: String?          // 进程名称
    let serviceType: DiscoveredServiceType
    let discoveredAt: Date
    let discoveryMethod: DiscoveryMethod
    var confirmedStatus: ConfirmationStatus
    var metadata: [String: String]
    
    /// 建议的服务 ID
    var suggestedID: String {
        metadata["suggested_id"] ?? "discovered-\(port)"
    }
    
    /// 建议的服务名称
    var suggestedName: String {
        if let existingName = metadata["existing_name"], !existingName.isEmpty {
            return existingName
        }
        return name
    }
    
    /// 检查是否已被管理
    var isManaged: Bool {
        get async {
            await ServiceManager.shared.services.contains { $0.port == port }
        }
    }
    
    /// 转换为 ServiceDefinition
    func toServiceDefinition() -> ServiceDefinition {
        ServiceDefinition(
            id: suggestedID,
            name: suggestedName,
            category: serviceType.category,
            type: serviceType.serviceType,
            description: "发现的服务 (端口: \(port))",
            path: nil,
            port: port,
            startCommand: nil,  // 外部启动，不知道命令
            stopCommand: nil,
            healthCheck: HealthCheckConfig(type: .port),
            env: nil,
            autoStart: false,
            dependencies: nil
        )
    }
}

// MARK: - 发现的服务类型
enum DiscoveredServiceType: String, Codable, CaseIterable {
    case httpService       // HTTP 服务
    case mcpServer         // MCP 服务器
    case database          // 数据库
    case messageQueue      // 消息队列
    case cacheServer       // 缓存服务
    case developmentTool   // 开发工具
    case unknown           // 未知类型
    
    var displayName: String {
        switch self {
        case .httpService: return "HTTP 服务"
        case .mcpServer: return "MCP 服务器"
        case .database: return "数据库"
        case .messageQueue: return "消息队列"
        case .cacheServer: return "缓存服务"
        case .developmentTool: return "开发工具"
        case .unknown: return "未知类型"
        }
    }
    
    var icon: String {
        switch self {
        case .httpService: return "globe"
        case .mcpServer: return "server.rack"
        case .database: return "cylinder.split.1x2"
        case .messageQueue: return "arrow.left.arrow.right"
        case .cacheServer: return "memorychip"
        case .developmentTool: return "hammer"
        case .unknown: return "questionmark.circle"
        }
    }
    
    var category: ServiceDefinition.ServiceCategory {
        switch self {
        case .mcpServer:
            return .mcp
        case .database, .cacheServer, .messageQueue:
            return .other
        default:
            return .other
        }
    }
    
    var serviceType: ServiceDefinition.ServiceType {
        switch self {
        case .mcpServer:
            return .http
        case .database, .cacheServer, .messageQueue:
            return .process
        default:
            return .http
        }
    }
}

// MARK: - 发现方法
enum DiscoveryMethod: String, Codable, CaseIterable {
    case portScan          // 端口扫描
    case processMonitor    // 进程监控
    case manualAdd         // 手动添加
    case networkProbe      // 网络探测
    
    var displayName: String {
        switch self {
        case .portScan: return "端口扫描"
        case .processMonitor: return "进程监控"
        case .manualAdd: return "手动添加"
        case .networkProbe: return "网络探测"
        }
    }
}

// MARK: - 确认状态
enum ConfirmationStatus: String, Codable, CaseIterable {
    case pending           // 待确认
    case confirmed         // 已确认
    case ignored           // 已忽略
    case autoManaged       // 自动管理
    
    var displayName: String {
        switch self {
        case .pending: return "待确认"
        case .confirmed: return "已确认"
        case .ignored: return "已忽略"
        case .autoManaged: return "自动管理"
        }
    }
    
    var color: String {
        switch self {
        case .pending: return "orange"
        case .confirmed: return "green"
        case .ignored: return "gray"
        case .autoManaged: return "blue"
        }
    }
}

// MARK: - 服务发现事件
enum ServiceDiscoveryEvent {
    case discovered(service: DiscoveredService)
    case confirmed(serviceID: String)
    case ignored(serviceID: String)
    case addedToManagement(service: DiscoveredService)
    case scanCompleted(found: Int, total: Int, duration: TimeInterval)
    case scanFailed(error: String)
}

// MARK: - 端口扫描配置
struct PortScanConfig {
    let startPort: Int
    let endPort: Int
    let timeout: TimeInterval
    let concurrency: Int  // 并发数
    
    static let `default` = PortScanConfig(
        startPort: 3000,
        endPort: 10000,
        timeout: 2,
        concurrency: 50
    )
    
    static let quick = PortScanConfig(
        startPort: 3000,
        endPort: 9000,
        timeout: 1,
        concurrency: 100
    )
    
    static let comprehensive = PortScanConfig(
        startPort: 1,
        endPort: 65535,
        timeout: 3,
        concurrency: 20
    )
}

// MARK: - 常见服务端口映射
struct CommonServicePorts {
    static let mapping: [Int: DiscoveredServiceType] = [
        // MCP 服务
        18060: .mcpServer,    // 小红书 MCP
        9002: .mcpServer,     // GitHub MCP HTTP
        8001: .mcpServer,     // 富途 MCP
        
        // 数据库
        3306: .database,      // MySQL
        5432: .database,      // PostgreSQL
        27017: .database,     // MongoDB
        6379: .cacheServer,   // Redis
        9200: .database,      // Elasticsearch
        
        // 消息队列
        5672: .messageQueue,  // RabbitMQ
        9092: .messageQueue,  // Kafka
        
        // 开发工具
        3000: .developmentTool,
        8080: .httpService,
        8081: .httpService,
        5000: .httpService,
        8000: .httpService,
        4200: .developmentTool,  // Angular
        5173: .developmentTool,  // Vite
        5174: .developmentTool,
    ]
    
    static func identifyServiceType(port: Int) -> DiscoveredServiceType {
        return mapping[port] ?? .unknown
    }
    
    static func suggestServiceName(port: Int, type: DiscoveredServiceType) -> String {
        switch type {
        case .mcpServer:
            return "MCP 服务 (端口: \(port))"
        case .database:
            if port == 3306 { return "MySQL" }
            if port == 5432 { return "PostgreSQL" }
            if port == 27017 { return "MongoDB" }
            if port == 6379 { return "Redis" }
            return "数据库 (端口: \(port))"
        case .cacheServer:
            return "缓存服务 (端口: \(port))"
        case .messageQueue:
            return "消息队列 (端口: \(port))"
        case .httpService:
            return "HTTP 服务 (端口: \(port))"
        case .developmentTool:
            return "开发服务器 (端口: \(port))"
        case .unknown:
            return "未知服务 (端口: \(port))"
        }
    }
}

// MARK: - 发现的服务分组
struct DiscoveredServiceGroup: Identifiable {
    let id = UUID()
    let type: DiscoveredServiceType
    var services: [DiscoveredService]
    
    var count: Int { services.count }
    var confirmedCount: Int {
        services.filter { $0.confirmedStatus == .confirmed || $0.confirmedStatus == .autoManaged }.count
    }
    var pendingCount: Int {
        services.filter { $0.confirmedStatus == .pending }.count
    }
}
