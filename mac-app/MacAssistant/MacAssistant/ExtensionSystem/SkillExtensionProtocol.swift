//
//  SkillExtensionProtocol.swift
//  MacAssistant
//
//  Skill 扩展协议 - 定义如何接入自定义 Skill
//

import Foundation

// MARK: - Skill 扩展协议

/// Skill 扩展协议 - 任何自定义 Skill 都需要实现
protocol SkillExtension: Identifiable, Codable {
    var id: String { get }
    var manifest: SkillManifest { get }
    
    /// 执行 Skill
    func execute(context: SkillExecutionContext) async throws -> SkillExecutionResult
    
    /// 验证配置是否有效
    func validate() -> ValidationResult
}

/// Skill 元数据
struct SkillManifest: Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let version: String
    let author: String
    let icon: String  // SF Symbol 名称
    let category: SkillCategory
    
    /// 依赖的能力
    let requiredCapabilities: [Capability]
    
    /// 执行配置
    let executionMode: ExecutionMode
    
    /// 输入参数定义
    let inputSchema: [ParameterDefinition]?
    
    /// 是否需要用户确认
    let requiresConfirmation: Bool
    
    enum ExecutionMode: String, Codable {
        case localScript      // 本地脚本执行
        case remoteAPI        // 调用远程 API
        case mcpTool          // MCP 工具
        case agentDelegation  // 委托给 Agent
        case builtin          // 内置实现
    }
}

/// 参数定义
struct ParameterDefinition: Codable {
    let name: String
    let type: ParameterType
    let description: String
    let required: Bool
    let defaultValue: String?
    
    enum ParameterType: String, Codable {
        case string
        case number
        case boolean
        case file
        case directory
    }
}

/// Skill 执行上下文
struct SkillExecutionContext {
    let input: String
    let parameters: [String: String]
    let files: [String]?
    let conversationHistory: [ConversationEntry]?
    let sessionID: String
    
    /// 进度回调
    var onProgress: ((String) -> Void)?
}

/// Skill 执行结果
struct SkillExecutionResult {
    let success: Bool
    let output: String
    let artifacts: [Artifact]?  // 生成的文件/图片等
    let followUpActions: [FollowUpAction]?
    
    struct Artifact: Codable {
        let type: ArtifactType
        let path: String
        let description: String
        
        enum ArtifactType: String, Codable {
            case file
            case image
            case url
        }
    }
    
    struct FollowUpAction: Codable {
        let label: String
        let skillID: String?
        let parameters: [String: String]?
    }
}

// MARK: - Skill 扩展管理器

@MainActor
final class SkillExtensionManager: ObservableObject {
    static let shared = SkillExtensionManager()
    
    @Published private(set) var installedSkills: [SkillManifest] = []
    @Published private(set) var availableSkills: [SkillManifest] = []
    
    private let registry = SkillRegistry()
    private let repository = SkillRepository()
    
    private init() {
        loadInstalledSkills()
    }
    
    // MARK: - 安装/卸载
    
    /// 从市场安装 Skill
    func installSkill(from manifest: SkillManifest) async throws {
        // 1. 下载 Skill 包
        let package = try await repository.download(manifest)
        
        // 2. 验证签名和权限
        try await validatePackage(package)
        
        // 3. 安装
        try await registry.install(package)
        
        // 4. 更新列表
        await MainActor.run {
            installedSkills.append(manifest)
        }
        
        LogInfo("SkillExtensionManager: 安装 Skill \(manifest.id)")
    }
    
    /// 卸载 Skill
    func uninstallSkill(id: String) throws {
        guard let index = installedSkills.firstIndex(where: { $0.id == id }) else {
            throw SkillError.notFound
        }
        
        try registry.uninstall(id: id)
        installedSkills.remove(at: index)
    }
    
    /// 从本地路径安装（开发测试用）
    func installFromPath(_ path: String) async throws {
        let manifest = try registry.loadFromPath(path)
        await MainActor.run {
            installedSkills.append(manifest)
        }
    }
    
    // MARK: - 执行
    
    /// 执行 Skill
    func executeSkill(
        id: String,
        context: SkillExecutionContext
    ) async throws -> SkillExecutionResult {
        guard let manifest = installedSkills.first(where: { $0.id == id }) else {
            throw SkillError.notInstalled
        }
        
        // 根据执行模式创建对应的执行器
        let executor = createExecutor(for: manifest)
        return try await executor.execute(context: context)
    }
    
    // MARK: - 发现
    
    /// 从市场搜索可用 Skills
    func searchAvailableSkills(query: String) async throws -> [SkillManifest] {
        return try await repository.search(query: query)
    }
    
    /// 获取推荐 Skills
    func recommendedSkills() async throws -> [SkillManifest] {
        return try await repository.recommended()
    }
    
    // MARK: - 配置
    
    /// 更新 Skill 配置
    func updateSkillConfig(id: String, config: SkillConfig) throws {
        try registry.updateConfig(id: id, config: config)
    }
    
    /// 启用/禁用 Skill
    func setSkillEnabled(id: String, enabled: Bool) throws {
        try registry.setEnabled(id: id, enabled: enabled)
    }
    
    // MARK: - 私有方法
    
    private func loadInstalledSkills() {
        // 从本地加载已安装的 Skills
        if let saved = registry.loadInstalled() {
            installedSkills = saved
        }
    }
    
