//
//  SkillRegistry.swift
//  MacAssistant
//
//  轻量级 Skill 注册表
//  只管理 Skill 声明和 UI 展示，不执行 Skill
//

import Foundation
import Combine

/// Skill 清单（声明式）
/// 只包含元数据，不包含执行逻辑
struct SkillManifest: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let version: String
    let author: String?
    let icon: String?  // SF Symbol 名称或 URL
    
    // 能力要求
    let requiredCapabilities: [CapabilityTag]
    
    // 参数定义（用于 UI 展示和验证）
    let parameters: [ParameterSchema]
    
    // 元数据
    let isBuiltin: Bool
    let isInstalled: Bool
    let installSource: String?  // 安装来源（builtin/marketplace/local）
    
    struct ParameterSchema: Codable {
        let name: String
        let type: ParameterType
        let description: String
        let required: Bool
        let defaultValue: String?
        let enumValues: [String]?  // 枚举值（如果有）
    }
    
    enum ParameterType: String, Codable {
        case string
        case number
        case boolean
        case file
        case directory
        case url
        case enum_type = "enum"
    }
}

/// Skill 注册表
/// 职责：
/// 1. 管理 Skill 清单（CRUD）
/// 2. 提供 Skill 浏览器功能
/// 3. 安装/卸载 Skill（委托给 OpenClaw Core）
/// 4. 不执行 Skill，只展示和配置
class SkillRegistry: ObservableObject {
    static let shared = SkillRegistry()
    
    // MARK: - 状态
    
    @Published private(set) var installedSkills: [SkillManifest] = []
    @Published private(set) var builtinSkills: [SkillManifest] = []
    @Published private(set) var isLoading: Bool = false
    
    // MARK: - 依赖
    
    // 轻量级注册表，实际 Skill 执行由 OpenClaw Core 处理
    
    // MARK: - 初始化
    
    init() {
        loadBuiltinSkills()
        syncFromOpenClaw()
    }
    
    // MARK: - 查询
    
    /// 获取所有可用 Skills
    var allSkills: [SkillManifest] {
        builtinSkills + installedSkills
    }
    
    /// 根据 ID 获取 Skill
    func get(_ skillId: String) -> SkillManifest? {
        allSkills.first { $0.id == skillId }
    }
    
    /// 根据能力标签筛选 Skills
    func skills(for capability: CapabilityTag) -> [SkillManifest] {
        allSkills.filter { $0.requiredCapabilities.contains(capability) }
    }
    
    /// 搜索 Skills
    func search(query: String) -> [SkillManifest] {
        let lowerQuery = query.lowercased()
        return allSkills.filter {
            $0.name.lowercased().contains(lowerQuery) ||
            $0.description.lowercased().contains(lowerQuery) ||
            $0.id.lowercased().contains(lowerQuery)
        }
    }
    
    /// 检查 Skill 是否已安装
    func isInstalled(_ skillId: String) -> Bool {
        installedSkills.contains { $0.id == skillId } ||
        builtinSkills.contains { $0.id == skillId }
    }
    
    // MARK: - 管理操作
    
    /// 安装 Skill
    /// 实际安装由 OpenClaw Core 执行
    func install(from source: SkillSource) async throws {
        isLoading = true
        defer { isLoading = false }
        
        switch source {
        case .marketplace(let skillId):
            // 从 ClawHub Marketplace 安装
            // 1. 获取 Skill 元数据
            // 2. 委托给 OpenClaw Core 安装
            // 3. 刷新本地列表
            try await installFromMarketplace(skillId)
            
        case .local(let path):
            // 从本地路径安装
            try await installFromLocal(path)
            
        case .url(let url):
            // 从 URL 安装
            try await installFromURL(url)
        }
        
        // 刷新列表
        await syncFromOpenClaw()
    }
    
    /// 卸载 Skill
    func uninstall(_ skillId: String) async throws {
        guard !isBuiltin(skillId) else {
            throw SkillError.cannotUninstallBuiltin
        }
        
        // 委托给 OpenClaw Core 卸载
        // await gateway.uninstallSkill(skillId)
        
        // 刷新列表
        await syncFromOpenClaw()
    }
    
