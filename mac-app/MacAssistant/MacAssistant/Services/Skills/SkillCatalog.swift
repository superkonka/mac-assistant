//
//  SkillCatalog.swift
//  MacAssistant
//
//  Skill 统一注册表 - 原子能力目录
//

import Foundation

// MARK: - Skill Manifest

/// Skill 清单 - 统一描述原子能力
struct SkillManifest: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let version: String
    
    // 能力描述
    let capabilities: [SkillCapability]
    let inputSchema: SkillInputSchema
    let outputSchema: SkillOutputSchema
    
    // 执行配置
    let executorType: SkillExecutorType
    var executorConfig: [String: String]
    
    // 元数据
    let tags: [String]
    let author: String?
    let createdAt: Date
    var updatedAt: Date
    
    // 内置标记（不可卸载）
    var isBuiltIn: Bool = false
    
    // 可编辑内置 Skill 支持
    var originalVersion: String?      // 内置版本（用于检测更新）
    var hasUserOverride: Bool = false // 是否有用户覆盖
    
    init(
        id: String,
        name: String,
        description: String,
        version: String = "1.0.0",
        capabilities: [SkillCapability],
        inputSchema: SkillInputSchema,
        outputSchema: SkillOutputSchema,
        executorType: SkillExecutorType,
        executorConfig: [String: String] = [:],
        tags: [String] = [],
        author: String? = nil,
        isBuiltIn: Bool = false,
        hasUserOverride: Bool = false,
        originalVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.capabilities = capabilities
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.executorType = executorType
        self.executorConfig = executorConfig
        self.tags = tags
        self.author = author
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isBuiltIn = isBuiltIn
        self.hasUserOverride = hasUserOverride
        self.originalVersion = originalVersion
    }
    
    /// 创建修改后的副本（用于用户覆盖）
    func copyWith(
        name: String? = nil,
        description: String? = nil,
        executorConfig: [String: String]? = nil,
        hasUserOverride: Bool? = nil
    ) -> SkillManifest {
        var copy = SkillManifest(
            id: self.id,
            name: name ?? self.name,
            description: description ?? self.description,
            version: self.version,
            capabilities: self.capabilities,
            inputSchema: self.inputSchema,
            outputSchema: self.outputSchema,
            executorType: self.executorType,
            executorConfig: executorConfig ?? self.executorConfig,
            tags: self.tags,
            author: self.author ?? "User",
            isBuiltIn: self.isBuiltIn,
            hasUserOverride: hasUserOverride ?? self.hasUserOverride,
            originalVersion: self.originalVersion ?? self.version
        )
        copy.updatedAt = Date()
        return copy
    }
}

/// Skill 能力描述
struct SkillCapability: Codable, Equatable, Hashable {
    let domain: String      // 领域：如 "browser", "system", "communication"
    let action: String      // 动作：如 "navigate", "screenshot", "send"
    let resource: String?   // 资源：如 "whatsapp", "email"
    
    var fullIdentifier: String {
        if let resource = resource {
            return "\(domain).\(action).\(resource)"
        }
        return "\(domain).\(action)"
    }
}

/// Skill 输入 schema
struct SkillInputSchema: Codable, Equatable {
    let parameters: [SkillParameter]
    let required: [String]
    
    struct SkillParameter: Codable, Equatable {
        let name: String
        let type: ParameterType
        let description: String
        let defaultValue: String?
        let enumValues: [String]?
        
        enum ParameterType: String, Codable {
            case string
            case number
            case boolean
            case array
            case object
        }
    }
}

/// Skill 输出 schema
struct SkillOutputSchema: Codable, Equatable {
    let type: OutputType
    let description: String
    let properties: [String: OutputProperty]?
    
    enum OutputType: String, Codable {
        case string
        case number
        case boolean
        case object
        case array
        case void
    }
    
    struct OutputProperty: Codable, Equatable {
        let type: String
        let description: String
    }
}

/// Skill 执行器类型
enum SkillExecutorType: String, Codable {
    case local        // 本地 Swift 代码
    case javascript   // JavaScript/AppleScript
    case remote       // 远程 API
    case agent        // Agent 调用
    case browser      // 浏览器操作
    case mcp          // MCP Service
}

// MARK: - Skill Catalog

/// Skill 统一注册表
@MainActor
final class SkillCatalog: ObservableObject {
    static let shared = SkillCatalog()
    
    @Published private(set) var skills: [SkillManifest] = []
    
