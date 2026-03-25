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
    let executorConfig: [String: String]
    
    // 元数据
    let tags: [String]
    let author: String?
    let createdAt: Date
    var updatedAt: Date
    
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
        author: String? = nil
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
    
    // MARK: - 内置 Skill
    
    private func registerBuiltInSkills() {
        // MARK: Browser Skills
        
        // Browser Navigate
        register(SkillManifest(
            id: "browser.navigate",
            name: "浏览器导航",
            description: "导航到指定 URL",
            capabilities: [
                SkillCapability(domain: "browser", action: "navigate", resource: nil)
            ],
            inputSchema: SkillInputSchema(
                parameters: [
                    .init(name: "url", type: .string, description: "目标 URL", defaultValue: nil, enumValues: nil)
                ],
                required: ["url"]
            ),
            outputSchema: SkillOutputSchema(type: .object, description: "导航结果", properties: [
                "success": .init(type: "boolean", description: "是否成功"),
                "url": .init(type: "string", description: "最终 URL")
            ]),
            executorType: .browser,
            tags: ["browser", "navigation"]
        ))
        
        // Browser Screenshot
        register(SkillManifest(
            id: "browser.screenshot",
            name: "浏览器截图",
            description: "截取浏览器当前页面",
            capabilities: [
                SkillCapability(domain: "browser", action: "screenshot", resource: nil)
            ],
            inputSchema: SkillInputSchema(
                parameters: [],
                required: []
            ),
            outputSchema: SkillOutputSchema(type: .object, description: "截图结果", properties: [
                "path": .init(type: "string", description: "截图文件路径")
            ]),
            executorType: .browser,
            tags: ["browser", "screenshot"]
        ))
        
        // MARK: System Skills
        
        // System Screenshot
        register(SkillManifest(
            id: "system.screenshot",
            name: "系统截图",
            description: "截取屏幕",
            capabilities: [
                SkillCapability(domain: "system", action: "screenshot", resource: nil)
            ],
            inputSchema: SkillInputSchema(
                parameters: [
                    .init(name: "filename", type: .string, description: "文件名", defaultValue: nil, enumValues: nil),
                    .init(name: "path", type: .string, description: "保存路径", defaultValue: nil, enumValues: nil),
                    .init(name: "interactive", type: .boolean, description: "是否交互式截图（选区）", defaultValue: "false", enumValues: nil)
                ],
                required: []
            ),
            outputSchema: SkillOutputSchema(type: .object, description: "截图结果", properties: [
                "path": .init(type: "string", description: "截图文件路径")
            ]),
            executorType: .local,
            tags: ["system", "screenshot"]
        ))
        
        // System Clipboard
        register(SkillManifest(
            id: "system.clipboard",
            name: "剪贴板操作",
            description: "读取或写入剪贴板内容",
            capabilities: [
                SkillCapability(domain: "system", action: "clipboard", resource: nil)
            ],
            inputSchema: SkillInputSchema(
                parameters: [
                    .init(name: "action", type: .string, description: "操作类型: read/write/clear", defaultValue: "read", enumValues: ["read", "write", "clear"]),
                    .init(name: "content", type: .string, description: "要写入的内容（write时使用）", defaultValue: nil, enumValues: nil)
                ],
                required: []
            ),
            outputSchema: SkillOutputSchema(type: .object, description: "操作结果", properties: [
                "content": .init(type: "string", description: "剪贴板内容"),
                "action": .init(type: "string", description: "执行的操作")
            ]),
            executorType: .local,
            tags: ["system", "clipboard"]
        ))
        
        // System Notification
        register(SkillManifest(
            id: "system.notification",
            name: "系统通知",
            description: "发送 macOS 系统通知",
            capabilities: [
                SkillCapability(domain: "system", action: "notify", resource: nil)
            ],
            inputSchema: SkillInputSchema(
                parameters: [
                    .init(name: "title", type: .string, description: "通知标题", defaultValue: nil, enumValues: nil),
                    .init(name: "message", type: .string, description: "通知内容", defaultValue: nil, enumValues: nil),
                    .init(name: "sound", type: .string, description: "提示音", defaultValue: "default", enumValues: ["default", "Glass", "Basso", "Hero", "Ping", "Pop", "Submarine"])
                ],
                required: ["title"]
            ),
            outputSchema: SkillOutputSchema(type: .void, description: "无返回值", properties: nil),
            executorType: .local,
            tags: ["system", "notification"]
        ))
        
        // System Volume
        register(SkillManifest(
            id: "system.volume",
            name: "音量控制",
            description: "控制系统音量",
            capabilities: [
                SkillCapability(domain: "system", action: "volume", resource: nil)
            ],
            inputSchema: SkillInputSchema(
                parameters: [
                    .init(name: "level", type: .number, description: "音量级别 (0-100)", defaultValue: nil, enumValues: nil),
                    .init(name: "action", type: .string, description: "操作: mute/unmute/up/down", defaultValue: nil, enumValues: ["mute", "unmute", "up", "down"])
                ],
                required: []
            ),
            outputSchema: SkillOutputSchema(type: .object, description: "操作结果", properties: [
                "level": .init(type: "number", description: "当前音量"),
                "muted": .init(type: "boolean", description: "是否静音")
            ]),
            executorType: .local,
            tags: ["system", "audio"]
        ))
        
        // System Search
        register(SkillManifest(
            id: "system.search",
            name: "文件搜索",
            description: "在系统中搜索文件",
            capabilities: [
                SkillCapability(domain: "system", action: "search", resource: nil)
            ],
            inputSchema: SkillInputSchema(
                parameters: [
                    .init(name: "query", type: .string, description: "搜索关键词", defaultValue: nil, enumValues: nil),
                    .init(name: "path", type: .string, description: "搜索路径", defaultValue: ".", enumValues: nil),
                    .init(name: "limit", type: .number, description: "结果数量限制", defaultValue: "20", enumValues: nil)
                ],
                required: ["query"]
            ),
            outputSchema: SkillOutputSchema(type: .object, description: "搜索结果", properties: [
                "files": .init(type: "array", description: "匹配的文件列表")
            ]),
            executorType: .local,
            executorConfig: ["command": "find {{path}} -name '*{{query}}*' 2>/dev/null | head -{{limit}}"],
            tags: ["system", "search", "files"]
        ))
        
        // MARK: Communication Skills
        
        // WhatsApp Send
        register(SkillManifest(
            id: "whatsapp.send",
            name: "WhatsApp 发送消息",
            description: "通过 WhatsApp 网页版发送消息",
            capabilities: [
                SkillCapability(domain: "communication", action: "send", resource: "whatsapp")
            ],
            inputSchema: SkillInputSchema(
                parameters: [
                    .init(name: "contact", type: .string, description: "联系人", defaultValue: nil, enumValues: nil),
                    .init(name: "message", type: .string, description: "消息内容", defaultValue: nil, enumValues: nil)
                ],
                required: ["contact", "message"]
            ),
            outputSchema: SkillOutputSchema(type: .object, description: "发送结果", properties: [
                "success": .init(type: "boolean", description: "是否成功"),
                "messageId": .init(type: "string", description: "消息 ID")
            ]),
            executorType: .browser,
            tags: ["communication", "whatsapp"]
        ))
        
        // MARK: Development Skills
        
        // Git Status
        register(SkillManifest(
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
        ))
        
        // Port Check
        register(SkillManifest(
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
        ))
        
        LogInfo("[SkillCatalog] 已注册 \(skills.count) 个内置 Skill")
    }
    
    private func extractKeywords(from text: String) -> [String] {
        // 简单的关键词提取
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { $0.count > 2 }
        return Array(Set(words))
    }
    
    // MARK: - 统计
    
    func statistics() -> (total: Int, byType: [SkillExecutorType: Int], byDomain: [String: Int]) {
        let byType = Dictionary(grouping: skills) { $0.executorType }
            .mapValues { $0.count }
        
        let byDomain = Dictionary(grouping: skills) { skill in
            skill.capabilities.first?.domain ?? "unknown"
        }.mapValues { $0.count }
        
        return (total: skills.count, byType: byType, byDomain: byDomain)
    }
}
