//
//  MCPServiceManager.swift
//  MacAssistant
//
//  MCP 服务管理器 - 管理 MCP 服务的生命周期和调用
//

import Foundation
import Combine

/// MCP 服务管理器
@MainActor
final class MCPServiceManager: ObservableObject {
    static let shared = MCPServiceManager()
    
    // MARK: - Published Properties
    
    @Published private(set) var services: [MCPServiceConfig] = []
    @Published private(set) var serviceStatuses: [String: MCPServiceStatus] = [:]
    @Published private(set) var isConnecting = false
    
    // MARK: - Private Properties
    
    private var stdioConnections: [String: STDIOConnection] = [:]
    private var httpConnections: [String: HTTPConnection] = [:]
    private var wsConnections: [String: WebSocketConnection] = [:]
    private let storageKey = "mcp.services"
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    private init() {
        loadServices()
    }
    
    // MARK: - 服务管理
    
    /// 添加新服务
    func addService(_ config: MCPServiceConfig) {
        services.append(config)
        saveServices()
        objectWillChange.send()
    }
    
    /// 更新服务配置
    func updateService(_ config: MCPServiceConfig) {
        if let index = services.firstIndex(where: { $0.id == config.id }) {
            services[index] = config
            saveServices()
            
            // 断开现有连接（配置变更后需要重新连接）
            disconnectService(id: config.id)
            objectWillChange.send()
        }
    }
    
    /// 删除服务
    func removeService(id: String) {
        disconnectService(id: id)
        services.removeAll { $0.id == id }
        saveServices()
        objectWillChange.send()
    }
    
    /// 启用/禁用服务
    func setServiceEnabled(id: String, enabled: Bool) {
        if let index = services.firstIndex(where: { $0.id == id }) {
            services[index].isEnabled = enabled
            saveServices()
            
            if !enabled {
                disconnectService(id: id)
            }
            objectWillChange.send()
        }
    }
    
    // MARK: - 连接管理
    
    /// 连接单个服务
    func connectService(id: String) async {
        guard let config = services.first(where: { $0.id == id }) else { return }
        guard config.isEnabled else { return }
        
        serviceStatuses[id] = .connecting
        isConnecting = true
        
        do {
            let tools: [MCPTool]
            
            switch config.transportType {
            case .stdio:
                let connection = try await STDIOConnection.launch(config: config)
                stdioConnections[id] = connection
                tools = try await connection.fetchTools()
                
            case .sse, .http:
                let connection = try await HTTPConnection.connect(config: config)
                httpConnections[id] = connection
                tools = try await connection.fetchTools()
                
            case .websocket:
                let connection = try await WebSocketConnection.connect(config: config)
                wsConnections[id] = connection
                tools = try await connection.fetchTools()
            }
            
            serviceStatuses[id] = .connected(tools)
            
            // 更新最后使用时间
            if let index = services.firstIndex(where: { $0.id == id }) {
                services[index].lastUsedAt = Date()
                saveServices()
            }
            
            LogInfo("[MCP] 服务 \(config.name) 连接成功，发现 \(tools.count) 个工具")
        } catch {
            serviceStatuses[id] = .error(error.localizedDescription)
            LogError("[MCP] 服务 \(config.name) 连接失败: \(error)")
        }
        
        isConnecting = false
    }
    
    /// 断开服务连接
    func disconnectService(id: String) {
        // 断开所有可能类型的连接
        if let conn = stdioConnections[id] {
            Task { await conn.close() }
            stdioConnections.removeValue(forKey: id)
        }
        if let conn = httpConnections[id] {
            Task { await conn.close() }
            httpConnections.removeValue(forKey: id)
        }
        if let conn = wsConnections[id] {
            Task { await conn.close() }
            wsConnections.removeValue(forKey: id)
        }
        serviceStatuses[id] = .disconnected(nil)
    }
    
    /// 断开所有连接
    func disconnectAll() {
        for (id, conn) in stdioConnections {
            Task { await conn.close() }
            serviceStatuses[id] = .disconnected(nil)
        }
        for (id, conn) in httpConnections {
            Task { await conn.close() }
            serviceStatuses[id] = .disconnected(nil)
        }
        for (id, conn) in wsConnections {
            Task { await conn.close() }
            serviceStatuses[id] = .disconnected(nil)
        }
        stdioConnections.removeAll()
        httpConnections.removeAll()
        wsConnections.removeAll()
    }
    
