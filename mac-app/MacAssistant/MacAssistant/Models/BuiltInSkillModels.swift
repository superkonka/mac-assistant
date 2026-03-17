//
//  SkillModels.swift
//  MacAssistant
//
//  Skill 系统的数据模型
//

import Foundation

// MARK: - Skill Protocol

/// 内置 Skill 协议 - 定义可执行的技能
protocol BuiltinSkill: Identifiable {
    var id: String { get }
    var name: String { get }
    var emoji: String { get }
    var description: String { get }
    var category: SkillCategory { get }
    var isAvailable: Bool { get }
    
    /// 执行技能
    func execute(context: MacAssistant.SkillContext) async throws -> SkillResult
}

// MARK: - Skill Category

enum SkillCategory: String, CaseIterable {
    case productivity = "生产力"
    case analysis = "分析"
    case creation = "创建"
    case system = "系统"
    case agent = "Agent"
    
    var icon: String {
        switch self {
        case .productivity: return "bolt.fill"
        case .analysis: return "magnifyingglass"
        case .creation: return "wand.and.stars"
        case .system: return "gearshape.fill"
        case .agent: return "person.fill.badge.plus"
        }
    }
    
    var color: String {
        switch self {
        case .productivity: return "yellow"
        case .analysis: return "blue"
        case .creation: return "purple"
        case .system: return "gray"
        case .agent: return "green"
        }
    }
}

// SkillContext 定义在 ChatModels.swift 中

// MARK: - Skill Result

enum SkillResult {
    case success(message: String)
    case requiresInput(prompt: String)
    case requiresAgentCreation(gap: CapabilityGap)
    case error(message: String)
}

// MARK: - Built-in Skills

/// 系统内置 AI 技能
/// 
/// 注意：新代码请使用 CoreSkill（在 SimplifiedSkillModels.swift 中定义）
/// 保留此类型用于向后兼容，建议迁移到 CoreSkill
enum AISkill: String, CaseIterable, Identifiable {
    // 系统工具
    case screenshot = "screenshot"
    case analyzeDisk = "analyze_disk"
    
    // 文本处理（建议迁移到 CoreSkill.textProcessing）
    case explainSelection = "explain_selection"
    case translateText = "translate_text"
    case summarizeText = "summarize_text"
    
    // 代码相关
    case codeReview = "code_review"
    
    // 以下 case 已废弃，将在未来版本移除：
    // - createVisionAgent → 使用 Agent 模板
    // - analyzeImage → 合并到 screenshot
    
    var id: String { rawValue }
    
    var name: String {
        switch self {
        case .screenshot: return "截图分析"
        case .codeReview: return "代码审查"
        case .explainSelection: return "解释选中内容"
        case .translateText: return "翻译文本"
        case .summarizeText: return "总结文本"
        case .analyzeDisk: return "磁盘分析"
        }
    }
    
    var emoji: String {
        switch self {
        case .screenshot: return "📸"
        case .codeReview: return "📝"
        case .explainSelection: return "💡"
        case .translateText: return "🌐"
        case .summarizeText: return "📋"
        case .analyzeDisk: return "💾"
        }
    }
    
    var description: String {
        switch self {
        case .screenshot: return "截取屏幕并分析内容"
        case .codeReview: return "审查代码质量并提供建议"
        case .explainSelection: return "解释当前选中的文本或代码"
        case .translateText: return "将文本翻译成其他语言"
        case .summarizeText: return "总结长文本的核心内容"
        case .analyzeDisk: return "分析磁盘使用情况，发现大文件和优化建议"
        }
    }
    
    var category: SkillCategory {
        switch self {
        case .screenshot:
            return .analysis
        case .codeReview, .explainSelection:
            return .analysis
        case .translateText, .summarizeText:
            return .productivity
        case .analyzeDisk:
            return .system
        }
    }
    
    var requiredCapability: Capability? {
        switch self {
        case .screenshot:
            return .vision
        case .codeReview:
            return .codeAnalysis
        case .explainSelection, .summarizeText:
            return .textChat
        case .translateText:
            return .textChat
        case .analyzeDisk:
            return nil // 不需要特定能力，本地执行
        }
    }
    
