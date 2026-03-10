//
//  SkillSystem.swift
//  技能系统 - 可进化的命令技能
//

import Foundation

// MARK: - 技能模型

enum SkillPriority: Int, Codable {
    case low = 0
    case normal = 1
    case high = 2
    case critical = 3
}

struct Skill: Codable {
    let id: String
    var name: String
    var triggers: [String]          // 触发关键词
    var commandTemplate: String     // 命令模板
    var priority: SkillPriority
    var usageCount: Int
    var successCount: Int
    var failCount: Int
    var improvementSuggestions: [String]?
    var createdAt: Date?
    var updatedAt: Date?
    var version: Int
    var lastUsed: Date?
    var lastEvolutionReason: String?
    
    init(id: String = UUID().uuidString,
         name: String,
         triggers: [String],
         commandTemplate: String,
         priority: SkillPriority = .normal,
         usageCount: Int = 0,
         successCount: Int = 0,
         failCount: Int = 0,
         improvementSuggestions: [String]? = nil,
         createdAt: Date? = nil,
         updatedAt: Date? = nil,
         version: Int = 1,
         lastUsed: Date? = nil,
         lastEvolutionReason: String? = nil) {
        self.id = id
        self.name = name
        self.triggers = triggers
        self.commandTemplate = commandTemplate
        self.priority = priority
        self.usageCount = usageCount
        self.successCount = successCount
        self.failCount = failCount
        self.improvementSuggestions = improvementSuggestions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.lastUsed = lastUsed
        self.lastEvolutionReason = lastEvolutionReason
    }
}

// MARK: - 技能系统

class SkillSystem: ObservableObject {
    @Published var skills: [Skill] = []

    static let shared = SkillSystem()
    
    private let storage = StorageManager.shared
    
    init() {
        loadSkills()
        registerDefaultSkills()
    }
    
    // MARK: - 技能管理
    
    func loadSkills() {
        skills = storage.getSkills()
    }
    
    func saveSkill(_ skill: Skill) {
        storage.saveSkill(skill, withEvolution: true)
        loadSkills()
    }
    
    func deleteSkill(id: String) {
        // 从SQLite删除
        // ...
        loadSkills()
    }
    
    // MARK: - 技能匹配
    
    func matchSkill(for input: String) -> Skill? {
        let lowerInput = input.lowercased()
        
        // 按优先级排序匹配
        let sortedSkills = skills.sorted { $0.priority.rawValue > $1.priority.rawValue }
        
        for skill in sortedSkills {
            for trigger in skill.triggers {
                if lowerInput.contains(trigger.lowercased()) {
                    return skill
                }
            }
        }
        
        return nil
    }
    
    func executeSkill(_ skill: Skill, withInput input: String) -> String {
        // 记录使用
        storage.updateSkillUsage(skillId: skill.id, success: true, context: input)
        
        // 解析参数
        let args = extractArguments(from: input, for: skill)
        
        // 填充命令模板
        let command = fillTemplate(skill.commandTemplate, with: args)
        
        // 执行命令
        let result = runCommand(command)
        
        return result
    }
    
    // MARK: - 技能进化
    
    func evolveSkill(_ skillId: String, reason: String, improvements: [String]) {
        guard let skill = skills.first(where: { $0.id == skillId }) else { return }
        
        var evolvedSkill = skill
        evolvedSkill.version += 1
        evolvedSkill.updatedAt = Date()
        evolvedSkill.lastEvolutionReason = reason
        evolvedSkill.improvementSuggestions = improvements
        
        // 根据改进建议更新技能
        for improvement in improvements {
            applyImprovement(&evolvedSkill, improvement: improvement)
        }
        
        saveSkill(evolvedSkill)
    }
    
    func suggestSkillEvolution(basedOn usage: SkillUsageStats) -> [String] {
        var suggestions: [String] = []
        
        // 基于成功率分析
        if usage.successRate < 0.5 {
            suggestions.append("命令模板可能需要简化或添加更多示例")
        }
        
        // 基于使用频率分析
        if usage.totalUses > 50 && usage.successRate > 0.8 {
            suggestions.append("考虑提升技能优先级")
        }
        
        return suggestions
    }
    
    // MARK: - 注册默认技能
    
