//
//  ConversationIntelligence.swift
//  MacAssistant
//
//  对话智能 - 让 Agents 和 Skills 自然融入会话
//

import Foundation
import Combine

/// 对话智能引擎 - 解析用户输入中的 Agent 和 Skill 意图
class ConversationIntelligence: ObservableObject {
    static let shared = ConversationIntelligence()
    
    @Published var suggestions: [ConversationSuggestion] = []
    @Published var isAnalyzing = false
    
    private let agentStore = AgentStore.shared
    private let orchestrator = AgentOrchestrator.shared
    private let skillRegistry = AISkillRegistry.shared
    
    // MARK: - 输入解析
    
    /// 解析用户输入，检测 Agent 和 Skill 引用
    func analyzeInput(_ input: String) -> ParsedInput {
        var parsed = ParsedInput(original: input)
        parsed.cleanText = input
        
        // 1. 检测 @Agent 提及
        if let agentMention = detectAgentMention(in: input) {
            parsed.agentMention = agentMention
            parsed.cleanText = removeMention(input, mention: agentMention.original)
        }
        
        // 2. 检测 /Skill 命令
        if let skillCommand = detectSkillCommand(in: parsed.cleanText) {
            parsed.skillCommand = skillCommand
            parsed.cleanText = removeCommand(parsed.cleanText, command: skillCommand.original)
        }
        
        // 3. 自然语言检测 Skill 意图
        if parsed.skillCommand == nil {
            parsed.detectedSkill = detectNaturalSkillIntent(in: parsed.cleanText)
        }
        
        // 4. 自然语言检测 Agent 需求
        if parsed.agentMention == nil {
            parsed.suggestedAgent = detectAgentNeed(in: parsed.cleanText)
        }
        
        // 5. 清理后的文本就是实际要发送的内容
        parsed.cleanText = parsed.cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return parsed
    }
    
    /// 获取实时建议（用于输入框下拉提示）
    func getSuggestions(for input: String) -> [ConversationSuggestion] {
        var suggestions: [ConversationSuggestion] = []
        
        // @ 触发 - Agent 建议
        if input.hasSuffix("@") || input.contains("@") && !input.hasSuffix(" ") {
            let query = extractQueryAfter(input, prefix: "@")
            suggestions += agentSuggestions(query: query)
        }
        
        // / 触发 - Skill 建议
        if input.hasSuffix("/") || input.contains("/") && !input.hasSuffix(" ") {
            let query = extractQueryAfter(input, prefix: "/")
            suggestions += skillSuggestions(query: query)
        }
        
        return suggestions
    }
    
    // MARK: - 私有检测方法
    
    /// 检测 @Agent 提及
    private func detectAgentMention(in input: String) -> AgentMention? {
        let pattern = #"@([\w\s]+?)(?:\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: input, options: [], range: NSRange(input.startIndex..., in: input)),
              let range = Range(match.range(at: 1), in: input) else {
            return nil
        }
        
        let name = String(input[range]).trimmingCharacters(in: .whitespaces)
        
        // 查找匹配的 Agent
        if let agent = findAgent(byName: name) {
            return AgentMention(
                original: String(input[Range(match.range(at: 0), in: input)!]),
                agentName: name,
                agent: agent
            )
        }
        
        return nil
    }
    
    /// 检测 /Skill 命令
    private func detectSkillCommand(in input: String) -> SkillCommand? {
        let pattern = #"/([\w]+)(?:\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: input, options: [], range: NSRange(input.startIndex..., in: input)),
              let range = Range(match.range(at: 1), in: input) else {
            return nil
        }
        
        let command = String(input[range]).lowercased()
        
        // 查找匹配的 Skill
        if let skill = skillRegistry.skills.first(where: { 
            $0.rawValue.lowercased() == command ||
            $0.name.lowercased().replacingOccurrences(of: " ", with: "_") == command
        }) {
            return SkillCommand(
                original: String(input[Range(match.range(at: 0), in: input)!]),
                command: command,
                skill: skill
            )
        }
        
        return nil
    }
    
    /// 自然语言检测 Skill 意图（仅检测明确的命令）
    private func detectNaturalSkillIntent(in input: String) -> AISkill? {
        let lowercased = input.lowercased()
        
        // 截图相关 - 需要明确的截图指令
        if containsAny(lowercased, ["截图", "截屏", "screenshot", "screen shot"]) &&
           !lowercased.contains("不用") &&
           !lowercased.contains("不要") &&
           !lowercased.contains("算了") {
            return .screenshot
        }
        
        // 代码审查 - 明确的代码审查指令
        if containsAny(lowercased, ["review 代码", "代码 review", "审查代码", "检查代码", "code review"]) {
            return .codeReview
        }
        
        // 解释代码 - 明确的解释指令
        if lowercased.contains("解释代码") || lowercased.contains("explain code") ||
           (lowercased.contains("解释") && lowercased.contains("这段")) {
            return .explainSelection
        }
        
        // 翻译 - 明确的翻译指令
        if (lowercased.contains("翻译") || lowercased.contains("translate")) &&
           (lowercased.contains("成") || lowercased.contains("to")) {
            return .translateText
        }
        
        // 总结 - 明确的总结指令
        if containsAny(lowercased, ["总结", "概括", "summarize", "summary"]) &&
           input.count > 50 {  // 只有文本较长时才建议总结
            return .summarizeText
        }
        
        return nil
    }
    