    private var skillByID: [String: SkillManifest] = [:]
    private var skillsBySkillCapability: [String: [SkillManifest]] = [:]
    private var skillsByTag: [String: [SkillManifest]] = [:]
    
    private init() {
        registerBuiltInSkills()
        registerLegacySkills()
        loadAllOverrides() // 加载用户覆盖（热重载支持）
    }
    
    // MARK: - 注册
    
    func register(_ skill: SkillManifest) {
        skills.removeAll { $0.id == skill.id }
        skills.append(skill)
        
        skillByID[skill.id] = skill
        
        // 按能力索引
        for capability in skill.capabilities {
            let key = capability.fullIdentifier
            if skillsBySkillCapability[key] == nil {
                skillsBySkillCapability[key] = []
            }
            skillsBySkillCapability[key]?.removeAll { $0.id == skill.id }
            skillsBySkillCapability[key]?.append(skill)
        }
        
        // 按标签索引
        for tag in skill.tags {
            if skillsByTag[tag] == nil {
                skillsByTag[tag] = []
            }
            skillsByTag[tag]?.removeAll { $0.id == skill.id }
            skillsByTag[tag]?.append(skill)
        }
        
        LogInfo("[SkillCatalog] 注册 Skill: \(skill.name) (\(skill.id))")
    }
    
    func unregister(id: String) {
        skills.removeAll { $0.id == id }
        skillByID.removeValue(forKey: id)
        
        // 清理索引
        for key in skillsBySkillCapability.keys {
            skillsBySkillCapability[key]?.removeAll { $0.id == id }
        }
        for key in skillsByTag.keys {
            skillsByTag[key]?.removeAll { $0.id == id }
        }
    }
    
    // MARK: - 查询
    
    func find(byID id: String) -> SkillManifest? {
        skillByID[id]
    }
    
    func find(byName name: String) -> SkillManifest? {
        skills.first { $0.name.lowercased() == name.lowercased() }
    }
    
    func find(byCapability domain: String, action: String, resource: String? = nil) -> [SkillManifest] {
        let capability = SkillCapability(domain: domain, action: action, resource: resource)
        return skillsBySkillCapability[capability.fullIdentifier] ?? []
    }
    
    func find(byTag tag: String) -> [SkillManifest] {
        skillsByTag[tag] ?? []
    }
    
    func find(byExecutorType type: SkillExecutorType) -> [SkillManifest] {
        skills.filter { $0.executorType == type }
    }
    
    func search(keyword: String) -> [SkillManifest] {
        let lowercased = keyword.lowercased()
        return skills.filter {
            $0.name.lowercased().contains(lowercased) ||
            $0.description.lowercased().contains(lowercased) ||
            $0.tags.contains { $0.lowercased().contains(lowercased) }
        }
    }
    
    // MARK: - 匹配
    
    /// 根据意图匹配最佳 Skill
    func matchBestSkill(intent: String, context: [String: String] = [:]) -> SkillManifest? {
        let lowercased = intent.lowercased()
        
        // 1. 精确匹配名称
        if let exact = skills.first(where: { $0.name.lowercased() == lowercased }) {
            return exact
        }
        
        // 2. 关键词匹配
        let keywords = extractKeywords(from: intent)
        var scores: [(SkillManifest, Double)] = []
        
        for skill in skills {
            var score = 0.0
            
            // 名称匹配
            if skill.name.lowercased().contains(lowercased) {
                score += 1.0
            }
            
            // 标签匹配
            for keyword in keywords {
                if skill.tags.contains(keyword) {
                    score += 0.5
                }
            }
            
            // 能力匹配
            for capability in skill.capabilities {
                if lowercased.contains(capability.action) {
                    score += 0.3
                }
            }
            
            if score > 0 {
                scores.append((skill, score))
            }
        }
        
        // 返回最高分的 Skill
        return scores.sorted { $0.1 > $1.1 }.first?.0
    }
    
    // MARK: - Skills 文件夹路径
    
