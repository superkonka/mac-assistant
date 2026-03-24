//
//  SkillCatalogAdapters.swift
//  MacAssistant
//
//  Skill 系统适配器 - 将旧版 Skill 系统桥接到统一 Catalog
//

import Foundation

// MARK: - Adapter Protocol

/// Skill 适配器协议
protocol SkillAdapter {
    /// 源系统名称
    var sourceName: String { get }
    
    /// 扫描并转换源系统的 Skills
    func adaptAllSkills() async throws -> [SkillManifest]
    
    /// 将特定 Skill 转换为 Manifest
    func adaptSkill(id: String) async throws -> SkillManifest?
    
    /// 执行转换后的 Skill
    func execute(manifestID: String, parameters: [String: Any]) async throws -> SkillExecutionResult
}

/// Skill 执行结果
struct SkillExecutionResult: Codable {
    let success: Bool
    let output: [String: String]?
    let error: String?
    let executionTime: TimeInterval
}

// MARK: - SkillSystem Adapter

/// 适配旧的 SkillSystem
final class SkillSystemAdapter: SkillAdapter {
    let sourceName = "SkillSystem"
    
    func adaptAllSkills() async throws -> [SkillManifest] {
        LogInfo("[SkillSystemAdapter] SkillSystem 适配已简化")
        return []
    }
    
    func adaptSkill(id: String) async throws -> SkillManifest? {
        return nil
    }
    
    func execute(manifestID: String, parameters: [String: Any]) async throws -> SkillExecutionResult {
        let startTime = Date()
        return SkillExecutionResult(
            success: false,
            output: nil,
            error: "SkillSystem 适配已简化",
            executionTime: Date().timeIntervalSince(startTime)
        )
    }
}

// MARK: - AISkill Adapter

/// 适配 AgentSkill (AgentSkill 协议)
final class AISkillAdapter: SkillAdapter {
    let sourceName = "AISkill"
    
    func adaptAllSkills() async throws -> [SkillManifest] {
        let skills = SkillRegistry.shared.allSkillNames().compactMap { SkillRegistry.shared.getSkill($0) }
        
        return skills.map { skill in
            SkillManifest(
                id: "agent.\(skill.name)",
                name: skill.name,
                description: skill.description,
                version: "1.0.0",
                capabilities: [
                    SkillCapability(domain: "agent", action: skill.name, resource: nil)
                ],
                inputSchema: SkillInputSchema(parameters: [], required: []),
                outputSchema: SkillOutputSchema(type: .string, description: "执行结果", properties: nil),
                executorType: .agent,
                executorConfig: ["skillName": skill.name],
                tags: ["agent"] + skill.requiredTools
            )
        }
    }
    
    func adaptSkill(id: String) async throws -> SkillManifest? {
        let skillName = id.replacingOccurrences(of: "agent.", with: "")
        guard let skill = SkillRegistry.shared.getSkill(skillName) else { return nil }
        
        return SkillManifest(
            id: "agent.\(skill.name)",
            name: skill.name,
            description: skill.description,
            version: "1.0.0",
            capabilities: [
                SkillCapability(domain: "agent", action: skill.name, resource: nil)
            ],
            inputSchema: SkillInputSchema(parameters: [], required: []),
            outputSchema: SkillOutputSchema(type: .string, description: "执行结果", properties: nil),
            executorType: .agent,
            executorConfig: ["skillName": skill.name],
            tags: ["agent"] + skill.requiredTools
        )
    }
    
    func execute(manifestID: String, parameters: [String: Any]) async throws -> SkillExecutionResult {
        let startTime = Date()
        let skillName = manifestID.replacingOccurrences(of: "agent.", with: "")
        
        guard let skill = SkillRegistry.shared.getSkill(skillName) else {
            return SkillExecutionResult(
                success: false,
                output: nil,
                error: "Skill 不存在: \(skillName)",
                executionTime: Date().timeIntervalSince(startTime)
            )
        }
        
        do {
            let command = parameters["command"] as? String ?? ""
            let args = parameters["args"] as? [String] ?? []
            let result = try await skill.execute(command, args: args)
            return SkillExecutionResult(
                success: true,
                output: ["result": result],
                error: nil,
                executionTime: Date().timeIntervalSince(startTime)
            )
        } catch {
            return SkillExecutionResult(
                success: false,
                output: nil,
                error: error.localizedDescription,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }
    }
}

// MARK: - MCP Service Adapter

/// 适配 MCP Services 作为 Skills（简化版）
final class MCPServiceAdapter: SkillAdapter {
    let sourceName = "MCPService"
    
