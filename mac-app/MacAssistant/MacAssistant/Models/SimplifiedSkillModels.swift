//
//  SimplifiedSkillModels.swift
//  MacAssistant
//
//  精简后的 Skill 模型 - 基于现有 8 个 Skill 合理重构
//

import Foundation

// MARK: - 核心 Skill 枚举（精简为 4 个）

/// 内置 Skill - 精简为真正独立的能力
enum CoreSkill: String, CaseIterable, Identifiable {
    // === 系统工具类（独立执行）===
    case diskManager = "disk_manager"
    case screenshot = "screenshot"
    
    // === 基础能力类（委托给当前 Agent）===
    case textProcessing = "text_processing"
    case codeReview = "code_review"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .diskManager: return "磁盘管理"
        case .screenshot: return "截图分析"
        case .textProcessing: return "文本处理"
        case .codeReview: return "代码审查"
        }
    }
    
    var emoji: String {
        switch self {
        case .diskManager: return "💾"
        case .screenshot: return "📸"
        case .textProcessing: return "📝"
        case .codeReview: return "🔍"
        }
    }
    
    var description: String {
        switch self {
        case .diskManager:
            return "分析磁盘空间、清理缓存、发现大文件"
        case .screenshot:
            return "截取屏幕并分析内容（需要配置 Vision Agent）"
        case .textProcessing:
            return "翻译、总结、解释文本内容"
        case .codeReview:
            return "审查代码质量、发现潜在问题"
        }
    }
    
    /// Skill 分类
    var category: SkillCategory {
        switch self {
        case .diskManager, .screenshot:
            return .system
        case .textProcessing, .codeReview:
            return .analysis
        }
    }
    
    /// 是否需要特定 Agent 能力
    var requiredCapability: Capability? {
        switch self {
        case .diskManager:
            return nil  // 完全独立，不依赖 Agent
        case .screenshot:
            return .vision  // 需要 Vision Agent 分析
        case .textProcessing:
            return .textChat  // 任何支持文本的 Agent 都可以
        case .codeReview:
            return .codeAnalysis  // 需要代码分析能力
        }
    }
    
    /// 执行方式
    var executionMode: SkillExecutionMode {
        switch self {
        case .diskManager:
            return .localTool  // 本地系统工具
        case .screenshot:
            return .hybrid  // 本地截图 + Agent 分析
        case .textProcessing, .codeReview:
            return .agentDelegation  // 委托给当前 Agent
        }
    }
    
    /// 是否需要用户确认
    var requiresConfirmation: Bool {
        switch self {
        case .diskManager: return true  // 清理操作需要确认
        default: return false
        }
    }
    
    /// 支持的触发意图
    var intentKeywords: [String] {
        switch self {
        case .diskManager:
            return ["磁盘", "空间", "清理", "缓存", "大文件", "存储"]
        case .screenshot:
            return ["截图", "截屏", "屏幕", "拍照"]
        case .textProcessing:
            return ["翻译", "总结", "解释", "概括", "简述"]
        case .codeReview:
            return ["代码审查", "review", "代码检查", "优化建议"]
        }
    }
}

// MARK: - Skill 执行模式

enum SkillExecutionMode {
    case localTool      // 本地工具执行（如磁盘分析）
    case hybrid         // 混合：本地操作 + Agent 分析
    case agentDelegation // 完全委托给 Agent
}

// MARK: - Skill 注册表（简化版）

@MainActor
final class CoreSkillRegistry: ObservableObject {
    static let shared = CoreSkillRegistry()
    
    /// 所有核心 Skills
    var allSkills: [CoreSkill] { CoreSkill.allCases }
    
    /// 系统工具类（独立执行）
    var systemTools: [CoreSkill] {
        allSkills.filter { $0.executionMode == .localTool }
    }
    
    /// 委托类（需要 Agent）
    var delegationSkills: [CoreSkill] {
        allSkills.filter { $0.executionMode == .agentDelegation }
    }
    
    /// 检查 Skill 是否可用
    func isAvailable(_ skill: CoreSkill) -> Bool {
        guard let required = skill.requiredCapability else {
            return true  // 无要求，总是可用
        }
        
        // 检查当前 Agent 是否支持该能力
        if let currentAgent = AgentOrchestrator.shared.currentAgent {
            return currentAgent.supports(required)
        }
        
        return false
    }
    
    /// 获取不可用时显示的提示
    func unavailableReason(for skill: CoreSkill) -> String? {
        guard !isAvailable(skill) else { return nil }
        
        switch skill {
        case .screenshot:
            return "需要配置支持视觉分析的 Agent"
        case .codeReview:
            return "当前 Agent 不支持代码分析能力"
        default:
            return "当前 Agent 不支持此功能"
        }
    }
    
    /// 根据意图匹配 Skill
    func matchSkill(for input: String) -> CoreSkill? {
        let lowercased = input.lowercased()
        
        for skill in allSkills {
            if skill.intentKeywords.contains(where: { lowercased.contains($0) }) {
                return skill
            }
        }
        return nil
    }
}

// MARK: - Skill 执行器（简化版）

@MainActor
final class CoreSkillExecutor {
    static let shared = CoreSkillExecutor()
    
    private init() {}
    
    /// 执行 Skill
    func execute(
        _ skill: CoreSkill,
        input: String,
        context: CoreSkillContext
    ) async -> CoreSkillExecutionResult {
        
        switch skill {
        case .diskManager:
            return await executeDiskManager(input: input)
            
        case .screenshot:
            return await executeScreenshot(input: input, context: context)
            
        case .textProcessing:
            return await executeTextProcessing(input: input, context: context)
            
        case .codeReview:
            return await executeCodeReview(input: input, context: context)
        }
    }
    
