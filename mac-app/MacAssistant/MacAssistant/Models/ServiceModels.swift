//
//  ServiceModels.swift
//  MacAssistant
//
//  服务管理模型 - 统一管理 MCP 服务、桌面应用等
//

import Foundation

/// 服务定义（从配置文件加载）
struct ServiceDefinition: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let category: ServiceCategory
    let type: ServiceType
    let description: String?
    let path: String?
    let port: Int?
    let startCommand: String?
    let stopCommand: String?
    let healthCheck: HealthCheckConfig?
    let env: [String: String]?
    let autoStart: Bool
    let dependencies: [String]?
    
    enum ServiceCategory: String, Codable, CaseIterable {
        case mcp = "mcp"
        case desktop = "desktop"
        case other = "other"
        
        var displayName: String {
            switch self {
            case .mcp: return "MCP 服务"
            case .desktop: return "桌面应用"
            case .other: return "其他服务"
            }
        }
        
        var icon: String {
            switch self {
            case .mcp: return "server.rack"
            case .desktop: return "app.fill"
            case .other: return "gearshape.fill"
            }
        }
    }
    
    enum ServiceType: String, Codable {
        case http = "http"           // HTTP 服务（MCP SSE）
        case stdio = "stdio"         // STDIO 服务
        case process = "process"     // 普通进程
        case app = "app"             // 桌面应用
    }
}

/// 健康检查配置
struct HealthCheckConfig: Codable, Equatable {
    let type: HealthCheckType
    let endpoint: String?         // HTTP 健康检查路径
    let interval: Int?            // 检查间隔（秒）
    
    init(type: HealthCheckType, endpoint: String? = nil, interval: Int? = 30) {
        self.type = type
        self.endpoint = endpoint
        self.interval = interval
    }
    
    enum HealthCheckType: String, Codable {
        case http = "http"
        case port = "port"
        case process = "process"
    }
}

/// 服务运行状态
enum ServiceRuntimeStatus: String, Codable, CaseIterable {
    case unknown = "unknown"
    case running = "running"
    case stopped = "stopped"
    case error = "error"
    case starting = "starting"
    case stopping = "stopping"
    
    var displayName: String {
        switch self {
        case .unknown: return "未知"
        case .running: return "运行中"
        case .stopped: return "已停止"
        case .error: return "异常"
        case .starting: return "启动中"
        case .stopping: return "停止中"
        }
    }
    
    var color: Color {
        switch self {
        case .unknown: return .gray
        case .running: return .green
        case .stopped: return .red
        case .error: return .red
        case .starting: return .yellow
        case .stopping: return .orange
        }
    }
    
    var colorName: String {
        switch self {
        case .unknown: return "gray"
        case .running: return "green"
        case .stopped: return "red"
        case .error: return "red"
        case .starting: return "yellow"
        case .stopping: return "orange"
        }
    }
    
    var symbolName: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .running: return "checkmark.circle.fill"
        case .stopped: return "xmark.circle"
        case .error: return "exclamationmark.triangle.fill"
        case .starting: return "arrow.clockwise"
        case .stopping: return "arrow.counterclockwise"
        }
    }
}

/// 服务运行时信息
struct ServiceRuntimeInfo: Identifiable, Equatable {
    let id: String              // 对应 ServiceDefinition.id
    var status: ServiceRuntimeStatus
    var pid: Int?               // 进程 ID
    var lastCheckedAt: Date
    var errorMessage: String?   // 如果状态是 error
    var uptime: TimeInterval?   // 运行时长
    var lastStartedAt: Date?    // 上次启动时间
    var healthCheckResult: HealthCheckResult?
}

/// 健康检查结果
struct HealthCheckResult: Equatable {
    let timestamp: Date
    let isHealthy: Bool
    let responseTimeMs: Int?
    let message: String?
    let metadata: [String: String]
    
    init(timestamp: Date = Date(), isHealthy: Bool, responseTimeMs: Int? = nil, message: String? = nil, metadata: [String: String] = [:]) {
        self.timestamp = timestamp
        self.isHealthy = isHealthy
        self.responseTimeMs = responseTimeMs
        self.message = message
        self.metadata = metadata
    }
}

/// 服务配置文档（根结构）
struct ServicesConfiguration: Codable {
    let version: String
    let services: [ServiceDefinition]
    
    static let defaultVersion = "1.0"
}

/// 服务操作结果
enum ServiceOperationResult {
    case success(message: String)
    case failure(error: String)
    case timeout
}

/// AI 服务操作结果
struct ServiceAIOperationResult {
    let success: Bool
    let serviceId: String
    let action: String
    let pid: Int?
    let status: ServiceRuntimeStatus
    let message: String
    let error: String?
    
    init(
        success: Bool,
        serviceId: String,
        action: String,
        pid: Int?,
        status: ServiceRuntimeStatus,
        message: String,
        error: String?
    ) {
        self.success = success
        self.serviceId = serviceId
        self.action = action
        self.pid = pid
        self.status = status
        self.message = message
        self.error = error
    }
}