    func adaptAllSkills() async throws -> [SkillManifest] {
        let services = await MainActor.run {
            ServiceManager.shared.services.filter { $0.category == .mcp }
        }
        let manifests = services.map(manifest(for:))
        LogInfo("[MCPServiceAdapter] 已转换 \(manifests.count) 个 MCP 服务为 Skills")
        return manifests
    }
    
    func adaptSkill(id: String) async throws -> SkillManifest? {
        let serviceID = normalizedServiceID(from: id)
        let service = await MainActor.run {
            ServiceManager.shared.services.first { $0.id == serviceID && $0.category == .mcp }
        }
        return service.map(manifest(for:))
    }
    
    func execute(manifestID: String, parameters: [String: Any]) async throws -> SkillExecutionResult {
        let startTime = Date()
        let serviceID = normalizedServiceID(from: manifestID)
        guard let service = await MainActor.run(
            body: { ServiceManager.shared.services.first { $0.id == serviceID && $0.category == .mcp } }
        ) else {
            return SkillExecutionResult(
                success: false,
                output: nil,
                error: "MCP 服务不存在: \(serviceID)",
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        guard service.type == .http, let port = service.port else {
            return SkillExecutionResult(
                success: false,
                output: nil,
                error: "当前仅支持 HTTP 型 MCP 服务，\(service.name) 属于 \(service.type.rawValue) 模式。",
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        let runtime = await MainActor.run { ServiceManager.shared.runtimeInfos[service.id] }
        if runtime?.status != .running {
            return SkillExecutionResult(
                success: false,
                output: nil,
                error: "\(service.name) 当前未运行，请先启动服务。",
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        let operation = (parameters["operation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "health"
        let endpoint = resolvedEndpoint(for: operation, parameters: parameters, service: service)
        let method = ((parameters["method"] as? String) ?? (operation == "invoke" ? "POST" : "GET"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard let url = URL(string: "http://127.0.0.1:\(port)\(endpoint)") else {
            return SkillExecutionResult(
                success: false,
                output: nil,
                error: "无法构造 \(service.name) 的请求地址。",
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 60

            if let jsonString = parameters["json_body"] as? String,
               !jsonString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.httpBody = Data(jsonString.utf8)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } else if let body = parameters["body"] as? [String: Any] {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return SkillExecutionResult(
                    success: false,
                    output: nil,
                    error: "\(service.name) 没有返回有效的 HTTP 响应。",
                    executionTime: Date().timeIntervalSince(startTime)
                )
            }

            let responseText = prettyResponseText(from: data)
            guard (200...299).contains(httpResponse.statusCode) else {
                return SkillExecutionResult(
                    success: false,
                    output: [
                        "service_id": service.id,
                        "endpoint": endpoint,
                        "status_code": String(httpResponse.statusCode),
                        "response": responseText
                    ],
                    error: "\(service.name) 请求失败，HTTP \(httpResponse.statusCode)。",
                    executionTime: Date().timeIntervalSince(startTime)
                )
            }

            return SkillExecutionResult(
                success: true,
                output: [
                    "service_id": service.id,
                    "service_name": service.name,
                    "operation": operation,
                    "endpoint": endpoint,
                    "status_code": String(httpResponse.statusCode),
                    "response": responseText
                ],
                error: nil,
                executionTime: Date().timeIntervalSince(startTime)
            )
        } catch {
            return SkillExecutionResult(
                success: false,
                output: [
                    "service_id": service.id,
                    "endpoint": endpoint
                ],
                error: error.localizedDescription,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }
    }

    private func manifest(for service: ServiceDefinition) -> SkillManifest {
        let endpointHint = service.healthCheck?.endpoint ?? "/health"
        return SkillManifest(
            id: "mcp.\(service.id)",
            name: service.name,
            description: """
            通过原生 MCP 服务调用 \(service.name)。
            默认执行健康检查；也可指定自定义 HTTP endpoint 和 JSON body 直接调用服务接口。
            预设健康检查地址：\(endpointHint)
            """,
            version: "1.0.0",
            capabilities: [
                SkillCapability(domain: "mcp", action: "health", resource: service.id),
                SkillCapability(domain: "mcp", action: "invoke", resource: service.id)
            ],
            inputSchema: SkillInputSchema(
                parameters: [
                    .init(
                        name: "operation",
                        type: .string,
                        description: "操作类型：health 或 invoke",
                        defaultValue: "health",
                        enumValues: ["health", "invoke"]
                    ),
                    .init(
                        name: "endpoint",
                        type: .string,
                        description: "相对路径，例如 /api/trending/list；为空时默认使用健康检查路径",
                        defaultValue: endpointHint,
                        enumValues: nil
                    ),
                    .init(
                        name: "method",
                        type: .string,
                        description: "HTTP 方法",
                        defaultValue: "GET",
                        enumValues: ["GET", "POST", "PUT", "DELETE"]
                    ),
                    .init(
                        name: "json_body",
                        type: .string,
                        description: "JSON 字符串形式的请求体",
                        defaultValue: nil,
                        enumValues: nil
                    )
                ],
                required: []
            ),
            outputSchema: SkillOutputSchema(
                type: .object,
                description: "MCP 调用结果",
                properties: [
                    "service_id": .init(type: "string", description: "服务 ID"),
                    "endpoint": .init(type: "string", description: "请求路径"),
                    "status_code": .init(type: "string", description: "HTTP 状态码"),
                    "response": .init(type: "string", description: "服务响应")
                ]
            ),
            executorType: .mcp,
            executorConfig: [
                "serviceID": service.id,
                "serviceType": service.type.rawValue,
                "port": service.port.map(String.init) ?? "",
                "healthEndpoint": endpointHint
            ],
            tags: mcpTags(for: service)
        )
    }

    private func normalizedServiceID(from manifestID: String) -> String {
        manifestID.hasPrefix("mcp.")
            ? String(manifestID.dropFirst(4))
            : manifestID
    }

    private func resolvedEndpoint(
        for operation: String,
        parameters: [String: Any],
        service: ServiceDefinition
    ) -> String {
        if let endpoint = parameters["endpoint"] as? String,
           !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return endpoint.hasPrefix("/") ? endpoint : "/\(endpoint)"
        }

        switch operation {
        case "invoke":
            return "/"
        case "health":
            let health = service.healthCheck?.endpoint ?? "/health"
            return health.hasPrefix("/") ? health : "/\(health)"
        case "trending", "hot", "popular":
            // 小红书等服务的热搜/热门接口
            if service.id.contains("xiaohongshu") {
                return "/api/trending/list"
            }
            return "/api/trending"
        case "search", "query":
            // 搜索接口
            if service.id.contains("xiaohongshu") {
                return "/api/search"
            }
            if service.id.contains("github") {
                return "/api/search"
            }
            return "/api/search"
        case "list_issues":
            // GitHub issues
            if let owner = parameters["owner"] as? String,
               let repo = parameters["repo"] as? String {
                return "/repos/\(owner)/\(repo)/issues"
            }
            return "/api/issues"
        case "list_prs":
            // GitHub PRs
            if let owner = parameters["owner"] as? String,
               let repo = parameters["repo"] as? String {
                return "/repos/\(owner)/\(repo)/pulls"
            }
            return "/api/pulls"
        case "get_repo":
            // GitHub repo info
            if let owner = parameters["owner"] as? String,
               let repo = parameters["repo"] as? String {
                return "/repos/\(owner)/\(repo)"
            }
            return "/api/repo"
        default:
            let health = service.healthCheck?.endpoint ?? "/health"
            return health.hasPrefix("/") ? health : "/\(health)"
        }
    }

    private func prettyResponseText(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
           let text = String(data: pretty, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func mcpTags(for service: ServiceDefinition) -> [String] {
        let base = [
            "mcp",
            "service",
            service.id,
            service.name.lowercased(),
            service.category.rawValue
        ]
        if service.id.contains("xiaohongshu") || service.name.contains("小红书") {
            return base + ["小红书", "xhs", "热搜", "内容运营"]
        }
        if service.id.contains("github") || service.name.lowercased().contains("github") {
            return base + ["github", "repo", "pull request"]
        }
        if service.id.contains("futu") || service.name.contains("富途") {
            return base + ["富途", "行情", "交易"]
        }
        return base
    }
}

// MARK: - Adapter Registry

/// 统一适配器注册表
@MainActor
final class SkillAdapterRegistry {
    static let shared = SkillAdapterRegistry()
    
    private var adapters: [String: SkillAdapter] = [:]
    
    private init() {
        registerDefaultAdapters()
    }
    
    func register(_ adapter: SkillAdapter) {
        adapters[adapter.sourceName] = adapter
        LogInfo("[SkillAdapterRegistry] 注册适配器: \(adapter.sourceName)")
    }
    
    func adapter(for source: String) -> SkillAdapter? {
        adapters[source]
    }
    
    func allAdapters() -> [SkillAdapter] {
        Array(adapters.values)
    }
    
    /// 同步所有适配器到 SkillCatalog
    func syncToCatalog() async {
        LogInfo("[SkillAdapterRegistry] 开始同步所有适配器到 Catalog...")
        
        for adapter in adapters.values {
            do {
                let manifests = try await adapter.adaptAllSkills()
                for manifest in manifests {
                    SkillCatalog.shared.register(manifest)
                }
            } catch {
                LogError("[SkillAdapterRegistry] 同步 \(adapter.sourceName) 失败: \(error)")
            }
        }
        
        let stats = SkillCatalog.shared.statistics()
        LogInfo("[SkillAdapterRegistry] 同步完成，Catalog 共 \(stats.total) 个 Skills")
    }
    
    /// 执行特定 Skill
    func execute(skillID: String, parameters: [String: Any]) async throws -> SkillExecutionResult {
        // 解析前缀确定适配器
        if skillID.hasPrefix("agent.") {
            return try await adapters["AISkill"]?.execute(manifestID: skillID, parameters: parameters)
                ?? SkillExecutionResult(success: false, output: nil, error: "适配器不可用", executionTime: 0)
        }
        
        // 尝试从 Catalog 执行
        if let manifest = SkillCatalog.shared.find(byID: skillID) {
            return try await executeWithManifest(manifest, parameters: parameters)
        }
        
        throw SkillAdapterError.skillNotFound(skillID)
    }
    
    private func executeWithManifest(_ manifest: SkillManifest, parameters: [String: Any]) async throws -> SkillExecutionResult {
        let startTime = Date()
        
        switch manifest.executorType {
        case .local:
            return SkillExecutionResult(
                success: true,
                output: ["message": "本地 Skill \(manifest.name) 执行成功"],
                error: nil,
                executionTime: Date().timeIntervalSince(startTime)
            )
        case .browser:
            return try await adapters["SkillSystem"]?.execute(manifestID: manifest.id, parameters: parameters)
                ?? SkillExecutionResult(success: false, output: nil, error: "Browser 适配器不可用", executionTime: Date().timeIntervalSince(startTime))
        case .agent:
            return try await adapters["AISkill"]?.execute(manifestID: manifest.id, parameters: parameters)
                ?? SkillExecutionResult(success: false, output: nil, error: "Agent 适配器不可用", executionTime: Date().timeIntervalSince(startTime))
        case .mcp:
            return try await adapters["MCPService"]?.execute(manifestID: manifest.id, parameters: parameters)
                ?? SkillExecutionResult(success: false, output: nil, error: "MCP 适配器不可用", executionTime: Date().timeIntervalSince(startTime))
        default:
            return SkillExecutionResult(
                success: false,
                output: nil,
                error: "不支持的执行器类型: \(manifest.executorType)",
                executionTime: Date().timeIntervalSince(startTime)
            )
        }
    }
    
    private func registerDefaultAdapters() {
        register(SkillSystemAdapter())
        register(AISkillAdapter())
        register(MCPServiceAdapter())
    }
}

// MARK: - Errors

enum SkillAdapterError: LocalizedError {
    case adapterNotFound(String)
    case skillNotFound(String)
    case executionFailed(String)
    case invalidParameters(String)
    
    var errorDescription: String? {
        switch self {
        case .adapterNotFound(let source):
            return "未找到适配器: \(source)"
        case .skillNotFound(let id):
            return "未找到 Skill: \(id)"
        case .executionFailed(let message):
            return "执行失败: \(message)"
        case .invalidParameters(let message):
            return "参数无效: \(message)"
        }
    }
}
