import Foundation

// MARK: - Bundle Models
// 对应 OpenClaw 的 Bundle 数据结构

/// Bundle 类型
enum BundleType: String, CaseIterable, Codable, Identifiable {
    case codex = "codex"
    case claude = "claude"
    case cursor = "cursor"
    case custom = "custom"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        case .custom: return "自定义"
        }
    }
    
    var icon: String {
        switch self {
        case .codex: return "cpu"
        case .claude: return "person.fill"
        case .cursor: return "cursorarrow"
        case .custom: return "cube.box"
        }
    }
    
    var description: String {
        switch self {
        case .codex:
            return "OpenAI Codex 编码助手，支持代码生成、重构和解释"
        case .claude:
            return "Anthropic Claude 智能助手，擅长长文本和复杂推理"
        case .cursor:
            return "Cursor 编辑器集成，AI 驱动的代码编辑体验"
        case .custom:
            return "自定义 Bundle，由社区或团队创建"
        }
    }
    
    var defaultCapabilities: [BundleCapability] {
        switch self {
        case .codex, .cursor:
            return [.codeAnalysis, .codeGeneration, .refactoring]
        case .claude:
            return [.reasoning, .longContext, .writing]
        case .custom:
            return []
        }
    }
}

/// Bundle 能力标签
enum BundleCapability: String, CaseIterable, Codable {
    case codeAnalysis = "code_analysis"
    case codeGeneration = "code_generation"
    case refactoring = "refactoring"
    case reasoning = "reasoning"
    case longContext = "long_context"
    case writing = "writing"
    case imageGeneration = "image_generation"
    case webSearch = "web_search"
    case sandbox = "sandbox"
    
    var displayName: String {
        switch self {
        case .codeAnalysis: return "代码分析"
        case .codeGeneration: return "代码生成"
        case .refactoring: return "代码重构"
        case .reasoning: return "推理能力"
        case .longContext: return "长上下文"
        case .writing: return "写作助手"
        case .imageGeneration: return "图片生成"
        case .webSearch: return "网络搜索"
        case .sandbox: return "沙箱执行"
        }
    }
    
    var icon: String {
        switch self {
        case .codeAnalysis: return "doc.text.magnifyingglass"
        case .codeGeneration: return "wand.and.stars"
        case .refactoring: return "arrow.2.circlepath"
        case .reasoning: return "brain"
        case .longContext: return "text.badge.plus"
        case .writing: return "pencil"
        case .imageGeneration: return "photo"
        case .webSearch: return "magnifyingglass"
        case .sandbox: return "lock.shield"
        }
    }
}

/// Bundle 元数据
struct BundleMetadata: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let type: BundleType
    let version: String
    let description: String
    let author: String
    let capabilities: [BundleCapability]
    let dependencies: [BundleDependency]
    let requiredProviders: [ProviderType]
    let sandboxConfig: SandboxConfiguration?
    let skills: [String]
    let isOfficial: Bool
    let installCount: Int
    let rating: Double?
    let lastUpdated: Date
    let iconURL: URL?
    
    struct BundleDependency: Codable, Equatable {
        let name: String
        let versionRange: String
        let optional: Bool
    }
    
    struct SandboxConfiguration: Codable, Equatable {
        let type: SandboxType
        let required: Bool
        let defaultConfig: [String: String]?
        
        enum SandboxType: String, Codable {
            case ssh = "ssh"
            case openShell = "openshell"
            case docker = "docker"
        }
    }
}

/// Bundle 安装状态
enum BundleInstallStatus: Equatable {
    case notInstalled
    case installing(progress: Double)
    case installed(version: String)
    case updating(fromVersion: String, toVersion: String)
    case uninstalling
    case error(String)
    
    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
    
    var isProcessing: Bool {
        switch self {
        case .installing, .updating, .uninstalling:
            return true
        default:
            return false
        }
    }
}

/// Bundle 实例（已安装）
struct BundleInstance: Identifiable, Codable {
    let id: String
    let metadata: BundleMetadata
    let installPath: String
    let installedAt: Date
    let lastUsedAt: Date?
    let config: [String: String]
    let isEnabled: Bool
    
    /// 获取此 Bundle 创建的 Agent 配置
    func agentConfiguration() -> AgentConfigurationSuggestion {
        AgentConfigurationSuggestion(
            name: "\(metadata.name) Agent",
            provider: metadata.requiredProviders.first ?? .openAI,
            model: recommendedModel(),
            capabilities: metadata.capabilities,
            sandboxEnabled: metadata.sandboxConfig?.required ?? false,
            skills: metadata.skills
        )
    }
    