    var shortcut: String? {
        switch self {
        case .screenshot: return "⌘⇧5"
        case .codeReview: return nil
        case .explainSelection: return "⌘⇧E"
        case .translateText: return nil
        case .summarizeText: return nil
        case .analyzeDisk: return nil
        }
    }

    var supportsIntentDetection: Bool {
        switch self {
        case .screenshot,
             .codeReview,
             .explainSelection,
             .translateText,
             .summarizeText,
             .analyzeDisk:
            return true
        }
    }
}

// MARK: - Skill Registry

/// 技能注册表 - 管理所有可用技能
class AISkillRegistry: ObservableObject {
    @Published var skills: [AISkill] = AISkill.allCases
    
    static let shared = AISkillRegistry()
    
    /// 按分类获取技能
    func skills(in category: SkillCategory) -> [AISkill] {
        skills.filter { $0.category == category }
    }
    
    /// 检查技能是否可用
    func isAvailable(_ skill: AISkill) -> Bool {
        guard let requiredCapability = skill.requiredCapability else {
            return true
        }
        
        // 检查当前 Agent 是否支持该能力
        if let currentAgent = AgentOrchestrator.shared.currentAgent {
            return currentAgent.supports(requiredCapability)
        }
        
        return false
    }
    
    /// 获取需要创建 Agent 的技能
    var skillsRequiringAgentCreation: [AISkill] {
        skills.filter { skill in
            guard let required = skill.requiredCapability else { return false }
            return !AgentStore.shared.agentsSupporting(required).isEmpty
        }
    }
    
    /// 执行技能
    func execute(_ skill: AISkill, context: MacAssistant.SkillContext) async -> SkillResult {
        switch skill {
        case .screenshot:
            return await executeScreenshot(context: context)
            
        case .codeReview:
            return await executeCodeReview(context: context)
            
        case .explainSelection:
            return await executeExplainSelection(context: context)
            
        case .translateText:
            return await executeTranslateText(context: context)
            
        case .summarizeText:
            return await executeSummarizeText(context: context)
            
        case .analyzeDisk:
            return await executeAnalyzeDisk(context: context)
        }
    }
    
    // MARK: - 技能执行实现
    
    private func executeScreenshot(context: MacAssistant.SkillContext) async -> SkillResult {
        // 触发截图
        context.runner.handleScreenshot()
        return .success(message: "已触发截图")
    }
    
    private func executeCodeReview(context: MacAssistant.SkillContext) async -> SkillResult {
        guard let code = context.input else {
            return .requiresInput(prompt: "请输入要审查的代码")
        }
        
        return .success(message: "正在审查代码...")
    }
    
    private func executeExplainSelection(context: MacAssistant.SkillContext) async -> SkillResult {
        // 获取当前选中的文本（需要 Accessibility 权限）
        return .success(message: "正在解释选中的内容...")
    }
    
    private func executeTranslateText(context: MacAssistant.SkillContext) async -> SkillResult {
        return .requiresInput(prompt: "请输入要翻译的文本和目标语言")
    }
    
    private func executeSummarizeText(context: MacAssistant.SkillContext) async -> SkillResult {
        guard let text = context.input, text.count > 100 else {
            return .requiresInput(prompt: "请输入要总结的文本（至少100字）")
        }
        
        return .success(message: "正在总结文本...")
    }
    
    private func executeAnalyzeDisk(context: MacAssistant.SkillContext) async -> SkillResult {
        // 触发磁盘分析
        await MainActor.run {
            // 通知显示磁盘管理界面
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowDiskMonitor"),
                object: nil
            )
            // 开始资源分析
            ResourceAnalyzer.shared.startAnalysis()
        }
        
        return .success(message: "已打开磁盘管理器并开始智能资源分析")
    }
}

// MARK: - Skill Item View Model

struct AISkillItem: Identifiable {
    let id = UUID()
    let skill: AISkill
    let isAvailable: Bool
    let requiresUpgrade: Bool
}