    /// 连接所有启用的服务
    func connectAllEnabled() async {
        for service in services where service.isEnabled {
            await connectService(id: service.id)
        }
    }
    
    // MARK: - 工具调用
    
    /// 调用 MCP 工具
    func callTool(serviceId: String, toolName: String, arguments: [String: Any]) async throws -> MCPToolResult {
        guard let config = services.first(where: { $0.id == serviceId }) else {
            throw MCPError.serviceNotFound
        }
        
        // 检查工具是否被启用
        if !config.enabledTools.isEmpty && !config.enabledTools.contains(toolName) {
            throw MCPError.toolDisabled
        }
        
        // 转换参数为 MCPValue
        let params: [String: MCPValue] = [
            "name": .string(toolName),
            "arguments": try MCPValue(fromAny: arguments)
        ]
        
        let request = MCPRequest(
            id: UUID().uuidString,
            method: "tools/call",
            params: params
        )
        
        let response: MCPResponse
        
        // 根据传输类型调用对应的连接
        switch config.transportType {
        case .stdio:
            guard let conn = stdioConnections[serviceId] else {
                throw MCPError.serviceNotConnected
            }
            response = try await conn.sendRequest(request)
            
        case .sse, .http:
            guard let conn = httpConnections[serviceId] else {
                throw MCPError.serviceNotConnected
            }
            response = try await conn.sendRequest(request)
            
        case .websocket:
            guard let conn = wsConnections[serviceId] else {
                throw MCPError.serviceNotConnected
            }
            response = try await conn.sendRequest(request)
        }
        
        if let error = response.error {
            throw MCPError.rpcError(code: error.code, message: error.message)
        }
        
        guard let result = response.result else {
            throw MCPError.invalidResponse
        }
        
        // 解析结果
        let resultData = try JSONSerialization.data(withJSONObject: result.value)
        let toolResult = try JSONDecoder().decode(MCPToolResult.self, from: resultData)
        
        // 更新使用统计
        if let index = services.firstIndex(where: { $0.id == serviceId }) {
            services[index].useCount += 1
            services[index].lastUsedAt = Date()
            saveServices()
        }
        
        return toolResult
    }
    
    /// 调用工具（自动选择服务）
    func callTool(toolName: String, arguments: [String: Any]) async throws -> MCPToolResult {
        // 查找支持该工具的服务
        for (serviceId, status) in serviceStatuses {
            if case .connected(let tools) = status,
               tools.contains(where: { $0.name == toolName }) {
                return try await callTool(serviceId: serviceId, toolName: toolName, arguments: arguments)
            }
        }
        throw MCPError.toolNotFound(toolName)
    }
    
    /// 获取所有可用工具
    func getAllAvailableTools() -> [(service: MCPServiceConfig, tool: MCPTool)] {
        var result: [(MCPServiceConfig, MCPTool)] = []
        
        for service in services where service.isEnabled {
            if case .connected(let tools) = serviceStatuses[service.id] {
                for tool in tools {
                    if service.enabledTools.isEmpty || service.enabledTools.contains(tool.name) {
                        result.append((service, tool))
                    }
                }
            }
        }
        
        return result
    }
    
    // MARK: - 持久化
    
    private func loadServices() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        
        do {
            services = try JSONDecoder().decode([MCPServiceConfig].self, from: data)
        } catch {
            LogError("[MCP] 加载服务失败: \(error)")
        }
    }
    
    private func saveServices() {
        do {
            let data = try JSONEncoder().encode(services)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            LogError("[MCP] 保存服务失败: \(error)")
        }
    }
}

// MARK: - STDIO 连接（本地进程）

