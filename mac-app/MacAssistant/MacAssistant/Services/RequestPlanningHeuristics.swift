//
//  RequestPlanningHeuristics.swift
//  MacAssistant
//

import Foundation

enum RequestPlanningHeuristics {
    static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shouldTreatAsResumeCommand(_ normalized: String) -> Bool {
        let candidates: Set<String> = [
            "继续",
            "继续处理",
            "继续刚才任务",
            "继续刚才中断的任务",
            "恢复刚才任务",
            "恢复处理",
            "继续上次任务"
        ]
        return candidates.contains(normalized)
    }

    static func acceptanceDecision(from normalized: String) -> Bool? {
        let accepted = ["是", "y", "yes"]
        if accepted.contains(normalized) {
            return true
        }

        let rejected = ["否", "n", "no"]
        if rejected.contains(normalized) {
            return false
        }

        return nil
    }

    static func workflowGuidanceDecision(from text: String) -> Bool? {
        let normalized = RequestPlanningHeuristics.normalized(text)
        guard !normalized.isEmpty else {
            return nil
        }

        let rejectMarkers = [
            "不用", "先不用", "算了", "不需要", "不继续", "先别", "不是这个", "换个方向", "不要"
        ]
        if rejectMarkers.contains(where: { normalized.contains($0) }) {
            return false
        }

        if acceptanceDecision(from: normalized) == true {
            return true
        }

        let acceptMarkers = [
            "可以", "好", "好的", "行", "没问题", "同意", "合理",
            "按这个", "就这样", "开始", "继续", "来吧", "试试", "做吧"
        ]
        if acceptMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        return nil
    }

    static func shouldContinueWorkflowDesign(
        with text: String,
        context: WorkflowDesignContinuationContext
    ) -> Bool {
        let normalized = RequestPlanningHeuristics.normalized(text)
        guard !normalized.isEmpty else {
            return false
        }

        if workflowGuidanceDecision(from: text) == true {
            return true
        }

        let negativeMarkers = [
            "不用", "算了", "暂停", "先停", "不继续", "不用做", "不用继续"
        ]
        if negativeMarkers.contains(where: { normalized.contains($0) }) {
            return false
        }

        let continuationMarkers = [
            "补充", "另外", "还要", "再加", "增加", "主要是", "重点是", "我希望",
            "需要", "要求", "最好", "每天", "每周", "定时", "提醒", "通知", "推送",
            "流程", "步骤", "触发", "条件", "任务", "灵感", "字数", "章节", "写作",
            "小说", "发布", "完成后", "如果", "当", "然后", "并且"
        ]
        if continuationMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        let metaSwitchMarkers = [
            "意图分析", "planner", "skills", "skill", "agent 列表", "切换 agent",
            "打开", "启动", "退出", "关闭", "截图", "天气", "github", "mcp 服务"
        ]
        if metaSwitchMarkers.contains(where: { normalized.contains($0) }) {
            return false
        }

        let interruptionMarkers = [
            "中断", "断了", "没说完", "没写完", "写完", "继续写", "继续完善", "继续展开",
            "继续这个", "继续刚才", "为什么文本中断", "文本中断"
        ]
        if interruptionMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        let original = RequestPlanningHeuristics.normalized(context.originalInput)
        if !original.isEmpty,
           !Set(normalized.split(separator: " ")).isDisjoint(with: Set(original.split(separator: " "))) {
            return true
        }

        return normalized.count >= 18
    }

    static func shouldShowSkillEvolutionOverview(for normalized: String) -> Bool {
        let keywords = [
            "skill优化", "优化skill", "技能优化", "skill 迭代", "技能迭代",
            "有哪些skill需要优化", "哪些技能需要优化", "skill建议", "优化建议"
        ]
        return keywords.contains(where: { normalized.contains($0) })
    }

    static func shouldShowPlannerConsole(for normalized: String) -> Bool {
        let plannerKeywords = [
            "意图分析", "planner", "调度", "调度链路", "链路模块",
            "现在用的是啥", "现在用的是谁", "谁在做意图分析", "秘书层",
            "规划器", "路由链路"
        ]
        return plannerKeywords.contains(where: { normalized.contains($0) })
    }