    private var skillsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".macassistant/skills", isDirectory: true)
    }
    
    // MARK: - 加载 Skills
    
    private func registerBuiltInSkills() {
        // 确保 Skills 目录存在
        ensureSkillsDirectoryExists()
        
        // 安装内置 Skills 到文件夹（首次运行）
        installBuiltInSkillsToDirectory()
        
        // 从文件夹加载所有 Skills（内置 + 用户）
        loadSkillsFromDirectory()
        
        LogInfo("[SkillCatalog] 已加载 \(skills.count) 个 Skill")
    }
    
    /// 确保 Skills 目录存在
    private func ensureSkillsDirectoryExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: skillsDirectory.path) {
            do {
                try fm.createDirectory(at: skillsDirectory, withIntermediateDirectories: true, attributes: nil)
                LogInfo("[SkillCatalog] 创建 Skills 目录: \(skillsDirectory.path)")
            } catch {
                LogError("[SkillCatalog] 创建目录失败: \(error)")
            }
        }
    }
    
    /// 清理旧的独立 system skills（迁移到 mac.system 聚合版本）
    private func cleanupLegacySystemSkills() {
        let fm = FileManager.default
        let legacySystemSkillIDs = [
            "system.screenshot",
            "system.clipboard", 
            "system.notification",
            "system.volume",
            "system.search"
        ]
        
        for skillID in legacySystemSkillIDs {
            let skillDir = skillsDirectory.appendingPathComponent(skillID, isDirectory: true)
            if fm.fileExists(atPath: skillDir.path) {
                do {
                    try fm.removeItem(at: skillDir)
                    LogInfo("[SkillCatalog] 已清理旧版 Skill: \(skillID)")
                } catch {
                    LogError("[SkillCatalog] 清理旧版 Skill 失败 \(skillID): \(error)")
                }
            }
        }
    }
    
    /// 将内置 Skills 安装到目录
    private func installBuiltInSkillsToDirectory() {
        let fm = FileManager.default
        
        // 清理旧的独立 system skills（迁移到聚合版本）
        cleanupLegacySystemSkills()
        
        // 定义所有内置 Skills
        let builtInSkills: [SkillManifest] = [
            // Mac System Control (聚合 Skill)
            SkillManifest(
                id: "mac.system",
                name: "Mac 系统控制",
                description: "macOS 系统功能聚合：截图、剪贴板、通知、搜索、音量控制",
                capabilities: [
                    SkillCapability(domain: "system", action: "control", resource: nil)
                ],
                inputSchema: SkillInputSchema(
                    parameters: [
                        // 主操作类型
                        .init(name: "action", type: .string, description: "操作类型: screenshot/clipboard/notification/search/volume", defaultValue: nil, enumValues: ["screenshot", "clipboard", "notification", "search", "volume"]),
                        // Screenshot 参数
                        .init(name: "screenshotFilename", type: .string, description: "截图文件名", defaultValue: nil, enumValues: nil),
                        .init(name: "screenshotPath", type: .string, description: "截图保存路径", defaultValue: nil, enumValues: nil),
                        .init(name: "screenshotInteractive", type: .boolean, description: "是否交互式截图（选区）", defaultValue: "false", enumValues: nil),
                        // Clipboard 参数
                        .init(name: "clipboardAction", type: .string, description: "剪贴板操作: read/write/clear", defaultValue: "read", enumValues: ["read", "write", "clear"]),
                        .init(name: "clipboardContent", type: .string, description: "要写入剪贴板的内容", defaultValue: nil, enumValues: nil),
                        // Notification 参数
                        .init(name: "notificationTitle", type: .string, description: "通知标题", defaultValue: nil, enumValues: nil),
                        .init(name: "notificationMessage", type: .string, description: "通知内容", defaultValue: nil, enumValues: nil),
                        .init(name: "notificationSound", type: .string, description: "提示音", defaultValue: "default", enumValues: ["default", "Glass", "Basso", "Hero", "Ping", "Pop", "Submarine"]),
                        // Search 参数
                        .init(name: "searchQuery", type: .string, description: "搜索关键词", defaultValue: nil, enumValues: nil),
                        .init(name: "searchPath", type: .string, description: "搜索路径", defaultValue: ".", enumValues: nil),
                        .init(name: "searchLimit", type: .number, description: "结果数量限制", defaultValue: "20", enumValues: nil),
                        // Volume 参数
                        .init(name: "volumeLevel", type: .number, description: "音量级别 (0-100)", defaultValue: nil, enumValues: nil),
                        .init(name: "volumeAction", type: .string, description: "音量操作: mute/unmute/up/down", defaultValue: nil, enumValues: ["mute", "unmute", "up", "down"])
                    ],
                    required: ["action"]
                ),
                outputSchema: SkillOutputSchema(type: .object, description: "操作结果", properties: [
                    "success": .init(type: "boolean", description: "是否成功"),
                    "action": .init(type: "string", description: "执行的操作"),
                    "data": .init(type: "object", description: "返回数据")
                ]),
                executorType: .local,
                tags: ["system", "mac", "control"]
            ),
            
            // Git Status
            SkillManifest(
                id: "git.status",
                name: "Git 状态检查",
                description: "检查 Git 仓库状态",
                capabilities: [
                    SkillCapability(domain: "development", action: "git_status", resource: nil)
                ],
                inputSchema: SkillInputSchema(
                    parameters: [
                        .init(name: "path", type: .string, description: "仓库路径", defaultValue: ".", enumValues: nil)
                    ],
                    required: []
                ),
                outputSchema: SkillOutputSchema(type: .object, description: "Git 状态", properties: [
                    "branch": .init(type: "string", description: "当前分支"),
                    "changes": .init(type: "array", description: "变更文件")
                ]),
                executorType: .local,
                executorConfig: ["command": "cd {{path}} && git status"],
                tags: ["development", "git"]
            ),
            
            // Port Check
            SkillManifest(
                id: "dev.port_check",
                name: "端口检查",
                description: "检查端口占用情况",
                capabilities: [
                    SkillCapability(domain: "development", action: "port_check", resource: nil)
                ],
                inputSchema: SkillInputSchema(
                    parameters: [
                        .init(name: "port", type: .number, description: "端口号", defaultValue: nil, enumValues: nil)
                    ],
                    required: ["port"]
                ),
                outputSchema: SkillOutputSchema(type: .object, description: "端口信息", properties: [
                    "in_use": .init(type: "boolean", description: "是否被占用"),
                    "process": .init(type: "string", description: "占用进程")
                ]),
                executorType: .local,
                executorConfig: ["command": "lsof -i :{{port}}"],
                tags: ["development", "network"]
            )
        ]
        
        // 保存内置 Skills 到目录
        for var skill in builtInSkills {
            let skillDir = skillsDirectory.appendingPathComponent(skill.id, isDirectory: true)
            let manifestPath = skillDir.appendingPathComponent("manifest.json")
            
            // 如果已存在则跳过（保护用户修改）
            guard !fm.fileExists(atPath: manifestPath.path) else { continue }
            
            // 标记为内置
            skill.isBuiltIn = true
            
            do {
                try fm.createDirectory(at: skillDir, withIntermediateDirectories: true, attributes: nil)
                let data = try JSONEncoder().encode(skill)
                try data.write(to: manifestPath)
                LogInfo("[SkillCatalog] 安装内置 Skill: \(skill.id)")
            } catch {
                LogError("[SkillCatalog] 安装 Skill \(skill.id) 失败: \(error)")
            }
        }
    }
    
    /// 从目录加载所有 Skills
    private func loadSkillsFromDirectory() {
        let fm = FileManager.default
        
        do {
            let skillDirs = try fm.contentsOfDirectory(at: skillsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            
            for skillDir in skillDirs {
                let manifestPath = skillDir.appendingPathComponent("manifest.json")
                
                guard fm.fileExists(atPath: manifestPath.path) else { continue }
                
                do {
                    let data = try Data(contentsOf: manifestPath)
                    let skill = try JSONDecoder().decode(SkillManifest.self, from: data)
                    register(skill)
                } catch {
                    LogError("[SkillCatalog] 加载 Skill 失败 \(manifestPath): \(error)")
                }
            }
        } catch {
            LogError("[SkillCatalog] 读取目录失败: \(error)")
        }
    }
    
    /// 注册旧版 AISkill（兼容性）
    private func registerLegacySkills() {
        // 将旧版 AISkill 转换为 SkillManifest 并注册
        for skill in AISkill.allCases {
            // 检查是否已存在（避免重复）
            guard find(byID: "legacy.\(skill.rawValue)") == nil else { continue }
            
            let manifest = SkillManifest(
                id: "legacy.\(skill.rawValue)",
                name: skill.name,
                description: skill.description,
                capabilities: [
                    SkillCapability(domain: "legacy", action: skill.rawValue, resource: nil)
                ],
                inputSchema: SkillInputSchema(
                    parameters: [],
                    required: []
                ),
                outputSchema: SkillOutputSchema(type: .void, description: "执行结果", properties: nil),
                executorType: .local,
                tags: ["legacy", skill.category.rawValue],
                author: "Built-in"
            )
            
            // 标记为内置且 Legacy
            var modifiedManifest = manifest
            modifiedManifest.isBuiltIn = true
            register(modifiedManifest)
        }
        
        LogInfo("[SkillCatalog] 已注册 \(AISkill.allCases.count) 个 Legacy Skills")
    }
    
    // MARK: - 管理接口
    
    /// 卸载 Skill（删除文件夹）
    func uninstallSkill(id: String) throws {
        let skillDir = skillsDirectory.appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default
        
        guard fm.fileExists(atPath: skillDir.path) else {
            throw SkillError.notFound
        }
        
        do {
            try fm.removeItem(at: skillDir)
            unregister(id: id)
            LogInfo("[SkillCatalog] 卸载 Skill: \(id)")
        } catch {
            throw SkillError.executionFailed("删除失败: \(error.localizedDescription)")
        }
    }
    
    /// 重新安装内置 Skill（恢复到默认）
    func reinstallBuiltInSkill(id: String) throws {
        // 先删除现有的
        let skillDir = skillsDirectory.appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: skillDir)
        
        // 重新安装
        installBuiltInSkillsToDirectory()
        
        // 重新加载
        loadSkillsFromDirectory()
    }
    
    /// 导出 Skill 到路径
    func exportSkill(id: String, to destination: URL) throws {
        guard let skill = find(byID: id) else {
            throw SkillError.notFound
        }
        
        let data = try JSONEncoder().encode(skill)
        try data.write(to: destination)
    }
    
    private func extractKeywords(from text: String) -> [String] {
        // 简单的关键词提取
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { $0.count > 2 }
        return Array(Set(words))
    }
    
    // MARK: - 启用/禁用管理
    
    private let disabledSkillsKey = "skills.disabled"
    
    /// 获取禁用列表
    private var disabledSkills: Set<String> {
        get {
            let array = UserDefaults.standard.array(forKey: disabledSkillsKey) as? [String] ?? []
            return Set(array)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: disabledSkillsKey)
        }
    }
    
    /// 检查 Skill 是否启用
    func isEnabled(id: String) -> Bool {
        !disabledSkills.contains(id)
    }
    
    /// 设置 Skill 启用状态
    func setEnabled(id: String, enabled: Bool) {
        if enabled {
            disabledSkills.remove(id)
        } else {
            disabledSkills.insert(id)
        }
        LogInfo("[SkillCatalog] Skill \(id) \(enabled ? "启用" : "禁用")")
    }
    
    /// 获取所有启用的 Skills
    var enabledSkills: [SkillManifest] {
        skills.filter { isEnabled(id: $0.id) }
    }
    
    // MARK: - 统计
    
    func statistics() -> (total: Int, enabled: Int, byType: [SkillExecutorType: Int], byDomain: [String: Int]) {
        let byType = Dictionary(grouping: skills) { $0.executorType }
            .mapValues { $0.count }
        
        let byDomain = Dictionary(grouping: skills) { skill in
            skill.capabilities.first?.domain ?? "unknown"
        }.mapValues { $0.count }
        
        return (
            total: skills.count,
            enabled: enabledSkills.count,
            byType: byType,
            byDomain: byDomain
        )
    }
}

