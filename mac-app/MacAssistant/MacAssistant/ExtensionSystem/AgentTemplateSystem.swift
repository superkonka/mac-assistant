//
//  AgentTemplateSystem.swift
//  MacAssistant
//
//  Agent 模板系统 - 快速创建和定制 Agent
//

import Foundation

// MARK: - Agent 模板

/// Agent 模板 - 预配置的 Agent 蓝图
struct AgentTemplate: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let emoji: String
    let category: AgentCategory
    
    /// 基础配置
    let baseConfig: BaseAgentConfiguration
    
    /// 系统提示词模板
    let systemPromptTemplate: String
    
    /// 可定制变量
    let customizableFields: [CustomizableField]
    
    /// 推荐模型
    let recommendedModels: [String]
    
    /// 所需能力
    let capabilities: [Capability]
    
    enum AgentCategory: String, Codable, CaseIterable {
        case programming = "编程开发"
        case writing = "写作辅助"
        case analysis = "数据分析"
        case creative = "创意设计"
        case business = "商业办公"
        case system = "系统工具"
        case custom = "自定义"
    }
    
    struct CustomizableField: Codable {
        let key: String
        let label: String
        let description: String
        let type: FieldType
        let defaultValue: String
        let required: Bool
        
        enum FieldType: String, Codable {
            case text
            case textarea  // 多行文本
            case select    // 下拉选择
            case multiselect // 多选
            case number
            case boolean
        }
    }
}

/// 基础 Agent 配置
struct BaseAgentConfiguration: Codable {
    let temperature: Double
    let maxTokens: Int
    let topP: Double?
    let presencePenalty: Double?
    let frequencyPenalty: Double?
    let responseFormat: ResponseFormat?
    
    enum ResponseFormat: String, Codable {
        case text
        case json
        case markdown
    }
}

// MARK: - 预设模板

extension AgentTemplate {
    /// 内置模板库
    static let builtinTemplates: [AgentTemplate] = [
        // 编程开发类
        codingExpert,
        codeReviewer,
        debugAssistant,
        
        // 写作辅助类
        writingAssistant,
        translator,
        editor,
        
        // 数据分析类
        dataAnalyst,
        sqlExpert,
        
        // 系统工具类
        shellExpert,
        devOpsEngineer,
        
        // 创意设计类
        uiDesigner,
        promptEngineer,
        
        // 商业办公类
        meetingAssistant,
        researchAnalyst
    ]
    
    /// 代码专家
    static let codingExpert = AgentTemplate(
        id: "coding-expert",
        name: "代码专家",
        description: "专注于代码编写、重构和最佳实践建议",
        emoji: "👨‍💻",
        category: .programming,
        baseConfig: BaseAgentConfiguration(
            temperature: 0.2,
            maxTokens: 4096,
            topP: 0.95,
            presencePenalty: 0.1,
            frequencyPenalty: 0.1,
            responseFormat: .markdown
        ),
        systemPromptTemplate: """
        你是一位经验丰富的 {{language}} 开发专家。你的专长包括：
        
        {{specializations}}
        
        在回答时请：
        1. 提供清晰、可维护的代码
        2. 遵循 {{language}} 的最佳实践和惯用写法
        3. 解释关键设计决策
        4. 指出潜在的性能问题或边界情况
        5. 如果适用，提供单元测试示例
        
        风格偏好：{{stylePreference}}
        """,
        customizableFields: [
            .init(
                key: "language",
                label: "编程语言",
                description: "你主要使用的编程语言",
                type: .select,
                defaultValue: "Swift",
                required: true
            ),
            .init(
                key: "specializations",
                label: "专长领域",
                description: "选择你的技术栈和专长",
                type: .multiselect,
                defaultValue: "iOS开发, SwiftUI, 系统架构",
                required: false
            ),
            .init(
                key: "stylePreference",
                label: "代码风格",
                description: "偏好的代码风格",
                type: .select,
                defaultValue: "简洁优雅",
                required: false
            )
        ],
        recommendedModels: ["gpt-4o", "claude-3-opus", "kimi-k2.5"],
        capabilities: [.textChat, .codeAnalysis, .fileOperations]
    )
    