    static func detectToolSkillCommand(
        in text: String,
        toolSkillRegistry: SkillRegistry
    ) -> (name: String, input: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let payload = String(trimmed.dropFirst())
        let parts = payload.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let rawName = parts.first else { return nil }

        let name = rawName.lowercased()
        guard toolSkillRegistry.getSkill(name) != nil else { return nil }

        let input = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : name
        return (name, input)
    }

    static func shouldRespondWithProjectSkillOverview(to text: String, images: [String]) -> Bool {
        guard images.isEmpty else {
            return false
        }

        let normalizedText = RequestPlanningHeuristics.normalized(text)

        if normalizedText.contains("openclaw") && (normalizedText.contains("skill") || normalizedText.contains("能力")) {
            return true
        }

        let skillKeywords = ["skill", "skills", "技能", "功能", "能做什么", "可以做什么", "会什么", "可用"]
        let requestKeywords = ["哪些", "什么", "查看", "列出", "介绍", "有哪些", "有什么"]

        let hasSkillIntent = skillKeywords.contains { normalizedText.contains($0) }
        let hasRequestIntent = requestKeywords.contains { normalizedText.contains($0) }
        return hasSkillIntent && hasRequestIntent
    }

    static func classifyAgentCreationRequest(_ text: String) -> AgentCreationRequestKind? {
        let normalizedText = RequestPlanningHeuristics.normalized(text)
        guard !normalizedText.isEmpty else { return nil }

        let createKeywords = [
            "创建", "新建", "新增", "添加", "配置", "设计", "做一个", "做个",
            "create", "build", "new"
        ]
        let agentKeywords = ["agent", "智能体", "助手", "机器人", "bot"]

        guard createKeywords.contains(where: { normalizedText.contains($0) }),
              agentKeywords.contains(where: { normalizedText.contains($0) }) else {
            return nil
        }

        let workflowKeywords = [
            "每天", "每周", "定时", "自动", "监控", "通知", "提醒", "订阅", "策略",
            "工作流", "任务", "服务", "接口", "部署", "执行", "分析", "跟踪", "告警",
            "开盘", "收盘", "cron", "schedule", "webhook", "mcp"
        ]
        let runtimeKeywords = [
            "openai", "anthropic", "claude", "moonshot", "kimi", "google", "gemini",
            "gpt", "api key", "apikey", "provider", "提供商", "模型", "llm"
        ]

        if workflowKeywords.contains(where: { normalizedText.contains($0) }) {
            return .workflowDesign
        }

        if runtimeKeywords.contains(where: { normalizedText.contains($0) }) {
            return .runtimeSetup
        }

        if text.count >= 80 || normalizedText.contains("需要") || normalizedText.contains("希望") {
            return .workflowDesign
        }

        return .runtimeSetup
    }

    static func plannedAgentSwitch(for parsed: ParsedInput, images: [String]) -> PlannedAgentSwitch? {
        guard let mention = parsed.agentMention else {
            return nil
        }

        let requiresVision = !images.isEmpty ||
            parsed.cleanText.lowercased().contains("图") ||
            parsed.cleanText.lowercased().contains("图片") ||
            parsed.cleanText.lowercased().contains("截图")
        let requiredCapability: Capability? = requiresVision ? .vision : nil

        return PlannedAgentSwitch(
            agent: mention.agent,
            reason: "通过 @\(mention.agentName) 指定",
            requiredCapability: requiredCapability
        )
    }

    static func shouldRespectCurrentAgentSelection(
        for text: String,
        images: [String],
        currentAgent: Agent?
    ) -> Bool {
        guard let currentAgent, images.isEmpty else {
            return false
        }

        return mentionsAgentIdentity(in: text, agent: currentAgent)
    }

    static func mentionsAgentIdentity(in text: String, agent: Agent?) -> Bool {
        guard let agent else {
            return false
        }

        let haystack = foldedIdentity(text)
        let keywords = agentIdentityKeywords(for: agent)
        return keywords.contains { keyword in
            let foldedKeyword = foldedIdentity(keyword)
            return !foldedKeyword.isEmpty && haystack.contains(foldedKeyword)
        }
    }

    private static func agentIdentityKeywords(for agent: Agent) -> [String] {
        var keywords = [
            agent.name,
            agent.displayName,
            agent.provider.displayName,
            agent.model
        ]

        if agent.provider == .ollama {
            keywords.append(contentsOf: ["kimi cli", "kimicli", "kimi", "kimi coder", "kimi-local"])
        }

        return keywords
    }

    private static func foldedIdentity(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}
