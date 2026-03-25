//
//  MCPModels.swift
//  MacAssistant
//
//  MCP (Model Context Protocol) 业务服务管理模型
//  管理外部 API 服务和第三方集成，区别于系统服务管理
//

import Foundation

// MARK: - MCP 服务配置

struct MCPServiceConfig: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var description: String = ""
    var emoji: String = "🔧"
    var endpoint: String
    var transportType: MCPTransportType = .stdio
    var authType: MCPAuthType = .none
    var apiKey: String?
    var headers: [String: String] = [:]
    var workingDirectory: String?
    var timeout: TimeInterval = 30
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var lastUsedAt: Date?
    var useCount: Int = 0
    
    // 启用的工具列表（空表示全部启用）
    var enabledTools: [String] = []
    
    // 初始化器
    init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        emoji: String = "🔧",
        endpoint: String,
        transportType: MCPTransportType = .stdio,
        authType: MCPAuthType = .none,
        apiKey: String? = nil,
        headers: [String: String] = [:],
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30,
        isEnabled: Bool = true,
        enabledTools: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.emoji = emoji
        self.endpoint = endpoint
        self.transportType = transportType
        self.authType = authType
        self.apiKey = apiKey
        self.headers = headers
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.isEnabled = isEnabled
        self.enabledTools = enabledTools
    }
}

// MARK: - 传输类型

enum MCPTransportType: String, Codable, CaseIterable {
    case stdio          // 本地进程通信
    case sse            // Server-Sent Events
    case websocket      // WebSocket
    case http           // HTTP REST
    
    var displayName: String {
        switch self {
        case .stdio: return "本地进程"
        case .sse: return "SSE"
        case .websocket: return "WebSocket"
        case .http: return "HTTP"
        }
    }
    
    var icon: String {
        switch self {
        case .stdio: return "terminal"
        case .sse: return "arrow.left.arrow.right"
        case .websocket: return "bolt.fill"
        case .http: return "globe"
        }
    }
    
    var description: String {
        switch self {
        case .stdio: return "启动本地程序并通过标准输入输出通信"
        case .sse: return "通过 Server-Sent Events 流式通信"
        case .websocket: return "通过 WebSocket 实时双向通信"
        case .http: return "通过 HTTP REST API 通信"
        }
    }
}

// MARK: - 认证类型

enum MCPAuthType: String, Codable, CaseIterable {
    case none
    case apiKey
    case bearerToken
    
    var displayName: String {
        switch self {
        case .none: return "无认证"
        case .apiKey: return "API Key"
        case .bearerToken: return "Bearer Token"
        }
    }
}

// MARK: - 服务状态

enum MCPServiceStatus: Equatable {
    case unknown
    case connecting
    case connected([MCPTool])
    case disconnected(String?)
    case error(String)
    
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
    
    var displayText: String {
        switch self {
        case .unknown: return "未知"
        case .connecting: return "连接中"
        case .connected(let tools): return "已连接 (\(tools.count) 工具)"
        case .disconnected: return "已断开"
        case .error: return "错误"
        }
    }
    
    var icon: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .connecting: return "arrow.clockwise"
        case .connected: return "checkmark.circle.fill"
        case .disconnected: return "xmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }
}

// MARK: - MCP 工具

struct MCPTool: Identifiable, Codable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    let parameters: MCPToolSchema?
    
    init(name: String, description: String = "", parameters: MCPToolSchema? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - 工具参数 Schema

struct MCPToolSchema: Codable, Equatable {
    let type: String
    let properties: [String: MCPPropertySchema]?
    let required: [String]?
}

struct MCPPropertySchema: Codable, Equatable {
    let type: String?
    let description: String?
    let enumValues: [String]?
    let items: Box<MCPPropertySchema>?
    
    enum CodingKeys: String, CodingKey {
        case type, description, items
        case enumValues = "enum"
    }
}

// Box 类型用于递归结构
final class Box<T: Codable & Equatable>: Codable, Equatable {
    var value: T
    init(_ value: T) { self.value = value }
    static func == (lhs: Box<T>, rhs: Box<T>) -> Bool { lhs.value == rhs.value }
}

// MARK: - MCP 请求/响应

struct MCPRequest: Codable, Identifiable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: [String: MCPValue]?
    
    init(id: String = UUID().uuidString, method: String, params: [String: MCPValue]? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

struct MCPResponse: Codable, Identifiable {
    let jsonrpc: String
    let id: String
    let result: MCPValue?
    let error: MCPErrorData?
}

struct MCPErrorData: Codable {
    let code: Int
    let message: String
    let data: MCPValue?
}

// MARK: - 工具调用结果

struct MCPToolResult: Codable {
    let content: [MCPToolContent]
    let isError: Bool?
}

enum MCPToolContent: Codable {
    case text(String)
    case image(data: String, mimeType: String)
    case resource(uri: String, mimeType: String?, text: String?, blob: String?)
    
    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, uri, blob
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let string):
            try container.encode("text", forKey: .type)
            try container.encode(string, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        case .resource(let uri, let mimeType, let text, let blob):
            try container.encode("resource", forKey: .type)
            try container.encode(uri, forKey: .uri)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(blob, forKey: .blob)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            self = .image(
                data: try container.decode(String.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType)
            )
        case "resource":
            self = .resource(
                uri: try container.decode(String.self, forKey: .uri),
                mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType),
                text: try container.decodeIfPresent(String.self, forKey: .text),
                blob: try container.decodeIfPresent(String.self, forKey: .blob)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content type: \(type)")
        }
    }
}