    /// 代码审查专家
    static let codeReviewer = AgentTemplate(
        id: "code-reviewer",
        name: "代码审查员",
        description: "专注于代码审查、发现潜在问题和改进建议",
        emoji: "🔍",
        category: .programming,
        baseConfig: BaseAgentConfiguration(
            temperature: 0.1,
            maxTokens: 4096,
            topP: 0.9,
            presencePenalty: 0.0,
            frequencyPenalty: 0.0,
            responseFormat: .markdown
        ),
        systemPromptTemplate: """
        你是一位严格的代码审查员。你的职责是：
        
        1. 发现潜在的 bugs 和逻辑错误
        2. 检查安全漏洞（{{securityLevel}}级别）
        3. 评估代码可读性和可维护性
        4. 检查是否符合 {{codingStandard}}
        5. 识别性能瓶颈
        6. 验证边界情况处理
        
        审查维度：{{reviewDimensions}}
        
        输出格式：
        - 🔴 严重问题（必须修复）
        - 🟡 建议改进（推荐修复）
        - 🟢 良好实践（保持）
        """,
        customizableFields: [
            .init(
                key: "securityLevel",
                label: "安全检查级别",
                description: "安全审查的严格程度",
                type: .select,
                defaultValue: "标准",
                required: true
            ),
            .init(
                key: "codingStandard",
                label: "编码规范",
                description: "遵循的编码规范",
                type: .select,
                defaultValue: "团队规范",
                required: false
            ),
            .init(
                key: "reviewDimensions",
                label: "审查维度",
                description: "重点关注的审查方面",
                type: .multiselect,
                defaultValue: "功能正确性,代码可读性,性能优化",
                required: false
            )
        ],
        recommendedModels: ["gpt-4o", "claude-3-opus"],
        capabilities: [.textChat, .codeAnalysis]
    )
    
    /// 调试助手
    static let debugAssistant = AgentTemplate(
        id: "debug-assistant",
        name: "调试助手",
        description: "帮助定位问题、分析日志和提供修复建议",
        emoji: "🐛",
        category: .programming,
        baseConfig: BaseAgentConfiguration(
            temperature: 0.3,
            maxTokens: 4096,
            topP: 0.95,
            presencePenalty: 0.0,
            frequencyPenalty: 0.0,
            responseFormat: .markdown
        ),
        systemPromptTemplate: """
        你是一位调试专家。帮助用户解决技术问题：
        
        1. 分析错误信息和日志
        2. 提供系统性的排查步骤
        3. 给出具体的修复建议
        4. 解释问题根因
        5. 预防类似问题的建议
        
        技术栈：{{techStack}}
        
        调试方法：先观察现象 → 定位范围 → 缩小问题 → 验证假设 → 实施修复
        """,
        customizableFields: [
            .init(
                key: "techStack",
                label: "技术栈",
                description: "你主要使用的技术栈",
                type: .multiselect,
                defaultValue: "Swift, iOS, Xcode",
                required: true
            )
        ],
        recommendedModels: ["gpt-4o", "claude-3-sonnet"],
        capabilities: [.textChat, .codeAnalysis]
    )
    
    /// 写作助手
    static let writingAssistant = AgentTemplate(
        id: "writing-assistant",
        name: "写作助手",
        description: "帮助撰写、润色和优化各类文本",
        emoji: "✍️",
        category: .writing,
        baseConfig: BaseAgentConfiguration(
            temperature: 0.7,
            maxTokens: 4096,
            topP: 0.95,
            presencePenalty: 0.2,
            frequencyPenalty: 0.2,
            responseFormat: .text
        ),
        systemPromptTemplate: """
        你是一位专业的写作助手。擅长：
        
        1. {{writingType}} 的撰写和润色
        2. 结构调整和逻辑优化
        3. 语言风格和语气调整
        4. 语法和拼写检查
        5. 表达简化和清晰化
        
        目标受众：{{targetAudience}}
        语气风格：{{tone}}
        
        保持原文核心意思，同时提升表达质量。
        """,
        customizableFields: [
            .init(
                key: "writingType",
                label: "写作类型",
                description: "主要协助的写作类型",
                type: .select,
                defaultValue: "技术文档",
                required: true
            ),
            .init(
                key: "targetAudience",
                label: "目标受众",
                description: "文章的目标读者",
                type: .select,
                defaultValue: "技术人员",
                required: false
            ),
            .init(
                key: "tone",
                label: "语气风格",
                description: "写作的语气",
                type: .select,
                defaultValue: "专业且友好",
                required: false
            )
        ],
        recommendedModels: ["claude-3-sonnet", "gpt-4o"],
        capabilities: [.textChat]
    )
    