    private func recommendedModel() -> String {
        switch metadata.type {
        case .codex:
            return "codex-latest"
        case .claude:
            return "claude-sonnet-4"
        case .cursor:
            return "cursor-default"
        case .custom:
            return "gpt-5.2"
        }
    }
}

/// Bundle 安装结果
enum BundleInstallResult {
    case success(BundleInstance)
    case failure(BundleInstallError)
    
    enum BundleInstallError: Error {
        case alreadyInstalled
        case dependencyMissing([String])
        case providerNotConfigured([ProviderType])
        case sandboxSetupFailed(String)
        case networkError
        case invalidBundle
        case permissionDenied
        case unknown(String)
        
        var localizedDescription: String {
            switch self {
            case .alreadyInstalled:
                return "Bundle 已安装"
            case .dependencyMissing(let deps):
                return "缺少依赖: \(deps.joined(separator: ", "))"
            case .providerNotConfigured(let providers):
                return "需要配置 Provider: \(providers.map { $0.displayName }.joined(separator: ", "))"
            case .sandboxSetupFailed(let reason):
                return "沙箱配置失败: \(reason)"
            case .networkError:
                return "网络错误，请检查连接"
            case .invalidBundle:
                return "Bundle 格式无效"
            case .permissionDenied:
                return "权限不足"
            case .unknown(let msg):
                return "未知错误: \(msg)"
            }
        }
    }
}

/// Agent 配置建议
struct AgentConfigurationSuggestion {
    let name: String
    let provider: ProviderType
    let model: String
    let capabilities: [BundleCapability]
    let sandboxEnabled: Bool
    let skills: [String]
}

// MARK: - Bundle 市场数据

struct BundleMarketplaceCategory: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let bundles: [BundleMetadata]
}

struct BundleSearchResult {
    let bundles: [BundleMetadata]
    let totalCount: Int
    let hasMore: Bool
    let query: String
}

// MARK: - 扩展

extension BundleMetadata {
    /// 示例 Bundles（用于开发和预览）
    static let samples: [BundleMetadata] = [
        BundleMetadata(
            id: "claude-coding",
            name: "Claude Coding",
            type: .claude,
            version: "1.2.0",
            description: "基于 Claude 的智能编程助手，支持代码生成、重构和代码审查。适合需要处理复杂代码逻辑和大型项目的开发者。",
            author: "Anthropic",
            capabilities: [.codeAnalysis, .codeGeneration, .refactoring, .reasoning, .longContext],
            dependencies: [],
            requiredProviders: [.anthropic],
            sandboxConfig: .init(type: .ssh, required: false, defaultConfig: nil),
            skills: ["/code", "/review", "/explain"],
            isOfficial: true,
            installCount: 15420,
            rating: 4.8,
            lastUpdated: Date(),
            iconURL: nil
        ),
        BundleMetadata(
            id: "codex-pro",
            name: "Codex Pro",
            type: .codex,
            version: "2.0.1",
            description: "OpenAI Codex 专业版，强大的代码理解和生成能力。支持多语言编程和框架特定的最佳实践。",
            author: "OpenAI",
            capabilities: [.codeAnalysis, .codeGeneration, .refactoring],
            dependencies: [],
            requiredProviders: [.openAI],
            sandboxConfig: .init(type: .docker, required: false, defaultConfig: ["image": "python:3.11"]),
            skills: ["/generate", "/test", "/debug"],
            isOfficial: true,
            installCount: 23100,
            rating: 4.7,
            lastUpdated: Date(),
            iconURL: nil
        ),
        BundleMetadata(
            id: "fullstack-dev",
            name: "全栈开发套件",
            type: .custom,
            version: "1.0.0",
            description: "包含前端、后端、数据库的全栈开发工具集。集成 Firecrawl 搜索和代码执行沙箱。",
            author: "社区",
            capabilities: [.codeAnalysis, .codeGeneration, .webSearch, .sandbox],
            dependencies: ["firecrawl"],
            requiredProviders: [.openAI, .deepSeek],
            sandboxConfig: .init(type: .openShell, required: true, defaultConfig: ["mode": "mirror"]),
            skills: ["/web", "/api", "/db", "/search"],
            isOfficial: false,
            installCount: 3420,
            rating: 4.5,
            lastUpdated: Date(),
            iconURL: nil
        )
    ]
}