// MARK: - Skill Override & Hot Reload

extension SkillCatalog {
    
    /// 用户覆盖目录
    private var overridesDirectory: URL {
        skillsDirectory.appendingPathComponent(".overrides", isDirectory: true)
    }
    
    /// 获取覆盖文件路径
    private func overridePath(for skillID: String) -> URL {
        overridesDirectory.appendingPathComponent("\(skillID).json")
    }
    
    /// 保存 Skill 覆盖（用户修改）
    func saveSkillOverride(_ skill: SkillManifest) throws {
        let fm = FileManager.default
        
        // 确保覆盖目录存在
        if !fm.fileExists(atPath: overridesDirectory.path) {
            try fm.createDirectory(at: overridesDirectory, withIntermediateDirectories: true)
        }
        
        // 保存覆盖文件
        var overrideSkill = skill
        overrideSkill.hasUserOverride = true
        overrideSkill.updatedAt = Date()
        
        let data = try JSONEncoder().encode(overrideSkill)
        try data.write(to: overridePath(for: skill.id))
        
        // 重新注册（热重载）
        register(overrideSkill)
        
        LogInfo("[SkillCatalog] 保存 Skill 覆盖: \(skill.id)")
    }
    
    /// 加载 Skill 覆盖
    func loadSkillOverride(for skillID: String) -> SkillManifest? {
        let path = overridePath(for: skillID)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        
        do {
            let data = try Data(contentsOf: path)
            return try JSONDecoder().decode(SkillManifest.self, from: data)
        } catch {
            LogError("[SkillCatalog] 加载覆盖失败 \(skillID): \(error)")
            return nil
        }
    }
    