    /// 翻译专家
    static let translator = AgentTemplate(
        id: "translator",
        name: "翻译专家",
        description: "专业的多语言翻译和本地化",
        emoji: "🌐",
        category: .writing,
        baseConfig: BaseAgentConfiguration(
            temperature: 0.3,
            maxTokens: 4096,
            topP: 0.95,
            presencePenalty: 0.1,
            frequencyPenalty: 0.1,
            responseFormat: .text
        ),
        systemPromptTemplate: """
        你是一位专业翻译。请遵循以下原则：
        
        1. 准确传达原文意思，不只是字面翻译
        2. 使用 {{targetLanguage}} 的地道表达
        3. 保持 {{domain}} 领域的专业术语准确
        4. 注意文化差异和本地化
        5. 保持原文的语气和风格
        
        源语言：自动检测
        目标语言：{{targetLanguage}}
        
        如遇到多义词，请选择最符合上下文的含义。
        """,
        customizableFields: [
            .init(
                key: "targetLanguage",
                label: "目标语言",
                description: "翻译成的语言",
                type: .select,
                defaultValue: "中文",
                required: true
            ),
            .init(
                key: "domain",
                label: "专业领域",
                description: "翻译内容所属领域",
                type: .select,
                defaultValue: "技术",
                required: false
            )
        ],
        recommendedModels: ["gpt-4o", "claude-3-sonnet"],
        capabilities: [.textChat]
    )
    
    /// 数据分析专家
    static let dataAnalyst = AgentTemplate(
        id: "data-analyst",
        name: "数据分析师",
        description: "分析数据、生成报告和可视化建议",
        emoji: "📊",
        category: .analysis,
        baseConfig: BaseAgentConfiguration(
            temperature: 0.2,
            maxTokens: 4096,
            topP: 0.9,
            presencePenalty: 0.0,
            frequencyPenalty: 0.0,
            responseFormat: .markdown
        ),
        systemPromptTemplate: """
        你是一位数据分析师。擅长：
        
        1. 数据清洗和预处理建议
        2. 统计分析和假设检验
        3. 趋势识别和异常检测
        4. 数据可视化方案
        5. 业务洞察和建议
        
        分析工具：{{tools}}
        输出格式：清晰的数据解读 + 可视化建议 + 行动建议
        
        注意：不直接处理敏感数据，提供分析方法即可。
        """,
        customizableFields: [
            .init(
                key: "tools",
                label: "分析工具",
                description: "使用的数据分析工具",
                type: .multiselect,
                defaultValue: "Python, Pandas, SQL",
                required: false
            )
        ],
        recommendedModels: ["gpt-4o", "claude-3-opus"],
        capabilities: [.textChat, .codeAnalysis]
    )
    
    /// Shell 专家
    static let shellExpert = AgentTemplate(
        id: "shell-expert",
        name: "Shell 专家",
        description: "帮助编写和解释命令行脚本",
        emoji: "🖥️",
        category: .system,
        baseConfig: BaseAgentConfiguration(
            temperature: 0.1,
            maxTokens: 4096,
            topP: 0.9,
            presencePenalty: 0.0,
            frequencyPenalty: 0.0,
            responseFormat: .markdown
        ),
        systemPromptTemplate: """
        你是一位命令行专家。专注于 {{shellType}}。
        
        提供：
        1. 高效的命令和管道组合
        2. 自动化脚本编写
        3. 系统管理任务
        4. 故障排查命令
        5. 安全性检查
        
        系统环境：{{osType}}
        
        ⚠️ 安全提醒：执行前请确认理解命令含义，特别是涉及删除或修改的命令。
        """,
        customizableFields: [
            .init(
                key: "shellType",
                label: "Shell 类型",
                description: "使用的 Shell",
                type: .select,
                defaultValue: "zsh",
                required: true
            ),
            .init(
                key: "osType",
                label: "操作系统",
                description: "当前操作系统",
                type: .select,
                defaultValue: "macOS",
                required: true
            )
        ],
        recommendedModels: ["gpt-4o", "claude-3-sonnet"],
        capabilities: [.textChat, .codeAnalysis, .localExecution]
    )
    