    private func registerDefaultSkills() {
        let defaultSkills = [
            Skill(
                name: "截图分析",
                triggers: ["截图", "screenshot", "屏幕"],
                commandTemplate: "screencapture -x /tmp/screenshot.png && kimi -f /tmp/screenshot.png -p '分析这张截图'",
                priority: .high
            ),
            Skill(
                name: "剪贴板处理",
                triggers: ["剪贴板", "clipboard", "粘贴"],
                commandTemplate: "pbpaste | kimi -p '处理以下内容:'",
                priority: .high
            ),
            Skill(
                name: "代码解释",
                triggers: ["解释代码", "代码解释", "explain code"],
                commandTemplate: "kimi -p '请详细解释这段代码:\n{{input}}'",
                priority: .normal
            ),
            Skill(
                name: "错误排查",
                triggers: ["错误", "报错", "error", "bug"],
                commandTemplate: "kimi -p '请帮我分析这个错误:\n{{input}}'",
                priority: .high
            ),
            Skill(
                name: "文件搜索",
                triggers: ["搜索文件", "查找文件", "find file"],
                commandTemplate: "find . -name '{{input}}' 2>/dev/null | head -20",
                priority: .normal
            ),
            Skill(
                name: "Git操作",
                triggers: ["git", "提交", "commit", "分支", "branch"],
                commandTemplate: "git {{input}}",
                priority: .normal
            ),
            Skill(
                name: "端口检查",
                triggers: ["端口", "port", "检查端口"],
                commandTemplate: "lsof -i :{{input}}",
                priority: .low
            ),
            Skill(
                name: "进程管理",
                triggers: ["进程", "杀死", "kill", "ps"],
                commandTemplate: "ps aux | grep {{input}} | grep -v grep",
                priority: .low
            )
        ]
        
        // 只注册不存在的技能
        for skill in defaultSkills {
            if !skills.contains(where: { $0.name == skill.name }) {
                saveSkill(skill)
            }
        }
    }
    
    // MARK: - 辅助方法
    
    private func extractArguments(from input: String, for skill: Skill) -> [String: String] {
        var args: [String: String] = [:]
        
        // 提取引号中的内容
        let quotePattern = "\"([^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: quotePattern) {
            let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
            for (index, match) in matches.enumerated() {
                if let range = Range(match.range(at: 1), in: input) {
                    args["arg\(index)"] = String(input[range])
                }
            }
        }
        
        // 提取命令后的剩余部分
        for trigger in skill.triggers {
            if let range = input.lowercased().range(of: trigger) {
                let afterTrigger = String(input[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !afterTrigger.isEmpty {
                    args["input"] = afterTrigger
                }
                break
            }
        }
        
        return args
    }
    
    private func fillTemplate(_ template: String, with args: [String: String]) -> String {
        var result = template
        
        for (key, value) in args {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        
        return result
    }
    
    private func runCommand(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return "执行失败: \(error.localizedDescription)"
        }
    }
    
    private func applyImprovement(_ skill: inout Skill, improvement: String) {
        // 根据改进建议更新技能
        if improvement.contains("触发词") {
            // 扩展触发词
            skill.triggers.append(contentsOf: ["新的触发词1", "新的触发词2"])
        }
        
        if improvement.contains("模板") {
            // 优化命令模板
            // ...
        }
        
        if improvement.contains("优先级") {
            // 提升优先级
            if skill.priority.rawValue < SkillPriority.critical.rawValue {
                skill.priority = SkillPriority(rawValue: skill.priority.rawValue + 1) ?? skill.priority
            }
        }
    }
}

// MARK: - 技能学习（从对话中学习新技能）

extension SkillSystem {
    /// 从成功的对话中学习新技能
    func learnSkill(from conversation: [MacAssistant.ChatMessage]) {
        // 分析对话模式
        guard conversation.count >= 2 else { return }
        
        let userMessages = conversation.filter { $0.role == MessageRole.user }
        let assistantMessages = conversation.filter { $0.role == MessageRole.assistant }
        
        guard let lastUserMessage = userMessages.last,
              let lastAssistantMessage = assistantMessages.last else { return }
        
        // 检查是否是命令模式
        if lastUserMessage.content.hasPrefix("/") {
            // 可能已经存在技能，不需要学习
            return
        }
        
        // 检查是否有重复模式
        let similarPatterns = findSimilarPatterns(in: userMessages)
        
        if similarPatterns.count >= 3 {
            // 发现重复模式，可以创建新技能
            suggestNewSkill(basedOn: similarPatterns, response: lastAssistantMessage.content)
        }
    }
    
    private func findSimilarPatterns(in messages: [ChatMessage]) -> [String] {
        // 简单的相似度检测
        var patterns: [String] = []
        
        for message in messages {
            let content = message.content.lowercased()
            
            // 提取开头几个词作为模式
            let words = content.split(separator: " ").prefix(3)
            let pattern = words.joined(separator: " ")
            
            patterns.append(String(pattern))
        }
        
        // 统计频率
        var frequency: [String: Int] = [:]
        for pattern in patterns {
            frequency[pattern, default: 0] += 1
        }
        
        // 返回高频模式
        return frequency.filter { $0.value >= 2 }.map { $0.key }
    }
    
    private func suggestNewSkill(basedOn patterns: [String], response: String) {
        // 生成技能建议
        let suggestedName = patterns.first ?? "新技能"
        let suggestedTriggers = patterns
        
        // 这里可以通知用户或自动创建
        print("建议创建新技能: \(suggestedName)")
        print("触发词: \(suggestedTriggers)")
    }
}