    /// 检查是否有用户覆盖
    func hasOverride(for skillID: String) -> Bool {
        FileManager.default.fileExists(atPath: overridePath(for: skillID).path)
    }
    
    /// 重置 Skill 到默认（删除覆盖）
    func resetSkillToDefault(id: String) throws {
        let path = overridePath(for: id)
        let fm = FileManager.default
        
        // 删除覆盖文件
        if fm.fileExists(atPath: path.path) {
            try fm.removeItem(at: path)
        }
        
        // 重新从目录加载原始版本
        let skillDir = skillsDirectory.appendingPathComponent(id, isDirectory: true)
        let manifestPath = skillDir.appendingPathComponent("manifest.json")
        
        if fm.fileExists(atPath: manifestPath.path) {
            let data = try Data(contentsOf: manifestPath)
            var skill = try JSONDecoder().decode(SkillManifest.self, from: data)
            skill.hasUserOverride = false
            register(skill)
        }
        
        LogInfo("[SkillCatalog] 重置 Skill 到默认: \(id)")
    }
    
    /// 获取内置 Skill 的原始版本（用于对比）
    func getBuiltInOriginalVersion(id: String) -> SkillManifest? {
        // 从应用 Bundle 中读取原始定义
        // 这里简化处理，从代码中的定义返回
        return builtInSkillDefinitions.first { $0.id == id }
    }
    