    /// DevOps 工程师
    static let devOpsEngineer = AgentTemplate(
        id: "devops-engineer",
        name: "DevOps 助手",
        description: "协助 CI/CD、容器化和基础设施管理",
        emoji: "🚀",
        category: .system,
        baseConfig: BaseAgentConfiguration(
            temperature: 0.2,
            maxTokens: 4096,
            topP: 0.95,
            presencePenalty: 0.0,
            frequencyPenalty: 0.0,
            responseFormat: .markdown
        ),
        systemPromptTemplate: """
        你是一位 DevOps 工程师。专长：
        
        1. Docker 和容器化
        2. CI/CD 流水线设计
        3. 基础设施即代码
        4. 监控和日志方案
        5. 云平台配置
        
        技术栈：{{techStack}}
        
        提供实用的配置示例和最佳实践。
        """,
        customizableFields: [
            .init(
                key: "techStack",
                label: "技术栈",
                description: "使用的 DevOps 工具",
                type: .multiselect,
                defaultValue: "Docker, Kubernetes, GitHub Actions",
                required: true
            )
        ],
        recommendedModels: ["gpt-4o", "claude-3-opus"],
        capabilities: [.textChat, .codeAnalysis, .fileOperations]
    )
    
    /// 会议助手
    static let meetingAssistant = AgentTemplate(
        id: "meeting-assistant",
        name: "会议助手",
        description: "整理会议纪要、提取行动项",
        emoji: "📝",
        category: .business,
        baseConfig: BaseAgentConfiguration(
            temperature: 0.4,
            maxTokens: 4096,
            topP: 0.9,
            presencePenalty: 0.1,
            frequencyPenalty: 0.1,
            responseFormat: .markdown
        ),
        systemPromptTemplate: """
        你是一位高效的会议助手。帮助：
        
        1. 整理会议纪要和要点
        2. 提取行动项和负责人
        3. 识别决策和共识
        4. 标注待跟进事项
        5. 生成会议摘要
        
        会议类型：{{meetingType}}
        
        输出结构：
        - 会议基本信息
        - 讨论要点
        - 决策事项
        - 行动项（负责人+截止日期）
        - 下次会议安排
        """,
        customizableFields: [
            .init(
                key: "meetingType",
                label: "会议类型",
                description: "常见的会议类型",
                type: .select,
                defaultValue: "周会",
                required: false
            )
        ],
        recommendedModels: ["claude-3-sonnet", "gpt-4o"],
        capabilities: [.textChat]
    )
    
    /// UI 设计师
    static let uiDesigner = AgentTemplate(
        id: "ui-designer",
        name: "UI 设计师",
        description: "提供界面设计建议和代码实现",
        emoji: "🎨",
        category: .creative,
        baseConfig: BaseAgentConfiguration(
            temperature: 0.6,
            maxTokens: 4096,
            topP: 0.95,
            presencePenalty: 0.2,
            frequencyPenalty: 0.2,
            responseFormat: .markdown
        ),
        systemPromptTemplate: """
        你是一位 UI/UX 设计师。擅长：
        
        1. 界面布局和视觉设计
        2. SwiftUI 代码实现
        3. 交互设计建议
        4. 设计系统构建
        5. 可访问性考虑
        
        设计平台：{{platform}}
        设计风格：{{style}}
        
        提供具体的代码示例和视觉描述。
        """,
        customizableFields: [
            .init(
                key: "platform",
                label: "设计平台",
                description: "目标平台",
                type: .select,
                defaultValue: "iOS (SwiftUI)",
                required: true
            ),
            .init(
                key: "style",
                label: "设计风格",
                description: "偏好的设计风格",
                type: .select,
                defaultValue: "现代简洁",
                required: false
            )
        ],
        recommendedModels: ["gpt-4o", "claude-3-sonnet"],
        capabilities: [.textChat, .codeAnalysis, .vision]
    )
    
    /// Prompt 工程师
    static let promptEngineer = AgentTemplate(
        id: "prompt-engineer",
        name: "Prompt 工程师",
        description: "优化和调试 AI 提示词",
        emoji: "🎯",
        category: .creative,
        baseConfig: BaseAgentConfiguration(
            temperature: 0.4,
            maxTokens: 4096,
            topP: 0.95,
            presencePenalty: 0.0,
            frequencyPenalty: 0.0,
            responseFormat: .markdown
        ),
        systemPromptTemplate: """
        你是一位 Prompt 工程专家。帮助：
        
        1. 分析和优化现有提示词
        2. 设计结构化的 Prompt
        3. 添加 Few-shot 示例
        4. 处理边缘情况
        5. 测试和迭代建议
        
        优化原则：清晰具体、结构化、可验证
        
        输出格式：
        - 问题诊断
        - 优化建议
        - 改进后的 Prompt
        - 使用示例
        """,
        customizableFields: [],
        recommendedModels: ["gpt-4o", "claude-3-opus"],
        capabilities: [.textChat]
    )
    