// MARK: - MCP Value 类型

enum MCPValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: MCPValue])
    case array([MCPValue])
    case null
    
    var value: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .object(let o): return o.reduce(into: [:]) { $0[$1.key] = $1.value.value }
        case .array(let a): return a.map { $0.value }
        case .null: return NSNull()
        }
    }
    
    init(fromAny value: Any) throws {
        if let s = value as? String { self = .string(s) }
        else if let i = value as? Int { self = .int(i) }
        else if let d = value as? Double { self = .double(d) }
        else if let b = value as? Bool { self = .bool(b) }
        else if let o = value as? [String: Any] {
            self = .object(try o.reduce(into: [:]) { result, pair in
                result[pair.key] = try MCPValue(fromAny: pair.value)
            })
        }
        else if let a = value as? [Any] {
            self = .array(try a.map { try MCPValue(fromAny: $0) })
        }
        else if value is NSNull {
            self = .null
        }
        else {
            throw MCPError.encodingError
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let o = try? container.decode([String: MCPValue].self) { self = .object(o) }
        else if let a = try? container.decode([MCPValue].self) { self = .array(a) }
        else if container.decodeNil() { self = .null }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid MCP value") }
    }
}

// MARK: - 预设配置

extension MCPServiceConfig {
    /// 内置预设服务配置
    static let presets: [MCPServiceConfig] = [
        // 文件系统
        MCPServiceConfig(
            name: "文件系统",
            description: "文件和目录操作",
            emoji: "📁",
            endpoint: "npx -y @modelcontextprotocol/server-filesystem ~/Documents ~/Downloads",
            transportType: .stdio
        ),
        // GitHub
        MCPServiceConfig(
            name: "GitHub",
            description: "GitHub API 操作",
            emoji: "🐙",
            endpoint: "npx -y @modelcontextprotocol/server-github",
            transportType: .stdio,
            authType: .apiKey
        ),
        // PostgreSQL
        MCPServiceConfig(
            name: "PostgreSQL",
            description: "PostgreSQL 数据库操作",
            emoji: "🐘",
            endpoint: "npx -y @modelcontextprotocol/server-postgres",
            transportType: .stdio
        ),
        // SQLite
        MCPServiceConfig(
            name: "SQLite",
            description: "SQLite 数据库操作",
            emoji: "💾",
            endpoint: "npx -y @modelcontextprotocol/server-sqlite ~/data.db",
            transportType: .stdio
        ),
        // 网络获取
        MCPServiceConfig(
            name: "网络获取",
            description: "网页抓取和解析",
            emoji: "🌐",
            endpoint: "npx -y @modelcontextprotocol/server-fetch",
            transportType: .stdio
        ),
        // Puppeteer
        MCPServiceConfig(
            name: "浏览器自动化",
            description: "使用 Puppeteer 进行浏览器自动化",
            emoji: "🎭",
            endpoint: "npx -y @modelcontextprotocol/server-puppeteer",
            transportType: .stdio
        ),
        // 内存
        MCPServiceConfig(
            name: "知识图谱",
            description: "基于知识图谱的记忆存储",
            emoji: "🧠",
            endpoint: "npx -y @modelcontextprotocol/server-memory",
            transportType: .stdio
        ),
        // 时间
        MCPServiceConfig(
            name: "时间工具",
            description: "时区和时间转换",
            emoji: "⏰",
            endpoint: "npx -y @modelcontextprotocol/server-time",
            transportType: .stdio
        ),
        // Slack
        MCPServiceConfig(
            name: "Slack",
            description: "Slack 消息和频道管理",
            emoji: "💬",
            endpoint: "npx -y @modelcontextprotocol/server-slack",
            transportType: .stdio,
            authType: .bearerToken
        ),
        // Brave Search
        MCPServiceConfig(
            name: "Brave 搜索",
            description: "Brave Search API",
            emoji: "🔍",
            endpoint: "npx -y @modelcontextprotocol/server-brave-search",
            transportType: .stdio,
            authType: .apiKey
        )
    ]
}