    /// 检查内置 Skill 是否有更新
    func checkForBuiltInUpdates() -> [SkillUpdateInfo] {
        var updates: [SkillUpdateInfo] = []
        
        for skill in skills where skill.isBuiltIn {
            guard let original = getBuiltInOriginalVersion(id: skill.id) else { continue }
            
            // 如果原始版本比当前版本新
            if original.version != skill.version {
                let hasOverride = hasOverride(for: skill.id)
                updates.append(SkillUpdateInfo(
                    skillID: skill.id,
                    skillName: skill.name,
                    currentVersion: skill.version,
                    newVersion: original.version,
                    hasUserOverride: hasOverride
                ))
            }
        }
        
        return updates
    }
    
    /// 应用内置 Skill 更新
    func applyBuiltInUpdate(id: String, preserveUserChanges: Bool = false) throws {
        guard let original = getBuiltInOriginalVersion(id: id) else {
            throw SkillError.notFound
        }
        
        if preserveUserChanges, let override = loadSkillOverride(for: id) {
            // 合并逻辑：保留用户的 executorConfig 修改
            var merged = original
            merged.executorConfig = override.executorConfig
            merged.hasUserOverride = true
            try saveSkillOverride(merged)
        } else {
            // 直接覆盖
            try resetSkillToDefault(id: id)
            
            // 更新 manifest 文件
            let skillDir = skillsDirectory.appendingPathComponent(id, isDirectory: true)
            let manifestPath = skillDir.appendingPathComponent("manifest.json")
            var updated = original
            updated.hasUserOverride = false
            let data = try JSONEncoder().encode(updated)
            try data.write(to: manifestPath)
            register(updated)
        }
        
        LogInfo("[SkillCatalog] 应用 Skill 更新: \(id)")
    }
    
    /// 启动时加载所有覆盖
    func loadAllOverrides() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: overridesDirectory.path) else { return }
        
        do {
            let files = try fm.contentsOfDirectory(at: overridesDirectory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                let skillID = file.deletingPathExtension().lastPathComponent
                if let override = loadSkillOverride(for: skillID) {
                    register(override)
                    LogInfo("[SkillCatalog] 加载 Skill 覆盖: \(skillID)")
                }
            }
        } catch {
            LogError("[SkillCatalog] 加载覆盖失败: \(error)")
        }
    }
    
    /// 内置 Skill 定义（用于对比更新）
    private var builtInSkillDefinitions: [SkillManifest] {
        // 这里返回代码中定义的所有内置 skills
        // 实际实现中应该从 Bundle 资源文件读取
        return [] // 占位，实际从代码中提取
    }
}

// MARK: - Skill Update Info

struct SkillUpdateInfo: Identifiable {
    let id = UUID()
    let skillID: String
    let skillName: String
    let currentVersion: String
    let newVersion: String
    let hasUserOverride: Bool
}

// MARK: - Skill Error

enum SkillError: Error {
    case notFound
    case notInstalled
    case validationFailed([String])
    case executionFailed(String)
}