actor STDIOConnection {
    private var process: Process?
    private var stdin: Pipe?
    private var stdout: Pipe?
    private var pendingRequests: [String: CheckedContinuation<MCPResponse, Error>] = [:]
    private var isClosed = false
    
    static func launch(config: MCPServiceConfig) async throws -> STDIOConnection {
        let connection = STDIOConnection()
        try await connection.launchProcess(config: config)
        return connection
    }
    
    private func launchProcess(config: MCPServiceConfig) async throws {
        let task = Process()
        
        // 解析命令
        let parts = config.endpoint.split(separator: " ").map(String.init)
        guard !parts.isEmpty else {
            throw MCPError.invalidConfiguration
        }
        
        task.launchPath = "/usr/bin/env"
        task.arguments = parts
        
        // 设置环境变量
        var environment = ProcessInfo.processInfo.environment
        if let apiKey = config.apiKey {
            environment["API_KEY"] = apiKey
        }
        for (key, value) in config.headers {
            environment[key] = value
        }
        task.environment = environment
        
        // 设置工作目录
        if let workingDir = config.workingDirectory {
            let expandedPath = NSString(string: workingDir).expandingTildeInPath
            task.currentDirectoryURL = URL(fileURLWithPath: expandedPath)
        }
        
        // 设置管道
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        task.standardError = FileHandle.nullDevice
        
        // 启动进程
        task.launch()
        
        self.process = task
        self.stdin = stdinPipe
        self.stdout = stdoutPipe
        
        // 开始读取输出
        Task {
            await readOutput(from: stdoutPipe)
        }
    }
    
    private func readOutput(from pipe: Pipe) async {
        let handle = pipe.fileHandleForReading
        
        while !isClosed {
            do {
                let data = handle.availableData
                guard !data.isEmpty else {
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    continue
                }
                
                if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !line.isEmpty {
                    try await handleResponse(line: line)
                }
            } catch {
                if !isClosed {
                    LogError("[MCP] 读取输出错误: \(error)")
                }
            }
        }
    }
    
    private func handleResponse(line: String) async throws {
        guard let data = line.data(using: .utf8) else { return }
        
        let response = try JSONDecoder().decode(MCPResponse.self, from: data)
        
        if let continuation = pendingRequests.removeValue(forKey: response.id) {
            continuation.resume(returning: response)
        }
    }
    
    func sendRequest(_ request: MCPRequest) async throws -> MCPResponse {
        guard !isClosed, let stdin = stdin else {
            throw MCPError.connectionClosed
        }
        
        let data = try JSONEncoder().encode(request)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw MCPError.encodingError
        }
        
        return try await withTimeout(seconds: 30) {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingRequests[request.id] = continuation
                
                if let lineData = (jsonString + "\n").data(using: .utf8) {
                    stdin.fileHandleForWriting.write(lineData)
                }
            }
        }
    }
    
    func fetchTools() async throws -> [MCPTool] {
        let request = MCPRequest(id: UUID().uuidString, method: "tools/list")
        let response = try await sendRequest(request)
        
        guard let result = response.result,
              let toolsArray = result.value as? [[String: Any]] else {
            return []
        }
        
        let data = try JSONSerialization.data(withJSONObject: toolsArray)
        return try JSONDecoder().decode([MCPTool].self, from: data)
    }
    
    func close() {
        isClosed = true
        
        // 取消所有待处理请求
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPError.connectionClosed)
        }
        pendingRequests.removeAll()
        
        // 终止进程
        process?.terminate()
        process = nil
    }
}

// MARK: - HTTP 连接（SSE/HTTP）

actor HTTPConnection {
    private var endpoint: URL?
    private var headers: [String: String] = [:]
    
    static func connect(config: MCPServiceConfig) async throws -> HTTPConnection {
        guard let url = URL(string: config.endpoint) else {
            throw MCPError.invalidConfiguration
        }
        
        let connection = HTTPConnection()
        await connection.configure(url: url, headers: config.headers, apiKey: config.apiKey)
        return connection
    }
    
    private func configure(url: URL, headers: [String: String], apiKey: String?) {
        self.endpoint = url
        self.headers = headers
        if let apiKey = apiKey {
            self.headers["Authorization"] = "Bearer \(apiKey)"
        }
    }
    
    func sendRequest(_ request: MCPRequest) async throws -> MCPResponse {
        guard let url = endpoint else {
            throw MCPError.invalidConfiguration
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        
        urlRequest.httpBody = try JSONEncoder().encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw MCPError.httpError
        }
        
        return try JSONDecoder().decode(MCPResponse.self, from: data)
    }
    
    func fetchTools() async throws -> [MCPTool] {
        let request = MCPRequest(id: UUID().uuidString, method: "tools/list")
        let response = try await sendRequest(request)
        
        guard let result = response.result,
              let toolsArray = result.value as? [[String: Any]] else {
            return []
        }
        
        let data = try JSONSerialization.data(withJSONObject: toolsArray)
        return try JSONDecoder().decode([MCPTool].self, from: data)
    }
    
    func close() {
        // HTTP 连接是无状态的，无需清理
    }
}

