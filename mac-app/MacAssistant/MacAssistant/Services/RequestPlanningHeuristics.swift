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
        let accepted = ["是", "y", "yes", "确认"]
        if accepted.contains(normalized) {
            return true
        }

        let rejected = ["否", "n", "no"]
        if rejected.contains(normalized) {
            return false
        }

        return nil
    }

    static func workflowApprovalDecision(from text: String) -> Bool? {
        let normalized = RequestPlanningHeuristics.normalized(text)
        guard !normalized.isEmpty else { return nil }

        if acceptanceDecision(from: normalized) == true {
            return true
        }

        let approvedMarkers = ["通过", "批准", "同意", "继续执行", "执行吧", "可以执行"]
        if approvedMarkers.contains(normalized) || approvedMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        let rejectedMarkers = ["拒绝", "不通过", "别执行", "不要执行", "先别", "取消这步", "否决"]
        if rejectedMarkers.contains(normalized) || rejectedMarkers.contains(where: { normalized.contains($0) }) {
            return false
        }

        return nil
    }

    static func shouldCancelPendingFlow(_ text: String) -> Bool {
        let normalized = RequestPlanningHeuristics.normalized(text)
        guard !normalized.isEmpty else {
            return false
        }

        let exactMatches: Set<String> = [
            "取消", "取消吧", "取消了", "取消一下",
            "退出", "退出吧", "退出流程",
            "算了", "算了吧", "不用了", "先不用", "不继续了",
            "停止", "停止吧", "停一下", "停", "结束", "结束吧",
            "cancel", "stop", "quit", "exit", "never mind"
        ]
        if exactMatches.contains(normalized) {
            return true
        }

        let leadingMarkers = ["取消", "退出", "停止", "结束", "算了", "不用了"]
        if leadingMarkers.contains(where: { normalized.hasPrefix($0) }) {
            return true
        }

        let scopedMarkers = [
            "取消创建", "取消流程", "退出创建", "退出流程",
            "取消这个", "取消当前", "结束当前", "停止当前"
        ]
        return scopedMarkers.contains(where: { normalized.contains($0) })
    }

    static func browserStartURL(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = RequestPlanningHeuristics.normalized(text)
        guard !normalized.isEmpty else {
            return nil
        }

        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }

        let directSitePatterns = [
            #"(?:(?:打开|访问|进入|去|导航到)\s*)(.+)"#,
            #"(?:(?:网页|网站)\s*)(.+)"#
        ]

        for pattern in directSitePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(
                    in: trimmed,
                    options: [],
                    range: NSRange(location: 0, length: trimmed.utf16.count)
                  ),
                  let siteRange = Range(match.range(at: 1), in: trimmed) else {
                continue
            }

            let rawSite = String(trimmed[siteRange])
            if let url = buildBrowserURL(from: rawSite) {
                return url
            }
        }

        return nil
    }

    static func shouldContinueBrowserSession(
        with text: String,
        session: BrowserSession,
        lastMessage: ChatMessage?
    ) -> Bool {
        let normalizedText = RequestPlanningHeuristics.normalized(text)
        let observation = session.latestObservation ?? session.latestSnapshot.map(BrowserObservation.init(snapshot:))
        guard !normalizedText.isEmpty else {
            return false
        }

        if lastMessage?.metadata?[BrowserConversationMetadataKeys.pendingSessionID] == session.id {
            let promptKind = lastMessage?.metadata?[BrowserConversationMetadataKeys.promptKind]
            if promptKind == "confirmation",
               acceptanceDecision(from: normalizedText) != nil || normalizedText == "继续" {
                return true
            }
            if promptKind == "next_step",
               shouldTreatAsResumeCommand(normalizedText) {
                return true
            }
        }

        if (session.pendingAction != nil || session.status == .blockedByAuth) &&
            shouldTreatAsResumeCommand(normalizedText) {
            return true
        }

        if session.latestDelta?.becameReady == true &&
            (shouldTreatAsResumeCommand(normalizedText) || normalizedText == "继续") {
            return true
        }

        let markers = [
            "当前页面", "这个页面", "网页上", "浏览器里", "帮我看看", "识别页面",
            "继续登录", "继续网页", "点击登录", "输入账号", "填写账号",
            "用户名", "邮箱", "提交"
        ]
        if markers.contains(where: { normalizedText.contains($0) }) {
            return true
        }

        if let observation {
            let pageURL = RequestPlanningHeuristics.normalized(observation.url)
            let pageTitle = RequestPlanningHeuristics.normalized(observation.title)
            let isChatSession = observation.looksLikeChatSurface

            if isChatSession {
                let chatMarkers = [
                    "whatsapp", "消息", "聊天", "回复", "联系人",
                    "未读", "发送", "群聊", "对话", "接管", "托管", "扮演"
                ]
                if chatMarkers.contains(where: { normalizedText.contains($0) }) {
                    return true
                }
            }

            if !pageTitle.isEmpty && normalizedText.contains(pageTitle) {
                return true
            }
            if !pageURL.isEmpty && normalizedText.contains(pageURL) {
                return true
            }
        }

        return false
    }

    static func hasHighLevelBrowserAutomationIntent(_ text: String) -> Bool {
        let normalized = RequestPlanningHeuristics.normalized(text)
        let markers = [
            "接管", "托管", "代聊", "自动回复", "自动处理", "值守",
            "监控", "监听", "跟进", "持续处理", "帮我盯着", "代表我回复"
        ]
        return markers.contains(where: { normalized.contains($0) })
    }

    static func shouldPromoteActiveBrowserSessionToWorkflow(
        text: String,
        observation: BrowserObservation?
    ) -> Bool {
        guard let observation else {
            return false
        }

        let normalized = RequestPlanningHeuristics.normalized(text)
        guard hasHighLevelBrowserAutomationIntent(text) else {
            return false
        }

        if observation.looksLikeChatSurface {
            return true
        }

        if normalized.contains("持续") || normalized.contains("长期") || normalized.contains("自动") {
            return true
        }

        return observation.pageKind == .dashboard || observation.pageKind == .list
    }

    static func browserWorkflowCandidate(
        from text: String,
        observation: BrowserObservation?
    ) -> WorkflowCandidate? {
        guard let observation,
              shouldPromoteActiveBrowserSessionToWorkflow(text: text, observation: observation) else {
            return nil
        }

        let normalized = RequestPlanningHeuristics.normalized(text)
        var steps: [String]
        var missingSlots: [PlanningSlot] = []

        if observation.looksLikeChatSurface {
            steps = [
                "读取当前页面的未读消息与对话上下文",
                "根据既定角色生成候选回复或行动建议",
                "等待你确认后继续回复或执行下一步"
            ]

            let modeMarkers = ["自动发送", "直接发送", "无需确认", "先给草稿", "确认后发送", "草稿"]
            if !modeMarkers.contains(where: { normalized.contains($0) }) {
                missingSlots.append(
                    PlanningSlot(
                        name: "reply_mode",
                        description: "回复模式（例如：先给草稿确认 / 自动发送）",
                        isRequired: true,
                        value: nil
                    )
                )
            }

            let scopeMarkers = ["当前对话", "当前聊天", "指定联系人", "全部联系人", "所有联系人", "群聊"]
            if !scopeMarkers.contains(where: { normalized.contains($0) }) {
                missingSlots.append(
                    PlanningSlot(
                        name: "conversation_scope",
                        description: "处理范围（例如：当前对话 / 指定联系人 / 全部联系人）",
                        isRequired: true,
                        value: nil
                    )
                )
            }
        } else {
            steps = [
                "持续观察当前网页状态变化",
                "根据页面变化规划下一步浏览器动作",
                "必要时向你确认后继续执行"
            ]

            if !normalized.contains("当前页面") && !normalized.contains("这个页面") {
                missingSlots.append(
                    PlanningSlot(
                        name: "monitor_target",
                        description: "监控目标或页面范围",
                        isRequired: true,
                        value: nil
                    )
                )
            }
        }

        return WorkflowCandidate(
            name: observation.looksLikeChatSurface ? "网页聊天接待助手" : "网页观察与执行助手",
            description: observation.looksLikeChatSurface
                ? "基于当前聊天页面持续读取消息、生成回复并等待确认。"
                : "基于当前网页状态持续观察变化并协助执行下一步动作。",
            stepsPreview: steps,
            estimatedSteps: steps.count,
            needsConfirmation: true,
            requiredCapabilities: ["browser-observation", "browser-action"],
            missingSlots: missingSlots
        )
    }

    static func browserObservationSummary(
        session: BrowserSession,
        observation: BrowserObservation?,
        delta: BrowserObservationDelta?
    ) -> String {
        guard let observation else {
            return session.lastUserGoal.map { "当前浏览器仍在执行目标：\($0)" } ?? "当前有一个活动浏览器会话。"
        }

        if delta?.becameReady == true {
            return "页面刚切换为可操作状态。"
        }

        if delta?.becameBlockedByAuth == true {
            return "页面重新进入登录或扫码状态。"
        }

        if observation.looksLikeChatSurface {
            return observation.authState == .ready
                ? "当前是已登录的聊天页面。"
                : "当前是聊天页面，但还未完成登录或扫码。"
        }

        switch observation.pageKind {
        case .login:
            return "当前停留在登录页面。"
        case .form:
            return "当前停留在表单页面。"
        case .dashboard:
            return "当前停留在仪表盘页面。"
        default:
            return "当前页面类型为 \(observation.pageKind.rawValue)。"
        }
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

    private static func buildBrowserURL(from rawSite: String) -> String? {
        let noiseTokens = ["网页", "网站", "首页", "登录页", "页面", "官网"]
        var site = rawSite.trimmingCharacters(in: .whitespacesAndNewlines)
        noiseTokens.forEach { token in
            site = site.replacingOccurrences(of: token, with: "")
        }
        site = site.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = site.lowercased()

        let knownSites: [String: String] = [
            "google": "https://www.google.com",
            "github": "https://github.com",
            "youtube": "https://www.youtube.com",
            "bilibili": "https://www.bilibili.com",
            "百度": "https://www.baidu.com",
            "微博": "https://weibo.com",
            "知乎": "https://www.zhihu.com",
            "whatsapp": "https://web.whatsapp.com"
        ]

        if let url = knownSites[lowercased] {
            return url
        }

        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return site
        }

        if site.contains(".") {
            return "https://\(site)"
        }

        return nil
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
    
    // MARK: - Workflow Intent Detection (新增)
    
    /// 识别用户意图类型
    static func intentKind(from text: String) -> IntentKind {
        let normalized = RequestPlanningHeuristics.normalized(text)
        
        // 优先判断是否适合 workflow
        if shouldPromoteToWorkflow(normalized) {
            return .workflow
        }

        let serviceMarkers = ["mcp", "服务", "service"]
        if serviceMarkers.contains(where: { normalized.contains($0) }) {
            return .service
        }
        
        // 判断是否纯聊天
        let chatOnlyMarkers = ["你好", "在吗", "帮忙", "谢谢", "再见", "介绍一下"]
        if chatOnlyMarkers.contains(where: { normalized.contains($0) }) && normalized.count < 20 {
            return .chat
        }
        
        // 判断是否为单次任务
        let singleTaskMarkers = ["查一下", "搜一下", "打开", "看看", "截图", "天气"]
        if singleTaskMarkers.contains(where: { normalized.contains($0) }) {
            return .singleTask
        }
        
        return .chat
    }
    
    /// 判断是否应提升为 workflow
    static func shouldPromoteToWorkflow(_ text: String) -> Bool {
        let normalized = RequestPlanningHeuristics.normalized(text)
        
        // 排除纯查询类意图（不是执行/自动化意图）
        let queryOnlyPatterns = ["有哪些", "有什么", "是什么", "在哪里", "怎么样", "如何", "介绍", "说明"]
        let isQueryOnly = queryOnlyPatterns.contains(where: { normalized.contains($0) })
        
        // 明确排除"有哪些服务"这种查询
        if isQueryOnly && normalized.contains("服务") {
            return false
        }

        let scheduleMarkers = ["每天", "每周", "定时", "定期", "循环"]
        let mcpAutomationMarkers = ["mcp", "整理", "汇总", "日报", "热搜", "榜单", "简报"]
        if scheduleMarkers.contains(where: { normalized.contains($0) }) &&
            mcpAutomationMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }
        
        // 多步骤关键词
        let multiStepMarkers = [
            "每天", "每周", "定时", "定期", "循环", "自动化",
            "先然后", "第一步", "流程", "步骤", "编排",
            "完成后", "结束时", "触发", "条件", "如果"
        ]
        let multiStepCount = multiStepMarkers.filter { normalized.contains($0) }.count
        
        // 长期运行关键词
        let longRunningMarkers = [
            "监控", "跟踪", "监听", "观察", "记录",
            "提醒我", "通知我", "推送", "汇总", "报告",
            "整理", "简报", "日报", "热搜", "榜单"
        ]
        let longRunningCount = longRunningMarkers.filter { normalized.contains($0) }.count
        
        // 复杂协调关键词
        let coordinationMarkers = [
            "多个", "同时", "协调", "同步", "串联", "并联",
            "根据", "取决于", "不同情况", "分支", "判断"
        ]
        let coordinationCount = coordinationMarkers.filter { normalized.contains($0) }.count
        
        // 得分判定
        let score = multiStepCount * 2 + longRunningCount * 2 + coordinationCount * 3
        return score >= 4 || (multiStepCount >= 2 && longRunningCount >= 1)
    }
    
    /// 生成 workflow 候选
    static func workflowCandidate(from text: String) -> WorkflowCandidate? {
        guard shouldPromoteToWorkflow(text) else { return nil }
        
        let normalized = RequestPlanningHeuristics.normalized(text)
        
        // 提取 workflow 名称（简化版）
        let name = extractWorkflowName(from: normalized) ?? "未命名工作流"
        
        // 生成步骤预览
        let steps = extractWorkflowSteps(from: normalized)
        
        // 提取缺失的槽位
        let slots = extractPlanningSlots(from: normalized)
        
        return WorkflowCandidate(
            name: name,
            description: "基于用户输入: \(text.prefix(50))...",
            stepsPreview: steps,
            estimatedSteps: steps.count,
            needsConfirmation: !slots.isEmpty,
            requiredCapabilities: [],
            missingSlots: slots
        )
    }
    
    /// 提取信息槽位
    static func extractPlanningSlots(from text: String) -> [PlanningSlot] {
        let normalized = RequestPlanningHeuristics.normalized(text)
        var slots: [PlanningSlot] = []
        
        // 时间槽
        if normalized.contains("定时") || normalized.contains("每天") || normalized.contains("每周") {
            if !normalized.contains("点") && !normalized.contains(":") {
                slots.append(PlanningSlot(
                    name: "execution_time",
                    description: "执行时间（如：早上9点）",
                    isRequired: true,
                    value: nil
                ))
            }
        }
        
        // 目标/接收者槽
        let targetPatterns = [
            (pattern: #"发给(.+?)"#, slot: "recipient"),
            (pattern: #"给(.+?)发送"#, slot: "recipient"),
            (pattern: #"通知(.+?)"#, slot: "recipient")
        ]
        for (pattern, slotName) in targetPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
               let range = Range(match.range(at: 1), in: text) {
                let value = String(text[range]).trimmingCharacters(in: .whitespaces)
                if slots.firstIndex(where: { $0.name == slotName }) == nil {
                    slots.append(PlanningSlot(
                        name: slotName,
                        description: "目标接收者",
                        isRequired: true,
                        value: value
                    ))
                }
            }
        }
        
        // 内容槽
        if normalized.contains("内容") || normalized.contains("写") {
            if !normalized.contains("主题是") && !normalized.contains("关于") {
                slots.append(PlanningSlot(
                    name: "content_theme",
                    description: "内容主题",
                    isRequired: false,
                    value: nil
                ))
            }
        }
        
        return slots
    }

    static func fillPlanningSlots(from text: String, expectedSlots: [PlanningSlot]) -> [PlanningSlot] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = RequestPlanningHeuristics.normalized(text)
        guard !trimmed.isEmpty else {
            return expectedSlots
        }

        return expectedSlots.map { slot in
            guard !slot.isFilled else { return slot }

            switch slot.name {
            case "execution_time":
                let timeMarkers = ["点", ":", "早上", "上午", "中午", "下午", "晚上", "每天", "每周", "定时"]
                if timeMarkers.contains(where: { normalized.contains($0) }) {
                    return PlanningSlot(
                        name: slot.name,
                        description: slot.description,
                        isRequired: slot.isRequired,
                        value: trimmed
                    )
                }

            case "recipient":
                let patterns = [
                    #"发给(.+?)"#,
                    #"给(.+?)发送"#,
                    #"通知(.+?)"#,
                    #"发送给(.+?)"#
                ]
                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
                       let range = Range(match.range(at: 1), in: text) {
                        return PlanningSlot(
                            name: slot.name,
                            description: slot.description,
                            isRequired: slot.isRequired,
                            value: String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                }

                if expectedSlots.count == 1 {
                    return PlanningSlot(
                        name: slot.name,
                        description: slot.description,
                        isRequired: slot.isRequired,
                        value: trimmed
                    )
                }

            case "content_theme":
                if !trimmed.isEmpty {
                    return PlanningSlot(
                        name: slot.name,
                        description: slot.description,
                        isRequired: slot.isRequired,
                        value: trimmed
                    )
                }

            default:
                if expectedSlots.count == 1 {
                    return PlanningSlot(
                        name: slot.name,
                        description: slot.description,
                        isRequired: slot.isRequired,
                        value: trimmed
                    )
                }
            }

            return slot
        }
    }

    static func shouldPublishWorkflowDraft(_ text: String) -> Bool {
        if workflowGuidanceDecision(from: text) == true {
            return true
        }

        let normalized = RequestPlanningHeuristics.normalized(text)
        let markers = ["确认", "发布", "创建吧", "就这样", "开始配置", "开始执行", "启动吧"]
        return markers.contains(normalized) || markers.contains(where: { normalized.contains($0) })
    }

    static func shouldModifyWorkflowDraft(_ text: String) -> Bool {
        let normalized = RequestPlanningHeuristics.normalized(text)
        let markers = ["修改", "调整", "改一下", "编辑", "补充", "优化", "增加", "删掉", "替换"]
        return markers.contains(normalized) || markers.contains(where: { normalized.contains($0) })
    }

    static func workflowStepsPreview(from text: String) -> [String] {
        extractWorkflowSteps(from: text)
    }
    
    // MARK: - Private Helpers
    
    private static func extractWorkflowName(from text: String) -> String? {
        // 尝试从 "创建一个XX的workflow" 或 "帮我做XX" 中提取
        let patterns = [
            #"(?:创建|设计|做一个|帮我做)(?:一个)?(.+?)(?:的)?(?:工作流|workflow|自动化|任务)"#,
            #"(?:每天|每周|定时)(.+?)(?:的|通知|提醒|汇总)"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
               let range = Range(match.range(at: 1), in: text) {
                let name = String(text[range]).trimmingCharacters(in: .whitespaces)
                if name.count > 1 && name.count < 30 {
                    return name
                }
            }
        }
        return nil
    }
    
    private static func extractWorkflowSteps(from text: String) -> [String] {
        let normalized = RequestPlanningHeuristics.normalized(text)
        var steps: [String] = []
        
        // 基于关键词推测步骤
        if normalized.contains("查") || normalized.contains("看") || normalized.contains("监控") {
            steps.append("收集信息/数据")
        }
        if normalized.contains("分析") || normalized.contains("整理") || normalized.contains("汇总") {
            steps.append("分析处理")
        }
        if normalized.contains("写") || normalized.contains("生成") || normalized.contains("创建") {
            steps.append("生成内容")
        }
        if normalized.contains("发") || normalized.contains("通知") || normalized.contains("提醒") || normalized.contains("推送") {
            steps.append("发送/通知")
        }
        if normalized.contains("保存") || normalized.contains("记录") || normalized.contains("存档") {
            steps.append("保存记录")
        }
        
        // 如果没有识别到任何步骤，添加一个通用步骤
        if steps.isEmpty {
            steps.append("执行主任务")
        }
        
        return steps
    }
}