    /// 更新 Skill
    func update(_ skillId: String) async throws {
        guard let skill = get(skillId) else {
            throw SkillError.skillNotFound
        }
        
        // 委托给 OpenClaw Core 更新
        // await gateway.updateSkill(skillId)
        
        await syncFromOpenClaw()
    }
    
    /// 启用/禁用 Skill
    func setEnabled(_ skillId: String, enabled: Bool) {
        // 更新本地配置
        // 同步到 OpenClaw Core
    }
    
    // MARK: - 内置 Skills
    
    /// 获取内置 Skills
    private func loadBuiltinSkills() {
        builtinSkills = [
            SkillManifest(
                id: "builtin.file",
                name: "文件操作",
                description: "读取、写入、搜索文件",
                version: "1.0.0",
                author: "MacAssistant",
                icon: "doc.text",
                requiredCapabilities: [.text],
                parameters: [
                    .init(name: "action", type: .enum_type, description: "操作类型", required: true, defaultValue: "read", enumValues: ["read", "write", "list", "search"]),
                    .init(name: "path", type: .file, description: "文件路径", required: true, defaultValue: nil, enumValues: nil)
                ],
                isBuiltin: true,
                isInstalled: true,
                installSource: "builtin"
            ),
            SkillManifest(
                id: "builtin.web",
                name: "网页搜索",
                description: "搜索网页内容",
                version: "1.0.0",
                author: "MacAssistant",
                icon: "globe",
                requiredCapabilities: [.text],
                parameters: [
                    .init(name: "query", type: .string, description: "搜索关键词", required: true, defaultValue: nil, enumValues: nil)
                ],
                isBuiltin: true,
                isInstalled: true,
                installSource: "builtin"
            ),
            SkillManifest(
                id: "builtin.screenshot",
                name: "截图分析",
                description: "截取屏幕并分析",
                version: "1.0.0",
                author: "MacAssistant",
                icon: "camera",
                requiredCapabilities: [.vision],
                parameters: [],
                isBuiltin: true,
                isInstalled: true,
                installSource: "builtin"
            ),
            SkillManifest(
                id: "builtin.git",
                name: "Git 操作",
                description: "Git 状态查看、提交等",
                version: "1.0.0",
                author: "MacAssistant",
                icon: "arrow.triangle.branch",
                requiredCapabilities: [.code],
                parameters: [
                    .init(name: "command", type: .enum_type, description: "Git 命令", required: true, defaultValue: "status", enumValues: ["status", "log", "diff", "commit"])
                ],
                isBuiltin: true,
                isInstalled: true,
                installSource: "builtin"
            ),
            SkillManifest(
                id: "builtin.app",
                name: "应用控制",
                description: "启动、控制 macOS 应用",
                version: "1.0.0",
                author: "MacAssistant",
                icon: "app",
                requiredCapabilities: [.text],
                parameters: [
                    .init(name: "action", type: .enum_type, description: "操作", required: true, defaultValue: "list", enumValues: ["list", "launch", "quit", "activate"]),
                    .init(name: "appName", type: .string, description: "应用名称", required: false, defaultValue: nil, enumValues: nil)
                ],
                isBuiltin: true,
                isInstalled: true,
                installSource: "builtin"
            )
        ]
    }
    
    // MARK: - 同步
    
    /// 从 OpenClaw Core 同步已安装的 Skills
    /// 应用层只展示，安装/卸载都在 Core 层处理
    func syncFromOpenClaw() async {
        // 从 Gateway 获取已安装 Skill 列表
        // 简化实现，实际应该调用 Gateway API (tools.catalog)
    }
    
    // MARK: - 私有方法
    
    private func isBuiltin(_ skillId: String) -> Bool {
        builtinSkills.contains { $0.id == skillId }
    }
    
    private func installFromMarketplace(_ skillId: String) async throws {
        // Marketplace 安装通过 OpenClaw Core 处理
    }
    
    private func installFromLocal(_ path: String) async throws {
        // 本地安装通过 OpenClaw Core 处理
    }
    
    private func installFromURL(_ url: URL) async throws {
        // URL 安装通过 OpenClaw Core 处理
    }
}

// MARK: - 类型定义

enum SkillSource {
    case marketplace(skillId: String)
    case local(path: String)
    case url(URL)
}

enum SkillError: Error {
    case skillNotFound
    case cannotUninstallBuiltin
    case installationFailed(String)
    case updateFailed(String)
}