// MARK: - WebSocket 连接

actor WebSocketConnection {
    private var webSocketTask: URLSessionWebSocketTask?
    private var pendingRequests: [String: CheckedContinuation<MCPResponse, Error>] = [:]
    
    static func connect(config: MCPServiceConfig) async throws -> WebSocketConnection {
        guard let url = URL(string: config.endpoint) else {
            throw MCPError.invalidConfiguration
        }
        
        let connection = WebSocketConnection()
        
        var request = URLRequest(url: url)
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let task = URLSession.shared.webSocketTask(with: request)
        await connection.setWebSocketTask(task)
        task.resume()
        
        // 开始接收消息
        Task {
            await connection.receiveMessages()
        }
        
        return connection
    }
    
    private func setWebSocketTask(_ task: URLSessionWebSocketTask) {
        self.webSocketTask = task
    }
    
    private func receiveMessages() async {
        guard let task = webSocketTask else { return }
        
        do {
            let message = try await task.receive()
            
            switch message {
            case .string(let text):
                if let data = text.data(using: .utf8) {
                    let response = try JSONDecoder().decode(MCPResponse.self, from: data)
                    if let continuation = pendingRequests.removeValue(forKey: response.id) {
                        continuation.resume(returning: response)
                    }
                }
            case .data(let data):
                let response = try JSONDecoder().decode(MCPResponse.self, from: data)
                if let continuation = pendingRequests.removeValue(forKey: response.id) {
                    continuation.resume(returning: response)
                }
            @unknown default:
                break
            }
            
            // 继续接收
            await receiveMessages()
        } catch {
            LogError("[MCP] WebSocket 接收错误: \(error)")
        }
    }
    
    func sendRequest(_ request: MCPRequest) async throws -> MCPResponse {
        guard let task = webSocketTask else {
            throw MCPError.connectionClosed
        }
        
        let data = try JSONEncoder().encode(request)
        
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[request.id] = continuation
            
            task.send(.data(data)) { [weak self] error in
                if let error = error {
                    Task { await self?.removePendingRequest(id: request.id) }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func removePendingRequest(id: String) {
        pendingRequests.removeValue(forKey: id)
    }
    
    func fetchTools() async throws -> [MCPTool] {
        let request = MCPRequest(id: UUID().uuidString, method: "tools/list")
        let response = try await sendRequest(request)
        
        guard let result = response.result,
              let toolsArray = result.value as? [[String: Any]] else {
            return []
        }
        
        let data = try JSONSerialization.data(withJSONObject: toolsArray)
        return try JSONDecoder().decode([MCPTool].self, from: data)
    }
    
    func close() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }
}

// MARK: - 错误类型

enum MCPError: Error, LocalizedError {
    case serviceNotFound
    case serviceNotConnected
    case toolNotFound(String)
    case toolDisabled
    case connectionClosed
    case invalidConfiguration
    case encodingError
    case invalidResponse
    case rpcError(code: Int, message: String)
    case httpError
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .serviceNotFound: return "MCP 服务未找到"
        case .serviceNotConnected: return "MCP 服务未连接"
        case .toolNotFound(let name): return "工具 '\(name)' 未找到"
        case .toolDisabled: return "工具已被禁用"
        case .connectionClosed: return "连接已关闭"
        case .invalidConfiguration: return "配置无效"
        case .encodingError: return "编码错误"
        case .invalidResponse: return "无效响应"
        case .rpcError(_, let message): return "RPC 错误: \(message)"
        case .httpError: return "HTTP 错误"
        case .timeout: return "请求超时"
        }
    }
}

// MARK: - 辅助函数

private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MCPError.timeout
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