    /// 研究分析师
    static let researchAnalyst = AgentTemplate(
        id: "research-analyst",
        name: "研究分析师",
        description: "深度研究、信息整合和报告撰写",
        emoji: "🔬",
        category: .business,
        baseConfig: BaseAgentConfiguration(
            temperature: 0.3,
            maxTokens: 4096,
            topP: 0.95,
            presencePenalty: 0.1,
            frequencyPenalty: 0.1,
            responseFormat: .markdown
        ),
        systemPromptTemplate: """
        你是一位研究分析师。擅长：
        
        1. 深度主题研究
        2. 多源信息整合
        3. 趋势分析
        4. 竞品分析
        5. 研究报告撰写
        
        研究领域：{{field}}
        
        研究方法：
        - 系统性文献回顾
        - 数据驱动分析
        - 多维度评估
        - 批判性思维
        """,
        customizableFields: [
            .init(
                key: "field",
                label: "研究领域",
                description: "专注的研究方向",
                type: .select,
                defaultValue: "技术趋势",
                required: true
            )
        ],
        recommendedModels: ["gpt-4o", "claude-3-opus"],
        capabilities: [.textChat, .webSearch]
    )
}

// MARK: - Agent 模板管理器

@MainActor
final class AgentTemplateManager: ObservableObject {
    static let shared = AgentTemplateManager()
    
    @Published var templates: [AgentTemplate] = []
    @Published var customTemplates: [AgentTemplate] = []
    
    private init() {
        loadTemplates()
    }
    
    /// 加载所有模板
    private func loadTemplates() {
        // 加载内置模板
        templates = AgentTemplate.builtinTemplates
        
        // 加载用户自定义模板
        if let saved = loadCustomTemplates() {
            customTemplates = saved
        }
    }
    
    /// 根据 ID 获取模板
    func template(id: String) -> AgentTemplate? {
        templates.first { $0.id == id } ?? customTemplates.first { $0.id == id }
    }
    
    /// 按分类获取模板
    func templates(in category: AgentTemplate.AgentCategory) -> [AgentTemplate] {
        templates.filter { $0.category == category }
    }
    
    /// 搜索模板
    func search(query: String) -> [AgentTemplate] {
        let all = templates + customTemplates
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.description.localizedCaseInsensitiveContains(query)
        }
    }
    
    /// 从模板创建 Agent
    func createAgent(
        from template: AgentTemplate,
        customizations: [String: String],
        provider: ProviderType,
        model: String,
        apiKey: String
    ) async throws -> Agent {
        
        // 1. 生成系统提示词
        let systemPrompt = renderTemplate(
            template.systemPromptTemplate,
            with: customizations
        )
        
        // 2. 创建 Agent
        let agent = Agent(
            name: customizations["name"] ?? template.name,
            emoji: template.emoji,
            description: template.description,
            provider: provider,
            model: model,
            capabilities: template.capabilities,
            config: AgentConfig(
                temperature: template.baseConfig.temperature,
                maxTokens: template.baseConfig.maxTokens,
                topP: template.baseConfig.topP,
                presencePenalty: template.baseConfig.presencePenalty,
                frequencyPenalty: template.baseConfig.frequencyPenalty
            )
        )
        
        // 3. 保存系统提示词配置
        // ...
        
        return agent
    }
    
    /// 保存自定义模板
    func saveCustomTemplate(_ template: AgentTemplate) throws {
        customTemplates.append(template)
        persistCustomTemplates()
    }
    
    /// 删除自定义模板
    func deleteCustomTemplate(id: String) {
        customTemplates.removeAll { $0.id == id }
        persistCustomTemplates()
    }
    
    // MARK: - 私有方法
    
    private func renderTemplate(_ template: String, with values: [String: String]) -> String {
        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }
    
    private func loadCustomTemplates() -> [AgentTemplate]? {
        guard let data = UserDefaults.standard.data(forKey: "customAgentTemplates"),
              let templates = try? JSONDecoder().decode([AgentTemplate].self, from: data) else {
            return nil
        }
        return templates
    }
    
    private func persistCustomTemplates() {
        if let data = try? JSONEncoder().encode(customTemplates) {
            UserDefaults.standard.set(data, forKey: "customAgentTemplates")
        }
    }
}