    /// 检测是否需要特定 Agent
    private func detectAgentNeed(in input: String) -> AgentSuggestion? {
        let lowercased = input.lowercased()
        
        // 需要视觉能力
        if containsAny(lowercased, ["图片", "图像", "截图", "这张图", "分析一下", "看图"]) {
            let visionAgents = agentStore.visionAgents
            if visionAgents.isEmpty {
                return AgentSuggestion(
                    reason: "需要图片分析能力",
                    suggestedAgent: nil,
                    action: .createVisionAgent
                )
            } else if let current = orchestrator.currentAgent, !current.supportsImageAnalysis {
                return AgentSuggestion(
                    reason: "当前 Agent 不支持图片分析",
                    suggestedAgent: visionAgents.first,
                    action: .switchAgent
                )
            }
        }
        
        // 需要代码分析能力
        if containsAny(lowercased, ["代码", "编程", "bug", "报错", "函数", "类", "debug"]) {
            // 检查当前 Agent 是否支持代码分析
            if let current = orchestrator.currentAgent, !current.supports(.codeAnalysis) {
                let codeAgents = agentStore.agents.filter { $0.supports(.codeAnalysis) }
                if let agent = codeAgents.first {
                    return AgentSuggestion(
                        reason: "建议切换到代码分析 Agent",
                        suggestedAgent: agent,
                        action: .switchAgent
                    )
                }
            }
        }
        
        return nil
    }
    
    // MARK: - 建议生成
    
    private func agentSuggestions(query: String) -> [ConversationSuggestion] {
        let agents = agentStore.agents.filter { agent in
            query.isEmpty || 
            agent.name.lowercased().contains(query.lowercased()) ||
            agent.provider.rawValue.contains(query.lowercased())
        }
        
        return agents.map { agent in
            ConversationSuggestion(
                type: .agent,
                icon: agent.emoji,
                title: agent.name,
                subtitle: "\(agent.provider.displayName) · \(agent.model)",
                action: .useAgent(agent)
            )
        }
    }
    
    private func skillSuggestions(query: String) -> [ConversationSuggestion] {
        let skills = skillRegistry.skills.filter { skill in
            query.isEmpty ||
            skill.name.lowercased().contains(query.lowercased()) ||
            skill.rawValue.contains(query.lowercased())
        }
        
        return skills.map { skill in
            ConversationSuggestion(
                type: .skill,
                icon: skill.emoji,
                title: skill.name,
                subtitle: skill.description,
                action: .useSkill(skill),
                isAvailable: skillRegistry.isAvailable(skill)
            )
        }
    }
    
    // MARK: - 辅助方法
    
    private func findAgent(byName name: String) -> Agent? {
        // 精确匹配
        if let agent = agentStore.agents.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return agent
        }
        
        // 模糊匹配
        return agentStore.agents.first { agent in
            agent.name.lowercased().contains(name.lowercased()) ||
            name.lowercased().contains(agent.name.lowercased())
        }
    }
    
    private func removeMention(_ text: String, mention: String) -> String {
        return text.replacingOccurrences(of: mention, with: "")
    }
    
    private func removeCommand(_ text: String, command: String) -> String {
        return text.replacingOccurrences(of: command, with: "")
    }
    
    private func extractQueryAfter(_ input: String, prefix: String) -> String {
        guard let range = input.range(of: prefix) else { return "" }
        return String(input[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
    
    private func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}

// MARK: - 数据模型

/// 解析后的输入
struct ParsedInput {
    let original: String
    var cleanText: String = ""
    var agentMention: AgentMention?
    var skillCommand: SkillCommand?
    var detectedSkill: AISkill?
    var suggestedAgent: AgentSuggestion?
    
    var hasMentions: Bool {
        agentMention != nil || skillCommand != nil
    }
    
    var needsConfirmation: Bool {
        detectedSkill != nil || suggestedAgent != nil
    }
}

struct AgentMention {
    let original: String
    let agentName: String
    let agent: Agent
}

struct SkillCommand {
    let original: String
    let command: String
    let skill: AISkill
}

struct AgentSuggestion {
    let reason: String
    let suggestedAgent: Agent?
    let action: AgentSuggestionAction
    
    enum AgentSuggestionAction {
        case switchAgent
        case createVisionAgent
    }
}

/// 对话建议
struct ConversationSuggestion: Identifiable {
    let id = UUID()
    let type: SuggestionType
    let icon: String
    let title: String
    let subtitle: String
    let action: SuggestionAction
    var isAvailable: Bool = true
    
    enum SuggestionType {
        case agent
        case skill
    }
    
    enum SuggestionAction {
        case useAgent(Agent)
        case useSkill(AISkill)
    }
}
