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
enum AISkill: String, CaseIterable, Identifiable {
    case screenshot = "screenshot"
    case createVisionAgent = "create_vision_agent"
    case analyzeImage = "analyze_image"
    case codeReview = "code_review"
    case explainSelection = "explain_selection"
    case translateText = "translate_text"
    case summarizeText = "summarize_text"
    
    var id: String { rawValue }
    
    var name: String {
        switch self {
        case .screenshot: return "截图分析"
        case .createVisionAgent: return "创建 Vision Agent"
        case .analyzeImage: return "图片分析"
        case .codeReview: return "代码审查"
        case .explainSelection: return "解释选中内容"
        case .translateText: return "翻译文本"
        case .summarizeText: return "总结文本"
        }
    }
    
    var emoji: String {
        switch self {
        case .screenshot: return "📸"
        case .createVisionAgent: return "👁️"
        case .analyzeImage: return "🖼️"
        case .codeReview: return "📝"
        case .explainSelection: return "💡"
        case .translateText: return "🌐"
        case .summarizeText: return "📋"
        }
    }
    
    var description: String {
        switch self {
        case .screenshot: return "截取屏幕并分析内容"
        case .createVisionAgent: return "创建支持图片分析的 AI Agent"
        case .analyzeImage: return "分析图片中的内容和细节"
        case .codeReview: return "审查代码质量并提供建议"
        case .explainSelection: return "解释当前选中的文本或代码"
        case .translateText: return "将文本翻译成其他语言"
        case .summarizeText: return "总结长文本的核心内容"
        }
    }
    
    var category: SkillCategory {
        switch self {
        case .screenshot, .analyzeImage:
            return .analysis
        case .createVisionAgent:
            return .agent
        case .codeReview, .explainSelection:
            return .analysis
        case .translateText, .summarizeText:
            return .productivity
        }
    }
    
    var requiredCapability: Capability? {
        switch self {
        case .screenshot, .analyzeImage, .createVisionAgent:
            return .vision
        case .codeReview:
            return .codeAnalysis
        case .explainSelection, .summarizeText:
            return .textChat
        case .translateText:
            return .textChat
        }
    }
    
    var shortcut: String? {
        switch self {
        case .screenshot: return "⌘⇧5"
        case .createVisionAgent: return nil
        case .analyzeImage: return nil
        case .codeReview: return nil
        case .explainSelection: return "⌘⇧E"
        case .translateText: return nil
        case .summarizeText: return nil
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
            
        case .createVisionAgent:
            return await executeCreateVisionAgent(context: context)
            
        case .analyzeImage:
            return await executeAnalyzeImage(context: context)
            
        case .codeReview:
            return await executeCodeReview(context: context)
            
        case .explainSelection:
            return await executeExplainSelection(context: context)
            
        case .translateText:
            return await executeTranslateText(context: context)
            
        case .summarizeText:
            return await executeSummarizeText(context: context)
        }
    }
    
    // MARK: - 技能执行实现
    
    private func executeScreenshot(context: MacAssistant.SkillContext) async -> SkillResult {
        // 触发截图
        context.runner.handleScreenshot()
        return .success(message: "已触发截图")
    }
    
    private func executeCreateVisionAgent(context: MacAssistant.SkillContext) async -> SkillResult {
        // 检查是否已有 Vision Agent
        if AgentStore.shared.visionAgents.isEmpty {
            let gap = CapabilityGap(
                missingCapability: .vision,
                suggestedProviders: [.openai, .anthropic, .moonshot],
                description: "需要创建支持视觉理解的 Agent"
            )
            return .requiresAgentCreation(gap: gap)
        }
        
        return .success(message: "已有 Vision Agent 可用")
    }
    
    private func executeAnalyzeImage(context: MacAssistant.SkillContext) async -> SkillResult {
        guard let imagePath = context.images?.first else {
            return .requiresInput(prompt: "请选择要分析的图片")
        }
        
        // 检查能力
        if let gap = AgentOrchestrator.shared.discoverGap(for: "分析图片") {
            return .requiresAgentCreation(gap: gap)
        }
        
        return .success(message: "正在分析图片...")
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
}

// MARK: - Skill Item View Model

struct AISkillItem: Identifiable {
    let id = UUID()
    let skill: AISkill
    let isAvailable: Bool
    let requiresUpgrade: Bool
}