    // MARK: - 具体执行实现
    
    /// 磁盘管理 - 完全本地执行
    private func executeDiskManager(input: String) async -> CoreSkillExecutionResult {
        let analyzer = ResourceAnalyzer.shared
        analyzer.startAnalysis()
        
        // 等待分析完成（简化实现）
        try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
        
        guard let result = analyzer.analysisResult else {
            return CoreSkillExecutionResult(
                success: false,
                output: "分析尚未完成",
                shouldDelegateToAgent: false
            )
        }
        
        let output = formatDiskAnalysis(result)
        return CoreSkillExecutionResult(
            success: true,
            output: output,
            shouldDelegateToAgent: false
        )
    }
    
    /// 截图分析 - 本地截图 + Agent 分析
    private func executeScreenshot(input: String, context: CoreSkillContext) async -> CoreSkillExecutionResult {
        // 1. 本地执行截图
        let screenshotPath = await takeScreenshot()
        
        guard !screenshotPath.isEmpty else {
            return CoreSkillExecutionResult(
                success: false,
                output: "截图失败",
                shouldDelegateToAgent: false
            )
        }
        
        // 2. 需要 Agent 继续分析
        return CoreSkillExecutionResult(
            success: true,
            output: "已截取屏幕，需要 Agent 分析内容",
            shouldDelegateToAgent: true,
            attachments: [screenshotPath]
        )
    }
    
    /// 文本处理 - 委托给 Agent
    private func executeTextProcessing(input: String, context: CoreSkillContext) async -> CoreSkillExecutionResult {
        // 判断具体意图
        let intent = detectTextIntent(input)
        
        let prompt = generateTextPrompt(intent: intent, input: input)
        
        return CoreSkillExecutionResult(
            success: true,
            output: prompt,
            shouldDelegateToAgent: true
        )
    }
    
    /// 代码审查 - 委托给 Agent
    private func executeCodeReview(input: String, context: CoreSkillContext) async -> CoreSkillExecutionResult {
        let prompt = """
        请对以下代码进行审查：
        
        1. 检查潜在的 bugs 和逻辑错误
        2. 评估代码可读性和可维护性
        3. 检查安全漏洞
        4. 识别性能瓶颈
        5. 提供改进建议
        
        代码：
        \(input)
        """
        
        return CoreSkillExecutionResult(
            success: true,
            output: prompt,
            shouldDelegateToAgent: true
        )
    }
    
    // MARK: - 辅助方法
    
    private func formatDiskAnalysis(_ result: ResourceAnalysisResult) -> String {
        return """
        📊 磁盘分析结果
        
        总大小: \(String(format: "%.2f", result.totalScannedGB)) GB
        
        分类分布:
        \(result.categories.map { "  \($0.category.rawValue): \(String(format: "%.2f", $0.sizeGB)) GB" }.joined(separator: "\n"))
        
        建议：可以在磁盘管理面板中查看详情和清理选项。
        """
    }
    
    private func takeScreenshot() async -> String {
        // 简化实现
        return ""
    }
    
    private func detectTextIntent(_ input: String) -> TextIntent {
        let lowercased = input.lowercased()
        if lowercased.contains("翻译") { return .translate }
        if lowercased.contains("总结") || lowercased.contains("概括") { return .summarize }
        if lowercased.contains("解释") { return .explain }
        return .general
    }
    
    private func generateTextPrompt(intent: TextIntent, input: String) -> String {
        switch intent {
        case .translate:
            return "请将以下内容翻译成中文/英文：\n\(input)"
        case .summarize:
            return "请总结以下内容的要点：\n\(input)"
        case .explain:
            return "请解释以下内容：\n\(input)"
        case .general:
            return input
        }
    }
}

// MARK: - 辅助类型

struct CoreSkillExecutionResult {
    let success: Bool
    let output: String
    let shouldDelegateToAgent: Bool
    var attachments: [String]?
}

struct CoreSkillContext {
    let currentAgent: Agent?
    let conversationHistory: [ChatMessage]?
}

enum TextIntent {
    case translate
    case summarize
    case explain
    case general
}

// MARK: - 废弃说明

// 注意：原 "创建 Vision Agent" Skill 已转为 Agent 模板 "vision-analyst"
// 请在 AgentTemplateSystem.swift 中查看

// MARK: - 移除的 Skill 说明

/*
 移除/合并的 Skill：
 
 1. create_vision_agent (创建 Vision Agent)
    → 改为 Agent 模板 "vision-analyst"
    → 理由：不是独立功能，是创建工具
 
 2. analyze_image (图片分析)
    → 合并到 screenshot (截图分析)
    → 理由：本质是同一个能力（视觉分析）
    → 上传图片和截图分析应该统一处理
 
 3. explain_selection (解释选中内容)
    → 合并到 textProcessing (文本处理)
    → 理由：解释/翻译/总结都是文本处理的不同形式
 
 4. translate_text (翻译文本)
    → 合并到 textProcessing (文本处理)
    → 理由：同上
 
 5. summarize_text (总结文本)
    → 合并到 textProcessing (文本处理)
    → 理由：同上
 
 保留下来的 4 个核心 Skill：
 - diskManager: 独立系统工具（最有价值）
 - screenshot: 本地+Agent 混合（视觉分析入口）
 - textProcessing: 文本处理三合一（解释/翻译/总结）
 - codeReview: 专业代码审查（独立价值）
*/