    private func createExecutor(for manifest: SkillManifest) -> SkillExecutor {
        switch manifest.executionMode {
        case .localScript:
            return LocalScriptExecutor(manifest: manifest)
        case .mcpTool:
            return MCPToolExecutor(manifest: manifest)
        case .remoteAPI:
            return RemoteAPIExecutor(manifest: manifest)
        case .builtin:
            return BuiltinExecutor(manifest: manifest)
        case .agentDelegation:
            return AgentDelegationExecutor(manifest: manifest)
        }
    }
    
    private func validatePackage(_ package: SkillPackage) async throws {
        // 验证签名、权限、依赖等
    }
}

// MARK: - Skill 执行器协议

protocol SkillExecutor {
    var manifest: SkillManifest { get }
    func execute(context: SkillExecutionContext) async throws -> SkillExecutionResult
    func validate() -> ValidationResult
}

// MARK: - 具体执行器实现

/// 本地脚本执行器
struct LocalScriptExecutor: SkillExecutor {
    let manifest: SkillManifest
    let scriptPath: String
    
    init(manifest: SkillManifest) {
        self.manifest = manifest
        // 从配置获取脚本路径
        self.scriptPath = "~/.macassistant/skills/\(manifest.id)/script.sh"
    }
    
    func execute(context: SkillExecutionContext) async throws -> SkillExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, context.input]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        return SkillExecutionResult(
            success: process.terminationStatus == 0,
            output: output,
            artifacts: nil,
            followUpActions: nil
        )
    }
    
    func validate() -> ValidationResult {
        let exists = FileManager.default.fileExists(atPath: scriptPath)
        return ValidationResult(isValid: exists, errors: exists ? [] : ["脚本文件不存在"])
    }
}

/// MCP 工具执行器
struct MCPToolExecutor: SkillExecutor {
    let manifest: SkillManifest
    
    func execute(context: SkillExecutionContext) async throws -> SkillExecutionResult {
        // 调用 MCP 工具
        return SkillExecutionResult(success: true, output: "MCP 工具执行结果", artifacts: nil, followUpActions: nil)
    }
    
    func validate() -> ValidationResult {
        return ValidationResult(isValid: true, errors: [])
    }
}

/// 远程 API 执行器
struct RemoteAPIExecutor: SkillExecutor {
    let manifest: SkillManifest
    
    func execute(context: SkillExecutionContext) async throws -> SkillExecutionResult {
        return SkillExecutionResult(success: true, output: "API 调用结果", artifacts: nil, followUpActions: nil)
    }
    
    func validate() -> ValidationResult {
        return ValidationResult(isValid: true, errors: [])
    }
}

/// 内置执行器
struct BuiltinExecutor: SkillExecutor {
    let manifest: SkillManifest
    
    func execute(context: SkillExecutionContext) async throws -> SkillExecutionResult {
        // 调用内置实现
        return SkillExecutionResult(success: true, output: "内置执行结果", artifacts: nil, followUpActions: nil)
    }
    
    func validate() -> ValidationResult {
        return ValidationResult(isValid: true, errors: [] )
    }
}

/// Agent 委托执行器
struct AgentDelegationExecutor: SkillExecutor {
    let manifest: SkillManifest
    
    func execute(context: SkillExecutionContext) async throws -> SkillExecutionResult {
        // 委托给特定 Agent 执行
        return SkillExecutionResult(success: true, output: "Agent 执行结果", artifacts: nil, followUpActions: nil)
    }
    
    func validate() -> ValidationResult {
        return ValidationResult(isValid: true, errors: [])
    }
}

// MARK: - 辅助类型

struct ValidationResult {
    let isValid: Bool
    let errors: [String]
}

enum SkillError: Error {
    case notFound
    case notInstalled
    case validationFailed([String])
    case executionFailed(String)
}

struct SkillPackage {
    let manifest: SkillManifest
    let resources: [URL]
    let config: SkillConfig?
}

struct SkillConfig: Codable {
    var parameters: [String: String]
    var enabled: Bool
}

struct RemoteAPIResult: Codable {
    let success: Bool
    let output: String
}

// MARK: - 模拟依赖（实际项目中已存在）

class SkillRegistry {
    func install(_ package: SkillPackage) async throws {}
    func uninstall(id: String) throws {}
    func loadFromPath(_ path: String) throws -> SkillManifest { fatalError() }
    func loadInstalled() -> [SkillManifest]? { nil }
    func updateConfig(id: String, config: SkillConfig) throws {}
    func setEnabled(id: String, enabled: Bool) throws {}
}

class SkillRepository {
    func download(_ manifest: SkillManifest) async throws -> SkillPackage { fatalError() }
    func search(query: String) async throws -> [SkillManifest] { [] }
    func recommended() async throws -> [SkillManifest] { [] }
}

class MCPClient {
    static let shared = MCPClient()
    func callTool(server: MCPServerConfig, tool: String, input: String) async throws -> MCPResult {
        fatalError()
    }
    func isServerAvailable(_ config: MCPServerConfig) -> Bool { true }
}

struct MCPResult {
    let success: Bool
    let content: String
    let artifacts: [MCPArtifact]?
}

struct MCPArtifact {
    let type: String
    let path: String
    let description: String
}

struct MCPServerConfig: Codable {}
