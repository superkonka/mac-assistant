//
//  CommandRunner.swift
//  MacAssistant
//
//  主命令处理器，集成 OpenClaw 和 Agent 系统
//

import Foundation
import SwiftUI
import Combine
import AppKit
import CoreGraphics

class CommandRunner: ObservableObject {
    private struct TaskExecutionResult {
        let agent: Agent
        let content: String
        let failed: Bool
    }

    private enum AgentCreationRequestKind {
        case runtimeSetup
        case workflowDesign
    }

    @Published var messages: [ChatMessage] = [] {
        didSet {
            guard !isRestoringPersistedState else { return }
            StorageManager.shared.replaceRecentMessages(messages)
        }
    }
    @Published var taskSessions: [AgentTaskSession] = [] {
        didSet {
            guard !isRestoringPersistedState else { return }
            executionJournal.saveTaskSessions(taskSessions)
        }
    }
    @Published private(set) var messageExecutionTraces: [UUID: ExecutionTrace] = [:]
    @Published var currentExecutionTrace: ExecutionTrace?
    @Published var isProcessing = false
    
    /// 截图路径（最近一张）
    @Published var lastScreenshotPath: String?
    
    private let agentStore = AgentStore.shared
    private let orchestrator = AgentOrchestrator.shared
    private let creationSkill = AgentCreationSkill.shared
    private let intelligence = ConversationIntelligence.shared
    private let skillRegistry = AISkillRegistry.shared
    private let toolSkillRegistry = SkillRegistry.shared
    private let skillEvolutionAdvisor = SkillEvolutionAdvisor.shared
    private let gatewayClient = OpenClawGatewayClient.shared
    private let localKimiCLIService = LocalKimiCLIService.shared
    private let logger = ConversationLogger.shared
    private let preferences = UserPreferenceStore.shared
    private let executionJournal = ExecutionJournalStore.shared
    private let initialSetupPromptKey = "initial_setup_prompt"
    private let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    
    private var cancellables: Set<AnyCancellable> = []
    private var isWaitingForScreenRecordingAuthorization = false
    private var isRestartingForScreenRecordingPermission = false
    private var isWaitingForKimiCLILogin = false
    private var pendingKimiCLILoginAgentID: String?
    private var traceDismissTasks: [UUID: Task<Void, Never>] = [:]
    private var traceSettleTasks: [UUID: Task<Void, Never>] = [:]
    private var isRestoringPersistedState = false
    
    static let shared = CommandRunner()
    
    init() {
        restorePersistedState()
        setupNotifications()
        Task {
            await reconcileInterruptedTaskSessions(trigger: "launch")
        }
    }

    var isLoading: Bool { isProcessing }
    
    private func setupNotifications() {
        NotificationCenter.default.publisher(for: NSNotification.Name("ShowCapabilityDiscovery"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let gap = notification.object as? CapabilityGap {
                    self?.handleCapabilityGap(gap)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resumePendingScreenRecordingFlowIfNeeded()
                    await self?.resumePendingKimiCLILoginFlowIfNeeded()
                    await self?.reconcileInterruptedTaskSessions(trigger: "foreground")
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .skillEvolutionProposalReady)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let proposal = notification.object as? SkillEvolutionProposal else {
                    return
                }
                self?.presentSkillEvolutionProposal(proposal)
            }
            .store(in: &cancellables)

        _ = skillEvolutionAdvisor.scanNow()
    }
    
    // MARK: - 主要处理入口
    
    /// 处理用户输入（主入口 - 智能解析版）
    func processInput(_ text: String, images: [String] = []) async {
        let contextualImages = resolveImagesForRequest(text: text, explicitImages: images)

        // 1. 检查是否在 Agent 创建流程中
        if creationSkill.isInCreationFlow {
            await creationSkill.handleInput(text, runner: self)
            return
        }

        if await handleResumeRequestIfNeeded(text) {
            return
        }

        if let lastMessage = messages.last,
           let pendingProposalID = lastMessage.metadata?["pending_skill_evolution_id"] {
            let lowercased = text.lowercased().trimmingCharacters(in: .whitespaces)

            if lowercased == "是" || lowercased == "y" || lowercased == "yes" {
                let response = skillEvolutionAdvisor.acceptProposal(id: pendingProposalID)
                let message = ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: response,
                    timestamp: Date(),
                    agentId: "builtin-skill-evolution-advisor",
                    agentName: "Skill 迭代顾问"
                )
                await MainActor.run {
                    messages.append(message)
                    isProcessing = false
                }
                return
            } else if lowercased == "否" || lowercased == "n" || lowercased == "no" {
                let response = skillEvolutionAdvisor.rejectProposal(id: pendingProposalID)
                let message = ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: response,
                    timestamp: Date(),
                    agentId: "builtin-skill-evolution-advisor",
                    agentName: "Skill 迭代顾问"
                )
                await MainActor.run {
                    messages.append(message)
                    isProcessing = false
                }
                return
            }
        }
        
        // 2. 检查是否是 Skill 确认回复
        if let lastMessage = messages.last,
           let pendingSkill = lastMessage.metadata?["pending_skill"],
           let skillInput = lastMessage.metadata?["skill_input"] {
            let lowercased = text.lowercased().trimmingCharacters(in: .whitespaces)
            
            if lowercased == "是" || lowercased == "y" || lowercased == "yes" {
                // 用户确认执行 Skill
                if let skill = AISkill(rawValue: pendingSkill) {
                    preferences.recordSkillAcceptance(skill)
                    await handleSkillCommand(skill, input: skillInput, images: images)
                    return
                }
            } else if lowercased == "否" || lowercased == "n" || lowercased == "no" {
                // 用户拒绝，记录偏好
                if let skill = AISkill(rawValue: pendingSkill) {
                    preferences.recordSkillRejection(skill)
                    
                    let response = ChatMessage(
                        id: UUID(),
                        role: MessageRole.assistant,
                        content: "好的，已跳过。下次遇到类似情况不再提示此 Skill。",
                        timestamp: Date()
                    )
                    await MainActor.run {
                        messages.append(response)
                        isProcessing = false
                    }
                    return
                }
            }
        }

        if agentStore.needsInitialSetup {
            let userMessage = ChatMessage(
                id: UUID(),
                role: .user,
                content: text,
                timestamp: Date(),
                images: contextualImages
            )
            await MainActor.run {
                messages.append(userMessage)
                isProcessing = false
                presentInitialSetupPrompt(for: contextualImages.isEmpty ? "开始对话" : "处理附件请求")
            }
            return
        }
        
        // 3. 智能解析输入
        let parsed = intelligence.analyzeInput(text)
        
        // 4. 记录用户输入
        logger.logUserInput(text, parsed: parsed)
        
        // 3. 添加用户消息（显示原始输入）
        let userMessage = ChatMessage(
            id: UUID(),
            role: .user,
            content: text,
            timestamp: Date(),
            images: contextualImages
        )
        let userMessageID = userMessage.id
        await MainActor.run {
            clearFinishedExecutionTraces()
            messages.append(userMessage)
            isProcessing = true
        }

        if let toolSkillCommand = detectToolSkillCommand(in: text) {
            await handleToolSkillCommand(toolSkillCommand.name, input: toolSkillCommand.input)
            return
        }

        if await handleSkillEvolutionOverviewIfNeeded(text) {
            return
        }

        if await handleAgentCreationRequestIfNeeded(text) {
            return
        }

        if await handleDirectWebContextIfNeeded(text, images: contextualImages) {
            return
        }

        if let nativeMacSkillName = await MacSystemAgent.shared.suggestedSkillName(for: text) {
            await handleToolSkillCommand(nativeMacSkillName, input: text)
            return
        }

        if await handleProjectSkillOverviewIfNeeded(text, images: contextualImages) {
            return
        }
        
        // 4. 处理 @Agent 提及（检查是否涉及图片）
        if let mention = parsed.agentMention {
            let requiresVision = !contextualImages.isEmpty ||
                                parsed.cleanText.lowercased().contains("图") ||
                                parsed.cleanText.lowercased().contains("图片") ||
                                parsed.cleanText.lowercased().contains("截图")
            let requiredCapability: Capability? = requiresVision ? .vision : nil
            await handleAgentSwitch(mention.agent, reason: "通过 @\(mention.agentName) 指定", requiredCapability: requiredCapability)
        }
        
        // 5. 处理 /Skill 命令
        if let skillCommand = parsed.skillCommand {
            await handleSkillCommand(skillCommand.skill, input: parsed.cleanText, images: contextualImages)
            return
        }
        
        // 6. 处理检测到的 Skill 意图（需要确认）
        if let detectedSkill = parsed.detectedSkill {
            await handleDetectedSkill(
                detectedSkill,
                input: parsed.cleanText,
                images: contextualImages,
                anchorMessageID: userMessageID
            )
            return
        }
        
        // 7. 处理 Agent 建议
        if let agentSuggestion = parsed.suggestedAgent {
            await handleAgentSuggestion(agentSuggestion, input: parsed.cleanText, images: contextualImages)
            return
        }
        
        // 8. 普通消息处理（使用解析后的纯净文本）
        await processCleanInput(parsed.cleanText, images: contextualImages, anchorMessageID: userMessageID)
    }

    private func detectToolSkillCommand(in text: String) -> (name: String, input: String)? {
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

    private func handleProjectSkillOverviewIfNeeded(_ text: String, images: [String]) async -> Bool {
        guard images.isEmpty, shouldRespondWithProjectSkillOverview(to: text) else {
            return false
        }

        let currentAgentName = orchestrator.currentAgent?.name
        let content = await openClawSkillOverviewMessage()
        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date(),
            agentId: orchestrator.currentAgent?.id,
            agentName: currentAgentName
        )

        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowSkillsBrowser"),
                object: nil
            )
            messages.append(message)
            isProcessing = false
        }
        return true
    }

    private func shouldRespondWithProjectSkillOverview(to text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.contains("openclaw") && (normalized.contains("skill") || normalized.contains("能力")) {
            return true
        }

        let skillKeywords = ["skill", "skills", "技能", "功能", "能做什么", "可以做什么", "会什么", "可用"]
        let requestKeywords = ["哪些", "什么", "查看", "列出", "介绍", "有哪些", "有什么"]

        let hasSkillIntent = skillKeywords.contains { normalized.contains($0) }
        let hasRequestIntent = requestKeywords.contains { normalized.contains($0) }
        return hasSkillIntent && hasRequestIntent
    }

    private func projectSkillOverviewMessage() -> String {
        let currentAgent = orchestrator.currentAgent?.displayName ?? "当前 Agent"
        let builtinSummary = builtInSkillAudienceSummary()
        let toolCommands = toolSkillRegistry
            .allSkillNames()
            .map { "`/\($0)`" }
            .joined(separator: "、")

        return """
        我已经把 Skills 面板打开了。

        现在你能直接调用的能力，可以先这样理解：

        1. 对话内置能力
        \(builtinSummary)

        2. 命令型工具
        • 当前内置命令包括 \(toolCommands)
        • 更适合系统、文件、App、Git、Futu 这类明确操作

        3. 外部市场
        • 你可以在 Skills 面板的“市场”页安装或卸载更多 ClawHub Skills
        • 安装后，OpenClaw runtime 会自动刷新新能力

        你现在正在使用 \(currentAgent)。
        直接告诉我目标就行，例如：
        • “帮我审查这个 PR”
        • “打开 Safari”
        • “查一下上海未来三天天气”
        """
    }

    private func openClawSkillOverviewMessage() async -> String {
        do {
            let report = try await gatewayClient.skillsStatus()
            let eligibleSkills = report.skills.filter { $0.eligible && !$0.disabled }
            let unavailableSkills = report.skills.filter { !$0.eligible || $0.disabled }
            var sections: [String] = [
                "我已经把 Skills 面板打开了。",
                "你现在能直接用的能力，重点看这三层：",
                "1. 对话内置能力\n\(builtInSkillAudienceSummary())"
            ]

            if eligibleSkills.isEmpty {
                sections.append("2. 已就绪的扩展 Skills\n• 当前还没有可直接运行的外部 Skill。")
            } else {
                sections.append(
                    "2. 已就绪的扩展 Skills（\(eligibleSkills.count) 个）\n\(groupedOpenClawSkillSummary(for: eligibleSkills))"
                )
            }

            if !unavailableSkills.isEmpty {
                sections.append(
                    "3. 还没就绪的扩展 Skills（\(unavailableSkills.count) 个）\n\(unavailableOpenClawSkillSummary(for: unavailableSkills))"
                )
            } else {
                sections.append("3. 环境状态\n• 当前已检测到的扩展 Skills 都满足运行条件。")
            }

            sections.append(
                """
                如果这批能力还不够，你可以直接在 Skills 面板的“市场”页继续安装更多 Skills。
                也可以直接说目标，我会自己选最合适的能力，比如：
                • 帮我审查这个 PR
                • 检查这台 Mac 的安全配置
                • 查下上海未来三天天气
                """
            )
            return sections.joined(separator: "\n\n")
        } catch {
            return projectSkillOverviewMessage()
        }
    }

    private func builtInSkillAudienceSummary() -> String {
        let availableSkills = skillRegistry.skills.filter(skillRegistry.isAvailable)
        let grouped = Dictionary(grouping: availableSkills, by: builtInSkillAudienceGroupTitle(for:))
        let orderedTitles = ["视觉与截图", "文本与代码", "联网与检索"]

        let lines = orderedTitles.compactMap { title -> String? in
            guard let skills = grouped[title], !skills.isEmpty else { return nil }
            let names = skills.map(\.name).joined(separator: "、")
            return "• \(title)：\(names)"
        }

        if lines.isEmpty {
            return "• 当前没有已就绪的内置 Skill。"
        }

        let unavailableCount = skillRegistry.skills.count - availableSkills.count
        if unavailableCount > 0 {
            return lines.joined(separator: "\n") + "\n• 另有 \(unavailableCount) 个内置 Skill 会在你切换到对应 Agent 后自动可用"
        }
        return lines.joined(separator: "\n")
    }

    private func builtInSkillAudienceGroupTitle(for skill: AISkill) -> String {
        switch skill {
        case .screenshot, .createVisionAgent, .analyzeImage:
            return "视觉与截图"
        case .codeReview, .explainSelection, .translateText, .summarizeText:
            return "文本与代码"
        case .webSearch:
            return "联网与检索"
        }
    }

    private func groupedOpenClawSkillSummary(for skills: [OpenClawSkillStatus]) -> String {
        let grouped = Dictionary(grouping: skills, by: openClawSkillGroupTitle(for:))
        let orderedTitles = ["开发与仓库", "系统与运维", "内容与平台", "信息查询", "扩展工具"]

        return orderedTitles.compactMap { title -> String? in
            guard let groupSkills = grouped[title], !groupSkills.isEmpty else { return nil }
            let lines = groupSkills
                .sorted(by: { $0.name < $1.name })
                .map { "• `\($0.name)`: \(friendlyOpenClawSummary(for: $0))" }
                .joined(separator: "\n")
            return "\(title)\n\(lines)"
        }
        .joined(separator: "\n\n")
    }

    private func unavailableOpenClawSkillSummary(for skills: [OpenClawSkillStatus]) -> String {
        let missingDependencies = Array(
            Set(
                skills.flatMap { skill in
                    skill.missing.bins + skill.missing.env + skill.missing.config
                }
            )
        )
        .sorted()

        let dependencyLine: String
        if missingDependencies.isEmpty {
            dependencyLine = "• 这些 Skill 当前主要是未启用状态。"
        } else {
            let preview = missingDependencies.prefix(6).map { "`\($0)`" }.joined(separator: "、")
            dependencyLine = "• 当前主要缺少这些依赖：\(preview)"
        }

        let detailLines = skills
            .prefix(4)
            .map { skill -> String in
                let missing = skill.missing.bins + skill.missing.env + skill.missing.config
                if missing.isEmpty {
                    return "• `\(skill.name)`: 当前未启用"
                }
                return "• `\(skill.name)`: 缺少 \(missing.joined(separator: ", "))"
            }
            .joined(separator: "\n")

        if detailLines.isEmpty {
            return dependencyLine
        }

        return """
        \(dependencyLine)
        \(detailLines)
        需要的话，我可以继续带你补环境，或者去市场安装替代 Skill。
        """
    }

    private func openClawSkillGroupTitle(for skill: OpenClawSkillStatus) -> String {
        let haystack = "\(skill.name) \(skill.description)".lowercased()

        if haystack.contains("weather") || haystack.contains("forecast") || haystack.contains("temperature") {
            return "信息查询"
        }

        if haystack.contains("xiaohongshu") || haystack.contains("小红书") || haystack.contains("comment") || haystack.contains("favorite") || haystack.contains("post") {
            return "内容与平台"
        }

        if haystack.contains("health") || haystack.contains("security") || haystack.contains("firewall") || haystack.contains("ssh") || haystack.contains("risk") || haystack.contains("host") {
            return "系统与运维"
        }

        if haystack.contains("coding") || haystack.contains("code") || haystack.contains("git") || haystack.contains("github") || haystack.contains("repo") || haystack.contains("pr") || haystack.contains("session") {
            return "开发与仓库"
        }

        return "扩展工具"
    }

    private func friendlyOpenClawSummary(for skill: OpenClawSkillStatus) -> String {
        switch skill.name {
        case "coding-agent":
            return "复杂编码任务、重构和 PR 处理"
        case "git-github-manager":
            return "Git / GitHub、PR、Issue、Release 管理"
        case "healthcheck":
            return "主机安全巡检、SSH / 防火墙 / 更新风险检查"
        case "session-logs":
            return "搜索和分析历史会话日志"
        case "weather":
            return "查询天气和短期预报"
        case "xiaohongshu-manager":
            return "管理小红书内容、互动和账号状态"
        default:
            return compactSkillDescription(skill.description)
        }
    }

    private func compactSkillDescription(_ description: String) -> String {
        let separators = [
            "Use when:",
            "NOT for:",
            "Requires ",
            "Requires:",
            " This skill",
            "\n"
        ]

        for separator in separators {
            if let range = description.range(of: separator) {
                let trimmed = description[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handleSkillEvolutionOverviewIfNeeded(_ text: String) async -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = [
            "skill优化", "优化skill", "技能优化", "skill 迭代", "技能迭代",
            "有哪些skill需要优化", "哪些技能需要优化", "skill建议", "优化建议"
        ]

        guard keywords.contains(where: { normalized.contains($0) }) else {
            return false
        }

        let newlyDiscovered = skillEvolutionAdvisor.scanNow()
        if !newlyDiscovered.isEmpty {
            await MainActor.run {
                for proposal in newlyDiscovered {
                    presentSkillEvolutionProposal(proposal)
                }
            }
        }

        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: skillEvolutionAdvisor.summaryMessage(),
            timestamp: Date(),
            agentId: "builtin-skill-evolution-advisor",
            agentName: "Skill 迭代顾问"
        )

        await MainActor.run {
            messages.append(message)
            isProcessing = false
        }
        return true
    }

    private func handleAgentCreationRequestIfNeeded(_ text: String) async -> Bool {
        guard let kind = classifyAgentCreationRequest(text) else {
            return false
        }

        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: agentCreationGuidanceMessage(for: kind, originalInput: text),
            timestamp: Date(),
            agentId: "builtin-agent-creation-guard",
            agentName: "Agent 创建顾问"
        )

        await MainActor.run {
            messages.append(message)
            isProcessing = false

            if kind == .runtimeSetup {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ShowInitialSetupWizard"),
                    object: nil
                )
            }
        }

        return true
    }

    private func classifyAgentCreationRequest(_ text: String) -> AgentCreationRequestKind? {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let createKeywords = [
            "创建", "新建", "新增", "添加", "配置", "设计", "做一个", "做个",
            "create", "build", "new"
        ]
        let agentKeywords = ["agent", "智能体", "助手", "机器人", "bot"]

        guard createKeywords.contains(where: { normalized.contains($0) }),
              agentKeywords.contains(where: { normalized.contains($0) }) else {
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

        if workflowKeywords.contains(where: { normalized.contains($0) }) {
            return .workflowDesign
        }

        if runtimeKeywords.contains(where: { normalized.contains($0) }) {
            return .runtimeSetup
        }

        if text.count >= 80 || normalized.contains("需要") || normalized.contains("希望") {
            return .workflowDesign
        }

        return .runtimeSetup
    }

    private func agentCreationGuidanceMessage(
        for kind: AgentCreationRequestKind,
        originalInput: String
    ) -> String {
        switch kind {
        case .runtimeSetup:
            return """
            我已经把这次请求切到 **本地 Agent 配置流程**，不会再交给通用对话 Agent 去“自己创建 Agent”。

            当前应用里“创建 Agent”指的是：
            • 配置 provider / model / 凭证
            • 建立一个可被路由的模型入口

            我已经为你打开配置向导。完成后，这个 Agent 就能参与正常对话和自愈切换。
            """

        case .workflowDesign:
            return """
            这次你的需求更像是 **业务工作流 Agent**，不是当前应用里那种“模型接入型 Agent”。

            你描述的是：
            \(originalInput)

            当前版本的 Agent 目前只承载：
            • provider / model / 凭证
            • 基础能力路由（文本、代码、视觉等）

            还**不能**直接承载：
            • 专属业务规则
            • 定时任务 / 订阅 / 提醒
            • 服务编排 / 状态跟踪

            所以把这类需求直接交给 Kimi / OpenClaw 去“设计并创建 Agent”是不合理的，我已经拦截了这条路径，避免再掉进长任务收尾丢失。

            更合理的落法是：
            1. 先保留一个可用的基础模型 Agent
            2. 再把这类股票监控 / 定时分析 / 通知逻辑沉淀成 Skill 或 AutoAgent 工作流

            如果你愿意，我下一步可以直接把这类“业务 Agent”整理成一份可落地的 Skill / AutoAgent 方案，而不是继续走当前这条伪创建流程。
            """
        }
    }

    private func handleDirectWebContextIfNeeded(_ text: String, images: [String]) async -> Bool {
        guard let content = await WebContextAgent.shared.responseIfNeeded(for: text, images: images) else {
            return false
        }

        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date(),
            agentId: "builtin-web-context-agent",
            agentName: "网页读取 Agent"
        )

        await MainActor.run {
            messages.append(message)
            isProcessing = false
        }

        return true
    }

    private func handleToolSkillCommand(_ skillName: String, input: String) async {
        guard let skill = toolSkillRegistry.getSkill(skillName) else {
            await MainActor.run {
                isProcessing = false
            }
            return
        }

        let args = input.split(whereSeparator: \.isWhitespace).map(String.init)
        let responseIdentity = toolSkillIdentity(for: skillName)

        do {
            let result = try await skill.execute(input, args: args)
            let message = ChatMessage(
                id: UUID(),
                role: .assistant,
                content: result,
                timestamp: Date(),
                agentId: responseIdentity.id,
                agentName: responseIdentity.name
            )

            await MainActor.run {
                messages.append(message)
                isProcessing = false
            }
        } catch {
            let message = ChatMessage(
                id: UUID(),
                role: .assistant,
                content: UserFacingErrorFormatter.inlineMessage(for: error, providerName: "/\(skillName)"),
                timestamp: Date(),
                agentId: responseIdentity.id,
                agentName: responseIdentity.name
            )

            await MainActor.run {
                messages.append(message)
                isProcessing = false
            }
        }
    }

    private func toolSkillIdentity(for skillName: String) -> (id: String?, name: String?) {
        switch skillName {
        case "app", "futu":
            return ("builtin-mac-operator", "Mac 操作 Agent")
        default:
            return (orchestrator.currentAgent?.id, orchestrator.currentAgent?.name)
        }
    }

    private func presentSkillEvolutionProposal(_ proposal: SkillEvolutionProposal) {
        let evidence = proposal.evidence.map { "• \($0)" }.joined(separator: "\n")
        let improvements = proposal.improvements.map { "• \($0)" }.joined(separator: "\n")

        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: """
            💡 检测到一条 Skill 优化提案

            目标 Skill: \(proposal.skillName)
            版本变化: v\(proposal.currentVersion) -> v\(proposal.suggestedVersion)
            原因: \(proposal.reason)

            观察依据：
            \(evidence)

            建议落地：
            \(improvements)

            回复 "是" 或 "y" 确认应用这条优化
            回复 "否" 或 "n" 忽略这条提案
            """,
            timestamp: Date(),
            agentId: "builtin-skill-evolution-advisor",
            agentName: "Skill 迭代顾问",
            metadata: ["pending_skill_evolution_id": proposal.id]
        )

        messages.append(message)
    }
    
    /// 处理纯净输入
    private func processCleanInput(_ text: String, images: [String], anchorMessageID: UUID) async {
        // 检测意图
        let intent = await orchestrator.analyzeIntent(text)
        
        // 路由决策
        let routingResult = await orchestrator.route(text, images: images, intent: intent)
        
        // 处理路由结果
        switch routingResult {
        case .agentSelected(let agent):
            await handleAgentRequest(
                agent: agent,
                text: text,
                images: images,
                intent: intent,
                anchorMessageID: anchorMessageID
            )
            
        case .gapDetected(let gap):
            await handleCapabilityGapInChat(gap: gap)
            
        case .multipleAgents(let agents):
            await handleMultipleAgentOptions(agents: agents, text: text, images: images)
        }
    }
    
    /// 处理截图命令
    func handleScreenshot() {
        Task {
            let canCapture = await MainActor.run {
                ensureScreenRecordingAccessForScreenshot()
            }
            guard canCapture else { return }

            guard let screenshotPath = saveScreenshotToDesktop() else {
                await MainActor.run {
                    appendSystemMessage(
                        "这次没有生成截图文件。可能是你取消了截图，或者屏幕录制权限还没有真正生效。"
                    )
                }
                return
            }

            await MainActor.run {
                completeScreenshotFlow(with: screenshotPath)
            }
        }
    }
    
    // MARK: - 智能处理方法
    
    /// 处理 Agent 切换（带能力检查）
    private func handleAgentSwitch(_ agent: Agent, reason: String, requiredCapability: Capability? = nil) async {
        // 检查是否需要特定能力
        if let capability = requiredCapability {
            if !agent.supports(capability) {
                // Agent 不支持所需能力，引导创建而不是切换
                let gap = CapabilityGap(
                    missingCapability: capability,
                    suggestedProviders: [.openai, .anthropic, .moonshot],
                    description: "\(agent.displayName) 不支持 \(capability.displayName) 能力"
                )
                
                let systemMessage = ChatMessage(
                    id: UUID(),
                    role: MessageRole.system,
                    content: """
                    ⚠️ \(agent.displayName) 不支持 \(capability.displayName)
                    
                    💡 我可以立即帮你创建一个支持此能力的 Agent：
                    """,
                    timestamp: Date()
                )
                
                await MainActor.run {
                    messages.append(systemMessage)
                    creationSkill.initiateCreation(for: gap, in: self)
                    isProcessing = false
                }
                
                // 记录能力缺口
                logger.logCapabilityGap(gap, context: "切换 Agent 时发现能力不匹配")
                return
            }
        }
        
        let previousAgent = orchestrator.currentAgent
        orchestrator.switchToAgent(agent)
        
        // 记录 Agent 切换
        logger.logAgentSwitch(from: previousAgent, to: agent, reason: reason)
        
        let systemMessage = ChatMessage(
            id: UUID(),
            role: MessageRole.system,
            content: "🔄 \(reason)，已切换到 \(agent.displayName)",
            timestamp: Date()
        )
        await MainActor.run {
            messages.append(systemMessage)
        }
    }
    
    /// 处理 Skill 命令
    private func handleSkillCommand(_ skill: AISkill, input: String, images: [String]) async {
        let startTime = Date()
        
        let context = MacAssistant.SkillContext(
            input: input,
            images: images,
            currentAgent: orchestrator.currentAgent,
            runner: self
        )
        
        let result = await skillRegistry.execute(skill, context: context)
        let duration = Date().timeIntervalSince(startTime)
        
        // 记录 Skill 执行
        logger.logSkillExecution(skill, result: result, duration: duration)
        
        await MainActor.run {
            isProcessing = false
            handleSkillResult(result, for: skill)
        }
    }
    
    /// 处理检测到的 Skill 意图（带确认，考虑用户偏好）
    private func handleDetectedSkill(
        _ skill: AISkill,
        input: String,
        images: [String],
        anchorMessageID: UUID
    ) async {
        // 1. 检查是否应该跳过（用户之前拒绝过）
        if preferences.shouldSkipDetection(skill) {
            // 直接发送纯净文本，不提示 Skill
            await processCleanInput(input, images: images, anchorMessageID: anchorMessageID)
            return
        }
        
        // 2. 检查是否应该自动确认（用户经常使用）
        if preferences.shouldAutoConfirm(skill) {
            await handleSkillCommand(skill, input: input, images: images)
            return
        }
        
        // 3. 显示确认提示
        let confirmMessage = ChatMessage(
            id: UUID(),
            role: MessageRole.assistant,
            content: """
            💡 检测到 **\(skill.name)** 意图
            
            "\(input)"
            
            是否使用 \(skill.emoji) \(skill.name)？
            回复 "是" 或 "y" 确认执行
            回复 "否" 或 "n" 拒绝（下次不再提示此 Skill）
            """,
            timestamp: Date(),
            metadata: ["pending_skill": skill.rawValue, "skill_input": input]
        )
        await MainActor.run {
            messages.append(confirmMessage)
            isProcessing = false
        }
    }
    
    /// 处理 Agent 建议
    private func handleAgentSuggestion(_ suggestion: AgentSuggestion, input: String, images: [String]) async {
        switch suggestion.action {
        case .switchAgent:
            if let agent = suggestion.suggestedAgent {
                if shouldAutoDelegateToSuggestedAgent(input: input, images: images, suggestedAgent: agent) {
                    await delegateRequest(
                        to: agent,
                        text: input,
                        images: images,
                        intent: .imageAnalysis,
                        reason: "当前 Agent 不支持图片分析，已自动委托给 \(agent.displayName) 继续处理这次图片请求。"
                    )
                    return
                }

                let confirmMessage = ChatMessage(
                    id: UUID(),
                    role: MessageRole.assistant,
                    content: """
                    💡 \(suggestion.reason)
                    
                    建议切换到 \(agent.displayName) 来处理此请求。
                    
                    是否切换？
                    回复 "是" 或 "y" 确认切换并发送消息。
                    回复 "否" 或 "n" 使用当前 Agent 继续。
                    """,
                    timestamp: Date(),
                    metadata: ["pending_switch": agent.id, "pending_input": input]
                )
                await MainActor.run {
                    messages.append(confirmMessage)
                    isProcessing = false
                }
            }
            
        case .createVisionAgent:
            // 直接进入 Agent 创建流程
            if let gap = orchestrator.discoverGap(for: input) {
                await MainActor.run {
                    creationSkill.initiateCreation(for: gap, in: self)
                    isProcessing = false
                }
            }
        }
    }
    
    /// 处理 Skill 执行结果
    private func handleSkillResult(_ result: SkillResult, for skill: AISkill) {
        switch result {
        case .success(let message):
            let successMessage = ChatMessage(
                id: UUID(),
                role: MessageRole.assistant,
                content: "✅ \(skill.name) 执行成功：\(message)",
                timestamp: Date()
            )
            messages.append(successMessage)
            
        case .requiresInput(let prompt):
            let inputMessage = ChatMessage(
                id: UUID(),
                role: MessageRole.assistant,
                content: "🎯 **\(skill.name)** 需要更多信息：\n\n\(prompt)",
                timestamp: Date()
            )
            messages.append(inputMessage)
            
        case .requiresAgentCreation(let gap):
            creationSkill.initiateCreation(for: gap, in: self)
            
        case .error(let message):
            let errorMessage = ChatMessage(
                id: UUID(),
                role: MessageRole.assistant,
                content: "❌ \(skill.name) 执行失败：\(message)",
                timestamp: Date()
            )
            messages.append(errorMessage)
        }
    }
    
    // MARK: - 路由处理
    
    /// 使用选定 Agent 处理请求
    private func handleAgentRequest(
        agent: Agent,
        text: String,
        images: [String],
        intent: Intent,
        anchorMessageID: UUID
    ) async {
        let traceID = await MainActor.run {
            startExecutionTrace(
                anchorMessageID: anchorMessageID,
                agentName: agent.displayName,
                intentName: intent.displayName,
                summary: "OpenClaw 正在把这次请求交给 \(agent.displayName)"
            )
        }
        
        // 发送给 OpenClaw
        await sendToOpenClaw(agent: agent, text: text, images: images, traceID: traceID)
    }
    
    /// 处理能力缺口（聊天内引导）
    private func handleCapabilityGapInChat(gap: CapabilityGap) async {
        // 记录能力缺口
        logger.logCapabilityGap(gap, context: "处理用户请求时检测到")
        
        // 检查是否是图片分析需求
        if gap.missingCapability == .vision || gap.missingCapability == .imageAnalysis {
            // 启动对话引导创建
            await MainActor.run {
                creationSkill.initiateCreation(for: gap, in: self)
            }
        } else {
            // 其他能力缺口，显示简单提示
            let message = ChatMessage(
                id: UUID(),
                role: .assistant,
                content: """
                💡 需要 **\(gap.missingCapability.displayName)** 能力
                
                \(gap.description)
                
                建议的提供商: \(gap.suggestedProviders.map { $0.displayName }.joined(separator: ", "))
                
                您可以在 Agent 列表中创建一个支持此能力的 Agent。
                """,
                timestamp: Date()
            )
            await MainActor.run {
                messages.append(message)
                isProcessing = false
            }
        }
    }
    
    /// 处理多个可选 Agent
    private func handleMultipleAgentOptions(agents: [Agent], text: String, images: [String]) async {
        var options = "找到多个可用的 Agent:\n\n"
        for (index, agent) in agents.enumerated() {
            options += "\(index + 1). \(agent.displayName) - \(agent.shortDescription)\n"
        }
        options += "\n回复数字选择，或直接输入继续。"
        
        let message = ChatMessage(
            id: UUID(),
            role: .system,
            content: options,
            timestamp: Date()
        )
        await MainActor.run {
            messages.append(message)
            isProcessing = false
        }
    }
    
    // MARK: - 视觉能力缺口处理
    
    private func handleVisionGap(screenshotPath: String) {
        if let agent = preferredAgent(for: .vision) {
            Task {
                await delegateRequest(
                    to: agent,
                    text: "分析这张截图",
                    images: [screenshotPath],
                    intent: .imageAnalysis,
                    reason: "当前 Agent 不支持图片分析，已自动委托给 \(agent.displayName) 处理刚才的截图。"
                )
            }
            return
        }

        // 检测能力缺口
        if let gap = orchestrator.discoverGap(for: "分析这张截图") {
            // 在聊天中启动创建流程
            creationSkill.initiateCreation(for: gap, in: self)
        }
    }
    
    // MARK: - OpenClaw 集成
    
    private func sendToOpenClaw(
        agent: Agent,
        text: String,
        images: [String],
        traceID: UUID? = nil
    ) async {
        let startTime = Date()
        let assistantMessage = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: "⏳ \(agent.name) 正在思考...",
            timestamp: Date(),
            agentId: agent.id,
            agentName: agent.name
        )
        
        do {
            await MainActor.run {
                messages.append(assistantMessage)
                if let traceID {
                    attachExecutionTrace(traceID: traceID, to: assistantMessage.id)
                    updateExecutionTrace(
                        traceID: traceID,
                        state: .running,
                        agentName: agent.displayName,
                        summary: "\(agent.displayName) 正在返回结果"
                    )
                }
            }

            let fullContent = try await sendViaGateway(
                agent: agent,
                sessionKey: "main",
                sessionLabel: "Main",
                text: text,
                images: images,
                assistantMessageID: assistantMessage.id
            )
            
            let duration = Date().timeIntervalSince(startTime)
            logger.logSystemResponse(fullContent, agent: agent)
            logger.logPerformance(operation: "openclaw_request", duration: duration)
            
            await MainActor.run {
                upsertAssistantMessage(
                    template: assistantMessage,
                    content: fullContent
                )
                if let traceID {
                    completeExecutionTrace(traceID: traceID, summary: "这次请求已处理完成")
                }
                isProcessing = false
            }
            
        } catch {
            logger.logError(error, context: "发送请求到 OpenClaw")

            var terminalError = error
            var terminalAgent = agent

            await maybeStartKimiCLILoginRecovery(after: error, for: agent)

            if UserFacingErrorFormatter.shouldTemporarilySuspendAgent(after: error) {
                agentStore.markTemporarilyUnavailable(agent)
            }

            for fallbackAgent in fallbackAgentsForRecoverableFailure(
                after: error,
                failingAgent: agent,
                images: images
            ) {
                logger.logAgentSwitch(
                    from: agent,
                    to: fallbackAgent,
                    reason: "\(UserFacingErrorFormatter.recoveryFailureSummary(for: error))后自动切换到可用 Agent"
                )
                orchestrator.switchToAgent(fallbackAgent)

                await MainActor.run {
                    if let traceID {
                        updateExecutionTrace(
                            traceID: traceID,
                            state: .fallback,
                            agentName: fallbackAgent.displayName,
                            transitionLabel: "自动回退",
                            summary: "\(agent.displayName) \(UserFacingErrorFormatter.recoveryFailureSummary(for: error))，已切换到 \(fallbackAgent.displayName)"
                        )
                    }
                    updateAssistantIdentity(
                        id: assistantMessage.id,
                        agentId: fallbackAgent.id,
                        agentName: fallbackAgent.name
                    )
                    upsertAssistantMessage(
                        template: ChatMessage(
                            id: assistantMessage.id,
                            role: .assistant,
                            content: "⏳ \(fallbackAgent.name) 正在继续处理...",
                            timestamp: assistantMessage.timestamp,
                            agentId: fallbackAgent.id,
                            agentName: fallbackAgent.name
                        ),
                        content: "⏳ \(fallbackAgent.name) 正在继续处理..."
                    )
                }

                do {
                    terminalAgent = fallbackAgent
                    let fallbackContent = try await sendViaGateway(
                        agent: fallbackAgent,
                        sessionKey: "main",
                        sessionLabel: "Main",
                        text: text,
                        images: images,
                        assistantMessageID: assistantMessage.id
                    )

                    let duration = Date().timeIntervalSince(startTime)
                    logger.logSystemResponse(fallbackContent, agent: fallbackAgent)
                    logger.logPerformance(operation: "openclaw_request_auth_fallback", duration: duration)
                    agentStore.restoreAvailability(for: fallbackAgent)

                    await MainActor.run {
                        upsertAssistantMessage(
                            template: ChatMessage(
                                id: assistantMessage.id,
                                role: .assistant,
                                content: fallbackContent,
                                timestamp: assistantMessage.timestamp,
                                agentId: fallbackAgent.id,
                                agentName: fallbackAgent.name
                            ),
                            content: fallbackContent
                        )
                        if let traceID {
                            completeExecutionTrace(traceID: traceID, summary: "这次请求已处理完成")
                        }
                        isProcessing = false
                    }
                    return
                } catch {
                    terminalError = error
                    logger.logError(error, context: "远端鉴权失败后回退到本地 Agent")

                    if UserFacingErrorFormatter.shouldTemporarilySuspendAgent(after: error) {
                        agentStore.markTemporarilyUnavailable(fallbackAgent)
                        continue
                    }
                    break
                }
            }

            let userFacingMessage = await recoveryGuidanceMessage(
                after: terminalError,
                failingAgent: terminalAgent,
                text: text,
                images: images
            ) ?? UserFacingErrorFormatter.chatMessage(
                for: terminalError,
                agentName: terminalAgent.displayName,
                providerName: terminalAgent.provider.displayName
            )
            let terminalAgentID = terminalAgent.id
            let terminalAgentName = terminalAgent.name
            
            await MainActor.run {
                if let traceID {
                    failExecutionTrace(traceID: traceID, summary: "这次请求处理失败")
                }
                upsertAssistantMessage(
                    template: ChatMessage(
                        id: assistantMessage.id,
                        role: .assistant,
                        content: userFacingMessage,
                        timestamp: assistantMessage.timestamp,
                        agentId: terminalAgentID,
                        agentName: terminalAgentName
                    ),
                    content: userFacingMessage
                )
                isProcessing = false
            }
        }
    }

    private func fallbackAgentsForRecoverableFailure(
        after error: Error,
        failingAgent: Agent,
        images: [String]
    ) -> [Agent] {
        guard UserFacingErrorFormatter.shouldAttemptAutomaticAgentFallback(after: error) else {
            return []
        }

        let requiredCapability = recoveryCapability(for: images)
        let candidates = agentStore.usableAgents.filter { candidate in
            candidate.id != failingAgent.id && candidate.supports(requiredCapability)
        }

        var ordered: [Agent] = []
        var seenAgentIDs = Set<String>()

        func appendCandidate(_ candidate: Agent?) {
            guard let candidate,
                  seenAgentIDs.insert(candidate.id).inserted,
                  candidates.contains(where: { $0.id == candidate.id }) else {
                return
            }
            ordered.append(candidate)
        }

        if requiredCapability == .textChat {
            candidates
                .filter { $0.provider == .ollama }
                .forEach { appendCandidate($0) }
        }

        appendCandidate(orchestrator.currentAgent)
        appendCandidate(agentStore.defaultAgent)
        candidates.forEach { appendCandidate($0) }
        return ordered
    }

    private func recoveryCapability(for images: [String]) -> Capability {
        images.isEmpty ? .textChat : .vision
    }

    private func isKimiCLIAuthenticationFailure(_ error: Error, agent: Agent) -> Bool {
        agent.provider == .ollama && UserFacingErrorFormatter.isAuthenticationError(error)
    }

    private func maybeStartKimiCLILoginRecovery(after error: Error, for agent: Agent) async {
        guard isKimiCLIAuthenticationFailure(error, agent: agent) else {
            return
        }

        let alreadyWaiting = await MainActor.run { () -> Bool in
            isWaitingForKimiCLILogin && pendingKimiCLILoginAgentID == agent.id
        }
        guard !alreadyWaiting else { return }

        await MainActor.run {
            let launched = agentStore.launchKimiLogin()
            isWaitingForKimiCLILogin = true
            pendingKimiCLILoginAgentID = agent.id

            appendSystemMessage(
                launched
                ? """
                🌐 检测到 \(agent.displayName) 的 Kimi CLI 登录已失效。

                我已经在终端执行 `kimi login`。接下来通常会打开网页授权；你完成登录后回到应用，我会自动检测 Kimi CLI 是否已经恢复可用。
                """
                : """
                🌐 检测到 \(agent.displayName) 的 Kimi CLI 登录已失效。

                请在终端执行 `kimi login` 并完成网页授权。登录完成后回到应用，我会自动检测 Kimi CLI 是否已经恢复可用。
                """
            )
        }
    }

    private func recoveryGuidanceMessage(
        after error: Error,
        failingAgent: Agent,
        text: String,
        images: [String]
    ) async -> String? {
        guard UserFacingErrorFormatter.isAuthenticationError(error) ||
                UserFacingErrorFormatter.isMissingConfigurationError(error) else {
            return nil
        }

        if failingAgent.provider == .ollama {
            return """
            我刚刚尝试让 \(failingAgent.displayName) 调用 Kimi CLI，但检测到 CLI 登录已经失效，所以这次请求没有成功。

            我已经帮你拉起 `kimi login` 登录流程。通常完成网页授权后回到应用就行；如果没有自动弹出终端，也可以手动执行一次 `kimi login`。登录完成后，把刚才的问题再发一次，我会继续处理。
            """
        }

        let requiredCapability = recoveryCapability(for: images)
        guard preferredAgent(for: requiredCapability) == nil else {
            return nil
        }

        if requiredCapability == .vision {
            let gap = CapabilityGap(
                missingCapability: .vision,
                suggestedProviders: [.openai, .anthropic, .moonshot, .google],
                description: "需要一个支持图片分析的 Agent 才能继续处理这次请求",
                context: text
            )

            await MainActor.run {
                creationSkill.initiateCreation(for: gap, in: self)
            }

            return """
            ⚙️ 当前没有可用的视觉 Agent

            \(failingAgent.displayName) 已因鉴权失败被暂时停用。我已经打开配置引导；补一个支持图片分析的 Agent 后，就能继续处理这类请求。
            """
        }

        showInitialSetupGuidance(for: "继续对话")
        return """
        ⚙️ 当前没有可用的 LLM 或 CLI Agent

        \(failingAgent.displayName) 已因\(UserFacingErrorFormatter.isAuthenticationError(error) ? "认证失效" : "配置缺失")被暂时跳过。我已经打开配置向导；只要配置任意一个可用的 LLM 或 CLI Agent，就可以继续。
        """
    }

    private func gatewayReturnedError(_ content: String) -> NSError? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let lowercased = trimmed.lowercased()
        let hasProviderPayloadShape = lowercased.contains("\"error\"") ||
            lowercased.contains("'error'") ||
            lowercased.contains("invalid_api_key") ||
            lowercased.contains("invalid_authentication_error")
        let startsWithProviderPayload = lowercased.hasPrefix("{\"error\"") ||
            lowercased.hasPrefix("{'error'")

        guard lowercased.hasPrefix("error code:") ||
              (lowercased.hasPrefix("error:") && hasProviderPayloadShape) ||
              startsWithProviderPayload else {
            return nil
        }

        return NSError(
            domain: "CommandRunner.GatewayContent",
            code: gatewayReturnedErrorCode(from: trimmed) ?? 1,
            userInfo: [NSLocalizedDescriptionKey: trimmed]
        )
    }

    private func gatewayReturnedErrorCode(from content: String) -> Int? {
        guard let range = content.range(of: "Error code:", options: [.caseInsensitive]) else {
            return nil
        }

        let suffix = content[range.upperBound...]
        let digits = suffix
            .drop { !$0.isNumber }
            .prefix { $0.isNumber }

        return digits.isEmpty ? nil : Int(digits)
    }

    private func shouldAutoDelegateToSuggestedAgent(input: String, images: [String], suggestedAgent: Agent) -> Bool {
        suggestedAgent.supportsImageAnalysis && isImageAnalysisRequest(text: input, images: images)
    }

    private func isImageAnalysisRequest(text: String, images: [String]) -> Bool {
        if !images.isEmpty {
            return true
        }

        let normalized = text.lowercased()
        return ["图片", "图像", "截图", "看图", "分析图", "分析图片", "分析截图", "这张图"]
            .contains { normalized.contains($0) }
    }

    private func resolveImagesForRequest(text: String, explicitImages: [String]) -> [String] {
        if !explicitImages.isEmpty {
            return explicitImages
        }

        guard isImageAnalysisRequest(text: text, images: explicitImages) else {
            return []
        }

        if let recentImagePath = latestReusableImagePath() {
            return [recentImagePath]
        }

        return []
    }

    private func latestReusableImagePath() -> String? {
        let fileManager = FileManager.default

        if let lastScreenshotPath,
           fileManager.fileExists(atPath: lastScreenshotPath) {
            return lastScreenshotPath
        }

        for message in messages.reversed() {
            guard let imagePath = message.images?.last else { continue }
            if fileManager.fileExists(atPath: imagePath) {
                return imagePath
            }
        }

        return nil
    }

    private func preferredAgent(for capability: Capability) -> Agent? {
        let candidates = agentStore.agentsSupporting(capability)

        if let current = orchestrator.currentAgent,
           current.supports(capability),
           agentStore.canUse(current) {
            return current
        }

        if let defaultAgent = agentStore.defaultAgent,
           defaultAgent.supports(capability) {
            return defaultAgent
        }

        return candidates.first
    }

    private func gatewaySessionKey(forTaskSessionID sessionID: String) -> String {
        let sanitized = sessionID
            .lowercased()
            .replacingOccurrences(of: "task-", with: "")
            .replacingOccurrences(of: "_", with: "-")
        return "agent:desktop:subagent:\(sanitized)"
    }

    private func sendViaGateway(
        agent: Agent,
        sessionKey: String,
        sessionLabel: String?,
        text: String,
        images: [String],
        taskSessionID: String? = nil,
        assistantMessageID: UUID
    ) async throws -> String {
        do {
            let content = try await gatewayClient.sendMessage(
                agent: agent,
                sessionKey: sessionKey,
                sessionLabel: sessionLabel,
                text: text,
                images: images,
                onAssistantText: { [weak self] partialText in
                    guard let self else { return }
                    guard self.gatewayReturnedError(partialText) == nil else { return }
                    if let taskSessionID {
                        await MainActor.run {
                            self.updateTaskSessionMessage(
                                sessionID: taskSessionID,
                                messageID: assistantMessageID,
                                content: partialText
                            )
                            self.updateTaskSessionStatus(
                                sessionID: taskSessionID,
                                status: .running,
                                summary: "\(agent.displayName) 正在通过 OpenClaw 持续输出结果"
                            )
                        }
                    } else {
                        await MainActor.run {
                            self.updateAssistantMessage(id: assistantMessageID, content: partialText)
                        }
                    }
                }
            )

            if let surfacedError = gatewayReturnedError(content) {
                throw surfacedError
            }

            let resolvedContent = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "服务已返回，但没有拿到可显示的内容。"
                : content

            await MainActor.run {
                if let taskSessionID {
                    self.updateTaskSessionMessage(
                        sessionID: taskSessionID,
                        messageID: assistantMessageID,
                        content: resolvedContent
                    )
                } else {
                    self.updateAssistantMessage(id: assistantMessageID, content: resolvedContent)
                }
            }

            return resolvedContent
        } catch {
            if let fallbackContent = try await fallbackToDirectKimiCLIIfNeeded(
                after: error,
                agent: agent,
                sessionKey: sessionKey,
                text: text,
                images: images,
                taskSessionID: taskSessionID,
                assistantMessageID: assistantMessageID
            ) {
                return fallbackContent
            }
            throw error
        }
    }

    private func fallbackToDirectKimiCLIIfNeeded(
        after error: Error,
        agent: Agent,
        sessionKey: String,
        text: String,
        images: [String],
        taskSessionID: String?,
        assistantMessageID: UUID
    ) async throws -> String? {
        guard shouldFallbackToDirectKimiCLI(after: error, agent: agent) else {
            return nil
        }

        await MainActor.run {
            if let taskSessionID {
                self.updateTaskSessionStatus(
                    sessionID: taskSessionID,
                    status: .running,
                    summary: "OpenClaw 当前不可用，已直接切换到 Kimi CLI"
                )
            } else {
                if let traceID = self.currentExecutionTrace?.id {
                    self.updateExecutionTrace(
                        traceID: traceID,
                        state: .fallback,
                        agentName: agent.displayName,
                        transitionLabel: "直接 CLI",
                        summary: "OpenClaw 当前不可用，已直接切换到 Kimi CLI"
                    )
                }
                self.updateAssistantMessage(
                    id: assistantMessageID,
                    content: "⏳ OpenClaw 当前不可用，正在直接调用 Kimi CLI..."
                )
            }
        }

        let content = try await localKimiCLIService.sendMessage(
            text: text,
            attachments: images,
            sessionKey: sessionKey
        )
        let resolvedContent = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "本地 Kimi CLI 已执行，但没有返回可显示的内容。"
            : content

        await MainActor.run {
            if let taskSessionID {
                self.updateTaskSessionMessage(
                    sessionID: taskSessionID,
                    messageID: assistantMessageID,
                    content: resolvedContent
                )
            } else {
                self.updateAssistantMessage(id: assistantMessageID, content: resolvedContent)
            }
        }

        return resolvedContent
    }

    private func shouldFallbackToDirectKimiCLI(after error: Error, agent: Agent) -> Bool {
        guard agent.provider == .ollama else {
            return false
        }

        if UserFacingErrorFormatter.isAuthenticationError(error) {
            return false
        }

        let description = (error as NSError).localizedDescription.lowercased()
        let markers = [
            "openclaw",
            "gateway",
            "bundlednotfound",
            "未打包在 app bundle 中",
            "未包含在应用中",
            "安装 openclaw 失败",
            "无法验证 openclaw",
            "启动超时"
        ]
        return markers.contains { description.contains($0) }
    }

    private func delegateRequest(
        to agent: Agent,
        text: String,
        images: [String],
        intent: Intent,
        reason: String
    ) async {
        await MainActor.run {
            isProcessing = true
        }

        let mainAgent = await MainActor.run { orchestrator.currentAgent }
        let sessionID = await MainActor.run {
            createTaskSession(
                mainAgent: mainAgent,
                delegateAgent: agent,
                request: text,
                images: images,
                intent: intent,
                reason: reason
            )
        }

        let result = await runTaskSession(
            sessionID: sessionID,
            agent: agent,
            text: text,
            images: images
        )

        guard !result.failed else {
            await MainActor.run {
                isProcessing = false
            }
            return
        }

        await reflectTaskResultInMainConversation(
            taskSessionID: sessionID,
            originalUserRequest: text,
            mainAgent: mainAgent,
            delegateAgent: result.agent,
            taskResult: result.content
        )
    }

    func taskSession(for id: String?) -> AgentTaskSession? {
        guard let id else { return nil }
        return taskSessions.first { $0.id == id }
    }

    func toggleTaskSessionExpansion(_ id: String) {
        guard let index = taskSessions.firstIndex(where: { $0.id == id }) else { return }
        taskSessions[index].isExpanded.toggle()
        taskSessions[index].updatedAt = Date()
    }

    @MainActor
    func resumeTaskSession(_ id: String) {
        Task {
            await resumeTaskSessionIfPossible(id)
        }
    }

    @MainActor
    private func createTaskSession(
        mainAgent: Agent?,
        delegateAgent: Agent,
        request: String,
        images: [String],
        intent: Intent,
        reason: String
    ) -> String {
        var session = AgentTaskSession(
            title: "\(delegateAgent.name) 子会话",
            originalRequest: request,
            status: .queued,
            statusSummary: "等待 \(delegateAgent.displayName) 接手",
            mainAgentName: mainAgent?.name,
            delegateAgentID: delegateAgent.id,
            delegateAgentName: delegateAgent.name,
            intentName: intent.displayName,
            isExpanded: true,
            inputImages: images,
            canResume: false
        )
        session.gatewaySessionKey = gatewaySessionKey(forTaskSessionID: session.id)

        let taskCardMessage = ChatMessage(
            id: UUID(),
            role: .system,
            content: "🔀 \(reason)",
            timestamp: Date(),
            linkedTaskSessionID: session.id
        )
        session.linkedMainMessageID = taskCardMessage.id
        session.messages = [
            TaskSessionMessage(role: .system, content: reason),
            TaskSessionMessage(role: .user, content: request, agentName: mainAgent?.name)
        ]

        messages.append(taskCardMessage)
        taskSessions.append(session)
        return session.id
    }

    @MainActor
    private func appendTaskSessionMessage(
        sessionID: String,
        role: MessageRole,
        content: String,
        agentName: String? = nil
    ) -> UUID {
        let message = TaskSessionMessage(
            role: role,
            content: content,
            agentName: agentName
        )
        guard let index = taskSessions.firstIndex(where: { $0.id == sessionID }) else {
            return message.id
        }
        taskSessions[index].messages.append(message)
        taskSessions[index].updatedAt = Date()
        if role == .assistant {
            taskSessions[index].latestAssistantText = content
        }
        return message.id
    }

    @MainActor
    private func updateTaskSessionMessage(
        sessionID: String,
        messageID: UUID,
        content: String
    ) {
        guard let sessionIndex = taskSessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = taskSessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        guard taskSessions[sessionIndex].messages[messageIndex].content != content else {
            return
        }

        var updatedSessions = taskSessions
        updatedSessions[sessionIndex].messages[messageIndex].content = content
        updatedSessions[sessionIndex].updatedAt = Date()
        if updatedSessions[sessionIndex].messages[messageIndex].role == .assistant {
            updatedSessions[sessionIndex].latestAssistantText = content
        }
        taskSessions = updatedSessions
    }

    @MainActor
    private func updateTaskSessionStatus(
        sessionID: String,
        status: TaskSessionStatus,
        summary: String,
        isExpanded: Bool? = nil,
        resultSummary: String? = nil,
        errorMessage: String? = nil
    ) {
        guard let index = taskSessions.firstIndex(where: { $0.id == sessionID }) else { return }

        var didChange = false

        if taskSessions[index].status != status {
            taskSessions[index].status = status
            didChange = true
        }
        if taskSessions[index].statusSummary != summary {
            taskSessions[index].statusSummary = summary
            didChange = true
        }
        if let isExpanded, taskSessions[index].isExpanded != isExpanded {
            taskSessions[index].isExpanded = isExpanded
            didChange = true
        }
        if let resultSummary, taskSessions[index].resultSummary != resultSummary {
            taskSessions[index].resultSummary = resultSummary
            didChange = true
        } else if resultSummary == nil,
                  status != .completed,
                  taskSessions[index].resultSummary != nil {
            taskSessions[index].resultSummary = nil
            didChange = true
        }
        if let errorMessage, taskSessions[index].errorMessage != errorMessage {
            taskSessions[index].errorMessage = errorMessage
            didChange = true
        } else if errorMessage == nil,
                  status != .failed,
                  status != .partial,
                  status != .waitingUser,
                  taskSessions[index].errorMessage != nil {
            taskSessions[index].errorMessage = nil
            didChange = true
        }

        guard didChange else { return }
        taskSessions[index].updatedAt = Date()
    }

    @MainActor
    private func updateTaskSessionDelegateAgent(
        sessionID: String,
        agent: Agent
    ) {
        guard let index = taskSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        taskSessions[index].delegateAgentID = agent.id
        taskSessions[index].delegateAgentName = agent.name
        taskSessions[index].updatedAt = Date()
    }

    @MainActor
    private func updateTaskSessionRecoveryContext(
        sessionID: String,
        gatewaySessionKey: String? = nil,
        gatewayRunID: String? = nil,
        gatewayConversationSessionID: String? = nil,
        requestStartedAt: Date? = nil,
        latestAssistantText: String? = nil,
        canResume: Bool? = nil,
        lastReconciledAt: Date? = nil
    ) {
        guard let index = taskSessions.firstIndex(where: { $0.id == sessionID }) else { return }

        if let gatewaySessionKey {
            taskSessions[index].gatewaySessionKey = gatewaySessionKey
        }
        if let gatewayRunID {
            taskSessions[index].gatewayRunID = gatewayRunID
        }
        if let gatewayConversationSessionID {
            taskSessions[index].gatewayConversationSessionID = gatewayConversationSessionID
        }
        if let requestStartedAt {
            taskSessions[index].requestStartedAt = requestStartedAt
        }
        if let latestAssistantText {
            taskSessions[index].latestAssistantText = latestAssistantText
        }
        if let canResume {
            taskSessions[index].canResume = canResume
        }
        if let lastReconciledAt {
            taskSessions[index].lastReconciledAt = lastReconciledAt
        }
        taskSessions[index].updatedAt = Date()
    }

    @MainActor
    private func latestAssistantMessageID(forTaskSessionID sessionID: String) -> UUID? {
        guard let session = taskSessions.first(where: { $0.id == sessionID }) else { return nil }
        return session.messages.last(where: { $0.role == .assistant })?.id
    }

    private func summarizeTaskResult(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 220 else { return trimmed }
        let prefix = trimmed.prefix(220)
        return "\(prefix)…"
    }

    private func shouldTreatAsResumeCommand(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private func handleResumeRequestIfNeeded(_ text: String) async -> Bool {
        guard shouldTreatAsResumeCommand(text) else {
            return false
        }

        let sessionID = await MainActor.run {
            taskSessions
                .reversed()
                .first(where: { $0.canResume || $0.status == .partial || $0.status == .waitingUser })?
                .id
        }
        guard let sessionID else {
            return false
        }

        await resumeTaskSessionIfPossible(sessionID)
        return true
    }

    private func resumeTaskSessionIfPossible(_ sessionID: String) async {
        let recovered = await reconcileTaskSession(sessionID, manualTrigger: true, allowRetry: true)
        guard !recovered else { return }

        await MainActor.run {
            appendSystemMessage("我已经重新检查了刚才中断的任务，但暂时还没有拿到新的结果。你可以先完成授权或检查本地状态，再继续一次。")
        }
    }

    private func reconcileInterruptedTaskSessions(trigger: String) async {
        let candidateIDs = await MainActor.run { () -> [String] in
            taskSessions
                .filter {
                    ($0.canResume || $0.status == .running || $0.status == .partial || $0.status == .waitingUser) &&
                    $0.gatewaySessionKey != nil &&
                    $0.requestStartedAt != nil
                }
                .sorted { $0.updatedAt < $1.updatedAt }
                .map(\.id)
        }

        for sessionID in candidateIDs {
            _ = await reconcileTaskSession(sessionID, manualTrigger: false, allowRetry: false)
        }

        if !candidateIDs.isEmpty {
            LogInfo("已完成中断任务回查，trigger=\(trigger)，任务数=\(candidateIDs.count)")
        }
    }

    private func reconcileTaskSession(
        _ sessionID: String,
        manualTrigger: Bool,
        allowRetry: Bool
    ) async -> Bool {
        let snapshot = await MainActor.run { taskSession(for: sessionID) }
        guard let snapshot,
              let sessionKey = snapshot.gatewaySessionKey,
              let requestStartedAt = snapshot.requestStartedAt else {
            return false
        }

        if let recovery = await gatewayClient.recoverInterruptedTaskOutput(
            sessionKey: sessionKey,
            requestStartedAt: requestStartedAt,
            latestAssistantText: snapshot.latestAssistantText ?? ""
        ) {
            let summary = recovery.source == .history
                ? "已通过本地账本回查恢复结果"
                : "已恢复最近输出，但还没拿到完整收尾"

            await MainActor.run {
                if let assistantMessageID = latestAssistantMessageID(forTaskSessionID: sessionID) {
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: recovery.text
                    )
                }

                updateTaskSessionRecoveryContext(
                    sessionID: sessionID,
                    gatewayConversationSessionID: recovery.sessionID,
                    latestAssistantText: recovery.text,
                    canResume: recovery.source == .buffer,
                    lastReconciledAt: Date()
                )

                if recovery.source == .history {
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .completed,
                        summary: summary,
                        isExpanded: manualTrigger,
                        resultSummary: summarizeTaskResult(recovery.text),
                        errorMessage: nil
                    )
                } else {
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .partial,
                        summary: summary,
                        isExpanded: true,
                        errorMessage: snapshot.errorMessage
                    )
                }

                if manualTrigger {
                    let notice = recovery.source == .history
                        ? "我已经回查到刚才中断任务的结果：\n\n\(recovery.text)"
                        : "我已经恢复到刚才中断任务的最近输出，完整收尾还没回来。你可以继续观察任务卡片，或者再点一次继续处理。"
                    appendAssistantConversationMessage(notice)
                }
            }
            return true
        }

        guard manualTrigger,
              allowRetry,
              snapshot.canResume,
              let delegateAgentID = snapshot.delegateAgentID,
              let agent = agentStore.agent(withId: delegateAgentID),
              agentStore.canUse(agent) else {
            await MainActor.run {
                updateTaskSessionRecoveryContext(
                    sessionID: sessionID,
                    lastReconciledAt: Date()
                )
            }
            return false
        }

        let assistantMessageID = await MainActor.run { () -> UUID in
            if let existingID = latestAssistantMessageID(forTaskSessionID: sessionID) {
                return existingID
            }
            return appendTaskSessionMessage(
                sessionID: sessionID,
                role: .assistant,
                content: "⏳ \(agent.name) 正在继续处理...",
                agentName: agent.name
            )
        }

        await MainActor.run {
            isProcessing = true
            updateTaskSessionDelegateAgent(sessionID: sessionID, agent: agent)
            updateTaskSessionStatus(
                sessionID: sessionID,
                status: .running,
                summary: "正在继续处理上次中断的任务",
                isExpanded: true,
                errorMessage: nil
            )
            updateTaskSessionRecoveryContext(
                sessionID: sessionID,
                requestStartedAt: Date(),
                canResume: false
            )
        }

        do {
            let continuedContent = try await sendViaGateway(
                agent: agent,
                sessionKey: sessionKey,
                sessionLabel: snapshot.title,
                text: snapshot.originalRequest,
                images: snapshot.inputImages ?? [],
                taskSessionID: sessionID,
                assistantMessageID: assistantMessageID
            )

            await MainActor.run {
                updateTaskSessionStatus(
                    sessionID: sessionID,
                    status: .completed,
                    summary: "\(agent.displayName) 已继续完成刚才的任务",
                    isExpanded: false,
                    resultSummary: summarizeTaskResult(continuedContent),
                    errorMessage: nil
                )
                updateTaskSessionRecoveryContext(
                    sessionID: sessionID,
                    latestAssistantText: continuedContent,
                    canResume: false,
                    lastReconciledAt: Date()
                )
                appendAssistantConversationMessage("我已经继续完成了刚才中断的任务：\n\n\(continuedContent)")
                isProcessing = false
            }
            return true
        } catch {
            let message = UserFacingErrorFormatter.chatMessage(
                for: error,
                agentName: agent.displayName,
                providerName: agent.provider.displayName
            )
            await MainActor.run {
                updateTaskSessionStatus(
                    sessionID: sessionID,
                    status: UserFacingErrorFormatter.isStreamInterruptedError(error) ? .partial : .failed,
                    summary: UserFacingErrorFormatter.isStreamInterruptedError(error)
                        ? "继续处理中再次中断，已保留现场"
                        : "\(agent.displayName) 继续处理失败",
                    isExpanded: true,
                    errorMessage: message
                )
                updateTaskSessionRecoveryContext(
                    sessionID: sessionID,
                    canResume: UserFacingErrorFormatter.isStreamInterruptedError(error),
                    lastReconciledAt: Date()
                )
                if let latestAssistantText = snapshot.latestAssistantText,
                   UserFacingErrorFormatter.isStreamInterruptedError(error),
                   let assistantMessageID = latestAssistantMessageID(forTaskSessionID: sessionID) {
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: latestAssistantText
                    )
                }
                appendSystemMessage(message)
                isProcessing = false
            }
            return false
        }
    }

    private func runTaskSession(
        sessionID: String,
        agent: Agent,
        text: String,
        images: [String]
    ) async -> TaskExecutionResult {
        let sessionKey = gatewaySessionKey(forTaskSessionID: sessionID)
        let requestStartedAt = Date()
        await MainActor.run {
            updateTaskSessionStatus(
                sessionID: sessionID,
                status: .running,
                summary: "\(agent.displayName) 正在处理这个任务",
                isExpanded: true
            )
            updateTaskSessionDelegateAgent(sessionID: sessionID, agent: agent)
            updateTaskSessionRecoveryContext(
                sessionID: sessionID,
                gatewaySessionKey: sessionKey,
                requestStartedAt: requestStartedAt,
                canResume: false
            )
        }

        let assistantMessageID = await MainActor.run {
            appendTaskSessionMessage(
                sessionID: sessionID,
                role: .assistant,
                content: "⏳ \(agent.name) 正在通过 OpenClaw 处理...",
                agentName: agent.name
            )
        }

        do {
            let content = try await sendViaGateway(
                agent: agent,
                sessionKey: sessionKey,
                sessionLabel: taskSession(for: sessionID)?.title,
                text: text,
                images: images,
                taskSessionID: sessionID,
                assistantMessageID: assistantMessageID
            )

            await MainActor.run {
                updateTaskSessionStatus(
                    sessionID: sessionID,
                    status: .completed,
                    summary: "\(agent.displayName) 已完成，结果已回流到主会话",
                    isExpanded: false,
                    resultSummary: summarizeTaskResult(content),
                    errorMessage: nil
                )
                updateTaskSessionRecoveryContext(
                    sessionID: sessionID,
                    latestAssistantText: content,
                    canResume: false,
                    lastReconciledAt: Date()
                )
            }

            return TaskExecutionResult(agent: agent, content: content, failed: false)
        } catch {
            logger.logError(error, context: "执行 Agent 子会话")

            var terminalError = error
            var terminalAgent = agent

            await maybeStartKimiCLILoginRecovery(after: error, for: agent)

            if UserFacingErrorFormatter.shouldTemporarilySuspendAgent(after: error) {
                agentStore.markTemporarilyUnavailable(agent)
            }

            for fallbackAgent in fallbackAgentsForRecoverableFailure(
                after: error,
                failingAgent: agent,
                images: images
            ) {
                logger.logAgentSwitch(
                    from: agent,
                    to: fallbackAgent,
                    reason: "子会话 \(UserFacingErrorFormatter.recoveryFailureSummary(for: error))后自动切换"
                )
                orchestrator.switchToAgent(fallbackAgent)

                await MainActor.run {
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .running,
                        summary: "\(agent.displayName) \(UserFacingErrorFormatter.recoveryFailureSummary(for: error))，已切换到 \(fallbackAgent.displayName)",
                        isExpanded: true
                    )
                    updateTaskSessionDelegateAgent(sessionID: sessionID, agent: fallbackAgent)
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: "⏳ \(fallbackAgent.name) 正在继续处理..."
                    )
                }

                do {
                    terminalAgent = fallbackAgent
                    let fallbackContent = try await sendViaGateway(
                        agent: fallbackAgent,
                        sessionKey: sessionKey,
                        sessionLabel: taskSession(for: sessionID)?.title,
                        text: text,
                        images: images,
                        taskSessionID: sessionID,
                        assistantMessageID: assistantMessageID
                    )

                    await MainActor.run {
                        updateTaskSessionStatus(
                            sessionID: sessionID,
                            status: .completed,
                            summary: "\(fallbackAgent.displayName) 已完成，结果已回流到主会话",
                            isExpanded: false,
                            resultSummary: summarizeTaskResult(fallbackContent),
                            errorMessage: nil
                        )
                        updateTaskSessionRecoveryContext(
                            sessionID: sessionID,
                            latestAssistantText: fallbackContent,
                            canResume: false,
                            lastReconciledAt: Date()
                        )
                    }

                    return TaskExecutionResult(agent: fallbackAgent, content: fallbackContent, failed: false)
                } catch {
                    terminalError = error
                    logger.logError(error, context: "子会话回退 Agent 失败")

                    if UserFacingErrorFormatter.shouldTemporarilySuspendAgent(after: error) {
                        agentStore.markTemporarilyUnavailable(fallbackAgent)
                        continue
                    }
                    break
                }
            }

            let userFacingMessage = await recoveryGuidanceMessage(
                after: terminalError,
                failingAgent: terminalAgent,
                text: text,
                images: images
            ) ?? UserFacingErrorFormatter.chatMessage(
                for: terminalError,
                agentName: terminalAgent.displayName,
                providerName: terminalAgent.provider.displayName
            )
            let terminalAgentName = terminalAgent.displayName
            let isStreamInterrupted = UserFacingErrorFormatter.isStreamInterruptedError(terminalError)
            let isKimiLoginFailure = isKimiCLIAuthenticationFailure(terminalError, agent: terminalAgent)
            let initialStreamingPlaceholder = "⏳ \(terminalAgent.name) 正在通过 OpenClaw 处理..."
            let preservedAssistantText = await MainActor.run {
                taskSession(for: sessionID)?.latestAssistantText?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            await MainActor.run {
                if isStreamInterrupted {
                    let shouldPreservePartialOutput =
                        !(preservedAssistantText ?? "").isEmpty &&
                        preservedAssistantText != initialStreamingPlaceholder
                    if !shouldPreservePartialOutput {
                        updateTaskSessionMessage(
                            sessionID: sessionID,
                            messageID: assistantMessageID,
                            content: userFacingMessage
                        )
                    }
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .partial,
                        summary: "结果回传中断，已保留现场并等待回查",
                        isExpanded: true,
                        errorMessage: userFacingMessage
                    )
                    updateTaskSessionRecoveryContext(
                        sessionID: sessionID,
                        latestAssistantText: shouldPreservePartialOutput ? preservedAssistantText : userFacingMessage,
                        canResume: true
                    )
                } else if isKimiLoginFailure {
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: userFacingMessage
                    )
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .waitingUser,
                        summary: "等待完成 Kimi CLI 登录后继续",
                        isExpanded: true,
                        errorMessage: userFacingMessage
                    )
                    updateTaskSessionRecoveryContext(
                        sessionID: sessionID,
                        canResume: true
                    )
                } else {
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: userFacingMessage
                    )
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .failed,
                        summary: "\(terminalAgentName) 执行失败",
                        isExpanded: true,
                        errorMessage: userFacingMessage
                    )
                    updateTaskSessionRecoveryContext(
                        sessionID: sessionID,
                        canResume: false
                    )
                }
            }

            return TaskExecutionResult(agent: terminalAgent, content: userFacingMessage, failed: true)
        }
    }

    private func reflectTaskResultInMainConversation(
        taskSessionID: String,
        originalUserRequest: String,
        mainAgent: Agent?,
        delegateAgent: Agent,
        taskResult: String
    ) async {
        let traceAnchorMessageID = await MainActor.run {
            taskSession(for: taskSessionID)?.linkedMainMessageID
        }

        let reflectionAgent = await MainActor.run { () -> Agent? in
            if let mainAgent, agentStore.canUse(mainAgent) {
                return mainAgent
            }
            return preferredAgent(for: .textChat)
        }

        let traceID = await MainActor.run { () -> UUID? in
            if let traceAnchorMessageID {
                return startExecutionTrace(
                    anchorMessageID: traceAnchorMessageID,
                    agentName: reflectionAgent?.displayName ?? delegateAgent.displayName,
                    intentName: "结果整合",
                    summary: "主会话正在整合 \(delegateAgent.displayName) 的执行结果",
                    state: .synthesizing,
                    transitionLabel: "子会话回流"
                )
            }
            return nil
        }

        guard let reflectionAgent else {
            await MainActor.run {
                if let traceID {
                    completeExecutionTrace(traceID: traceID, summary: "已直接回流子会话结果")
                }
                let fallbackMessage = ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: summarizeTaskResult(taskResult),
                    timestamp: Date()
                )
                messages.append(fallbackMessage)
                isProcessing = false
            }
            return
        }

        let reflectionPrompt = """
        你现在是主会话 AI，需要根据一个子会话的执行结果，直接给用户最终答复。

        用户原始请求：
        \(originalUserRequest)

        子会话执行 Agent：
        \(delegateAgent.displayName)

        子会话结果：
        \(taskResult)

        请直接面向用户作答：
        1. 不要提内部委托、子会话、路由机制。
        2. 用自然语言整合子会话结果，给出结论或下一步建议。
        3. 如果信息不足，明确说明还缺什么。
        """

        _ = await sendToOpenClaw(agent: reflectionAgent, text: reflectionPrompt, images: [], traceID: traceID)
    }

    private func streamLocalBridgeForTask(
        sessionID: String,
        agent: Agent,
        text: String,
        images: [String],
        assistantMessageID: UUID
    ) async throws -> String {
        var requestBody: [String: Any] = [
            "model": "\(agent.provider.rawValue)/\(agent.model)",
            "messages": [
                ["role": "user", "content": text]
            ],
            "stream": true
        ]

        if !images.isEmpty && agent.supportsImageAnalysis {
            requestBody["images"] = images
        }

        let url = URL(string: "http://localhost:11434/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (stream, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "CommandRunner",
                code: 15,
                userInfo: [NSLocalizedDescriptionKey: "本地 OpenClaw Bridge 请求失败"]
            )
        }

        var fullContent = ""
        var lastUpdateTime = Date()
        var hasReceivedContent = false

        for try await line in stream.lines {
            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {

                fullContent += content
                hasReceivedContent = true
                let contentSnapshot = fullContent
                await MainActor.run {
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: contentSnapshot
                    )
                    updateTaskSessionStatus(
                        sessionID: sessionID,
                        status: .running,
                        summary: "\(agent.displayName) 正在持续输出结果"
                    )
                }
                lastUpdateTime = Date()
            }

            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let done = json["done"] as? Bool, done {
                break
            }

            if !hasReceivedContent && Date().timeIntervalSince(lastUpdateTime) > 3 {
                await MainActor.run {
                    updateTaskSessionMessage(
                        sessionID: sessionID,
                        messageID: assistantMessageID,
                        content: "⏳ \(agent.name) 正在连接..."
                    )
                }
                lastUpdateTime = Date()
            }
        }

        if fullContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallback = "服务已返回，但没有拿到可显示的内容。"
            await MainActor.run {
                updateTaskSessionMessage(
                    sessionID: sessionID,
                    messageID: assistantMessageID,
                    content: fallback
                )
            }
            return fallback
        }

        return fullContent
    }

    private func sendToConfiguredProviderForTask(
        sessionID: String,
        agent: Agent,
        text: String,
        images: [String],
        assistantMessageID: UUID
    ) async throws -> String {
        guard let profile = agentStore.runtimeProfile(for: agent) else {
            throw NSError(
                domain: "CommandRunner",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: "\(agent.displayName) 缺少认证配置，请重新配置该 Agent。"]
            )
        }

        let responseText: String
        switch agent.provider {
        case .openai, .moonshot:
            responseText = try await callOpenAICompatibleProvider(
                agent: agent,
                text: text,
                images: images,
                profile: profile
            )
        case .anthropic:
            responseText = try await callAnthropicProvider(
                agent: agent,
                text: text,
                images: images,
                profile: profile
            )
        case .google:
            responseText = try await callGoogleProvider(
                agent: agent,
                text: text,
                images: images,
                profile: profile
            )
        case .ollama:
            throw NSError(
                domain: "CommandRunner",
                code: 17,
                userInfo: [NSLocalizedDescriptionKey: "本地 Agent 应该走 OpenClaw Bridge，不应走远端 provider 分支。"]
            )
        }

        let finalText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = finalText.isEmpty ? "服务已返回，但没有拿到可显示的内容。" : finalText
        await MainActor.run {
            updateTaskSessionMessage(
                sessionID: sessionID,
                messageID: assistantMessageID,
                content: content
            )
        }
        return content
    }

    private func streamLocalBridge(
        agent: Agent,
        text: String,
        images: [String],
        assistantMessageID: UUID
    ) async throws -> String {
        var requestBody: [String: Any] = [
            "model": "\(agent.provider.rawValue)/\(agent.model)",
            "messages": [
                ["role": "user", "content": text]
            ],
            "stream": true
        ]

        if !images.isEmpty && agent.supportsImageAnalysis {
            requestBody["images"] = images
        }

        let url = URL(string: "http://localhost:11434/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (stream, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "CommandRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "本地 OpenClaw Bridge 请求失败"]
            )
        }

        var fullContent = ""
        var lastUpdateTime = Date()
        var hasReceivedContent = false

        for try await line in stream.lines {
            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {

                fullContent += content
                hasReceivedContent = true
                await updateAssistantMessage(id: assistantMessageID, content: fullContent)
                lastUpdateTime = Date()
            }

            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let done = json["done"] as? Bool, done {
                break
            }

            if !hasReceivedContent && Date().timeIntervalSince(lastUpdateTime) > 3 {
                await updateAssistantMessage(id: assistantMessageID, content: "⏳ \(agent.name) 正在连接...")
                lastUpdateTime = Date()
            }
        }

        if fullContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallback = "服务已返回，但没有拿到可显示的内容。"
            await updateAssistantMessage(id: assistantMessageID, content: fallback)
            return fallback
        }

        return fullContent
    }

    private func sendToConfiguredProvider(
        agent: Agent,
        text: String,
        images: [String],
        assistantMessageID: UUID
    ) async throws -> String {
        guard let profile = agentStore.runtimeProfile(for: agent) else {
            throw NSError(
                domain: "CommandRunner",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(agent.displayName) 缺少认证配置，请重新配置该 Agent。"]
            )
        }

        let responseText: String
        switch agent.provider {
        case .openai, .moonshot:
            responseText = try await callOpenAICompatibleProvider(
                agent: agent,
                text: text,
                images: images,
                profile: profile
            )
        case .anthropic:
            responseText = try await callAnthropicProvider(
                agent: agent,
                text: text,
                images: images,
                profile: profile
            )
        case .google:
            responseText = try await callGoogleProvider(
                agent: agent,
                text: text,
                images: images,
                profile: profile
            )
        case .ollama:
            throw NSError(
                domain: "CommandRunner",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "本地 Agent 应该走 OpenClaw Bridge，不应走远端 provider 分支。"]
            )
        }

        let finalText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = finalText.isEmpty ? "服务已返回，但没有拿到可显示的内容。" : finalText
        await updateAssistantMessage(id: assistantMessageID, content: content)
        return content
    }

    private func callOpenAICompatibleProvider(
        agent: Agent,
        text: String,
        images: [String],
        profile: AgentStore.RuntimeProfile
    ) async throws -> String {
        guard !profile.apiKey.isEmpty else {
            throw NSError(
                domain: "CommandRunner",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "\(agent.provider.displayName) API Key 为空，请重新配置。"]
            )
        }

        let endpoint = URL(string: "\(normalizedBaseURL(profile.baseURL))/chat/completions")!
        let messageContent = try buildOpenAICompatibleContent(text: text, images: images)
        var body: [String: Any] = [
            "model": profile.model,
            "messages": [
                ["role": "user", "content": messageContent]
            ],
            "stream": false
        ]
        body["temperature"] = agent.config.temperature
        body["max_tokens"] = agent.config.maxTokens

        let data = try await performJSONRequest(
            url: endpoint,
            headers: [
                "Authorization": "Bearer \(profile.apiKey)",
                "Content-Type": "application/json"
            ],
            body: body,
            providerName: agent.provider.displayName,
            agent: agent
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "CommandRunner",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "\(agent.provider.displayName) 返回了无法解析的响应。"]
            )
        }

        if let errorMessage = extractProviderErrorMessage(from: json) {
            throw NSError(domain: "CommandRunner", code: 6, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }

        let choices = json["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        return extractOpenAICompatibleText(from: message?["content"])
    }

    private func callAnthropicProvider(
        agent: Agent,
        text: String,
        images: [String],
        profile: AgentStore.RuntimeProfile
    ) async throws -> String {
        guard !profile.apiKey.isEmpty else {
            throw NSError(
                domain: "CommandRunner",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Anthropic API Key 为空，请重新配置。"]
            )
        }

        let endpoint = URL(string: "\(normalizedBaseURL(profile.baseURL))/messages")!
        let content = try buildAnthropicContent(text: text, images: images)
        var body: [String: Any] = [
            "model": profile.model,
            "max_tokens": max(agent.config.maxTokens, 1024),
            "messages": [
                ["role": "user", "content": content]
            ]
        ]
        body["temperature"] = agent.config.temperature

        let data = try await performJSONRequest(
            url: endpoint,
            headers: [
                "x-api-key": profile.apiKey,
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json"
            ],
            body: body,
            providerName: agent.provider.displayName,
            agent: agent
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "CommandRunner",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Anthropic 返回了无法解析的响应。"]
            )
        }

        if let errorMessage = extractProviderErrorMessage(from: json) {
            throw NSError(domain: "CommandRunner", code: 9, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }

        let contentBlocks = json["content"] as? [[String: Any]] ?? []
        let textBlocks = contentBlocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return textBlocks.joined(separator: "\n")
    }

    private func callGoogleProvider(
        agent: Agent,
        text: String,
        images: [String],
        profile: AgentStore.RuntimeProfile
    ) async throws -> String {
        guard !profile.apiKey.isEmpty else {
            throw NSError(
                domain: "CommandRunner",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Google API Key 为空，请重新配置。"]
            )
        }

        var components = URLComponents(string: "\(normalizedBaseURL(profile.baseURL))/models/\(profile.model):generateContent")
        components?.queryItems = [URLQueryItem(name: "key", value: profile.apiKey)]

        guard let endpoint = components?.url else {
            throw NSError(
                domain: "CommandRunner",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Google 请求地址无效。"]
            )
        }

        let parts = try buildGoogleParts(text: text, images: images)
        var body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": parts]
            ]
        ]
        body["generationConfig"] = [
            "temperature": agent.config.temperature,
            "maxOutputTokens": agent.config.maxTokens
        ]

        let data = try await performJSONRequest(
            url: endpoint,
            headers: ["Content-Type": "application/json"],
            body: body,
            providerName: agent.provider.displayName,
            agent: agent
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "CommandRunner",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Google 返回了无法解析的响应。"]
            )
        }

        if let errorMessage = extractProviderErrorMessage(from: json) {
            throw NSError(domain: "CommandRunner", code: 13, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }

        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let content = candidates.first?["content"] as? [String: Any]
        let partsResponse = content?["parts"] as? [[String: Any]] ?? []
        let textParts = partsResponse.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return textParts.joined(separator: "\n")
    }

    private func performJSONRequest(
        url: URL,
        headers: [String: String],
        body: [String: Any],
        providerName: String,
        agent: Agent? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "CommandRunner",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "\(providerName) 没有返回有效的 HTTP 响应。"]
            )
        }

        // 记录详细的请求/响应日志用于诊断
        let hasAuthHeader = headers.keys.contains { $0.lowercased() == "authorization" || $0.lowercased() == "x-api-key" }
        let apiKeyPreview = hasAuthHeader ? "已提供" : "未提供"
        
        LogDebug("API 请求: \(providerName) \(url.path), 认证: \(apiKeyPreview), 状态码: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            let rawMessage = extractProviderErrorMessage(from: data)
            let responsePreview = String(data: data, encoding: .utf8)?.prefix(500) ?? "无法解析"
            
            LogError("API 错误: \(providerName) HTTP \(httpResponse.statusCode), 响应: \(responsePreview)")
            
            // 根据状态码提供用户友好的错误信息
            let userMessage: String
            switch httpResponse.statusCode {
            case 401:
                let detail = rawMessage ?? "API Key 无效或已过期"
                userMessage = "❌ \(providerName) 认证失败\n\n原因: \(detail)\n\n解决方法:\n1. 检查 API Key 是否正确复制（没有多余的空格）\n2. 确认 API Key 没有过期\n3. 在 Agent 列表中重新配置"
            case 403:
                userMessage = "❌ \(providerName) 权限不足\n\n您的 API Key 可能没有访问该模型的权限。"
            case 429:
                userMessage = "⚠️ \(providerName) 请求过于频繁\n\n请稍后再试，或检查您的用量限制。"
            case 500...599:
                userMessage = "⚠️ \(providerName) 服务器错误 (HTTP \(httpResponse.statusCode))\n\n这是提供商的服务器问题，请稍后再试。"
            default:
                userMessage = rawMessage ?? "\(providerName) 请求失败，HTTP \(httpResponse.statusCode)。"
            }
            
            throw NSError(
                domain: "CommandRunner",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: userMessage]
            )
        }

        if let agent {
            agentStore.restoreAvailability(for: agent)
        }

        return data
    }

    private func extractProviderErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw?.isEmpty == false ? raw : nil
        }
        return extractProviderErrorMessage(from: json)
    }

    private func extractProviderErrorMessage(from json: [String: Any]) -> String? {
        if let error = json["error"] as? String, !error.isEmpty {
            return error
        }

        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let details = error["details"] as? String, !details.isEmpty {
                return details
            }
        }

        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }

        return nil
    }

    private func buildOpenAICompatibleContent(text: String, images: [String]) throws -> Any {
        let prompt = normalizedPrompt(text, hasImages: !images.isEmpty)
        guard !images.isEmpty else { return prompt }

        var content: [[String: Any]] = [
            ["type": "text", "text": prompt]
        ]

        for path in images {
            let attachment = try loadImageAttachment(at: path)
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:\(attachment.mimeType);base64,\(attachment.base64)"]
            ])
        }

        return content
    }

    private func buildAnthropicContent(text: String, images: [String]) throws -> [[String: Any]] {
        var content: [[String: Any]] = [
            ["type": "text", "text": normalizedPrompt(text, hasImages: !images.isEmpty)]
        ]

        for path in images {
            let attachment = try loadImageAttachment(at: path)
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": attachment.mimeType,
                    "data": attachment.base64
                ]
            ])
        }

        return content
    }

    private func buildGoogleParts(text: String, images: [String]) throws -> [[String: Any]] {
        var parts: [[String: Any]] = [
            ["text": normalizedPrompt(text, hasImages: !images.isEmpty)]
        ]

        for path in images {
            let attachment = try loadImageAttachment(at: path)
            parts.append([
                "inline_data": [
                    "mime_type": attachment.mimeType,
                    "data": attachment.base64
                ]
            ])
        }

        return parts
    }

    private func extractOpenAICompatibleText(from payload: Any?) -> String {
        if let text = payload as? String {
            return text
        }

        if let blocks = payload as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let type = block["type"] as? String, type == "output_text",
                   let text = block["text"] as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil
            }
            return texts.joined(separator: "\n")
        }

        return ""
    }

    private func loadImageAttachment(at path: String) throws -> (mimeType: String, base64: String) {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return (mimeType(for: url.pathExtension), data.base64EncodedString())
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        case "heic":
            return "image/heic"
        case "bmp":
            return "image/bmp"
        case "tiff", "tif":
            return "image/tiff"
        default:
            return "application/octet-stream"
        }
    }

    private func normalizedPrompt(_ text: String, hasImages: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return hasImages ? "请分析这张图片。" : "你好"
    }

    private func normalizedBaseURL(_ baseURL: String) -> String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    @MainActor
    private func updateAssistantMessage(id: UUID, content: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            if messages[index].content == content {
                scheduleTraceSettlementIfNeeded(forAssistantMessageID: id, content: content)
                return
            }
            var updatedMessages = messages
            updatedMessages[index].content = content
            messages = updatedMessages
            scheduleTraceSettlementIfNeeded(forAssistantMessageID: id, content: content)
        }
    }

    @MainActor
    private func updateAssistantIdentity(id: UUID, agentId: String?, agentName: String?) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        guard messages[index].agentId != agentId || messages[index].agentName != agentName else { return }
        var updatedMessages = messages
        updatedMessages[index].agentId = agentId
        updatedMessages[index].agentName = agentName
        messages = updatedMessages
    }

    @MainActor
    private func upsertAssistantMessage(template: ChatMessage, content: String) {
        if messages.contains(where: { $0.id == template.id }) {
            updateAssistantMessage(id: template.id, content: content)
            return
        }

        var recoveredMessage = template
        recoveredMessage.content = content
        messages.append(recoveredMessage)
        scheduleTraceSettlementIfNeeded(forAssistantMessageID: template.id, content: content)
        LogInfo("恢复缺失的 assistant 消息并补写最终内容: \(template.id.uuidString)")
    }

    @MainActor
    private func startExecutionTrace(
        anchorMessageID: UUID,
        agentName: String,
        intentName: String,
        summary: String,
        state: ExecutionTraceState = .routing,
        transitionLabel: String? = nil
    ) -> UUID {
        let trace = ExecutionTrace(
            anchorMessageID: anchorMessageID,
            agentName: agentName,
            intentName: intentName,
            transitionLabel: transitionLabel,
            summary: summary,
            state: state
        )
        traceDismissTasks[trace.id]?.cancel()
        traceDismissTasks[trace.id] = nil
        messageExecutionTraces[trace.id] = trace
        refreshCurrentExecutionTrace()
        return trace.id
    }

    @MainActor
    private func attachExecutionTrace(traceID: UUID, to assistantMessageID: UUID) {
        guard var trace = messageExecutionTraces[traceID] else { return }
        trace.assistantMessageID = assistantMessageID
        messageExecutionTraces[traceID] = trace
        refreshCurrentExecutionTrace()
    }

    @MainActor
    private func updateExecutionTrace(
        traceID: UUID,
        state: ExecutionTraceState,
        agentName: String? = nil,
        intentName: String? = nil,
        transitionLabel: String? = nil,
        summary: String? = nil
    ) {
        guard var trace = messageExecutionTraces[traceID] else { return }
        traceDismissTasks[traceID]?.cancel()
        trace.state = state
        if let agentName {
            trace.agentName = agentName
        }
        if let intentName {
            trace.intentName = intentName
        }
        trace.transitionLabel = transitionLabel
        if let summary {
            trace.summary = summary
        }
        if !state.isActive {
            trace.finishedAt = Date()
        }
        messageExecutionTraces[traceID] = trace
        refreshCurrentExecutionTrace()
    }

    @MainActor
    private func completeExecutionTrace(traceID: UUID, summary: String) {
        traceSettleTasks[traceID]?.cancel()
        traceSettleTasks[traceID] = nil
        updateExecutionTrace(traceID: traceID, state: .completed, summary: summary)
        scheduleExecutionTraceDismiss(traceID: traceID, after: 1.6)
    }

    @MainActor
    private func failExecutionTrace(traceID: UUID, summary: String) {
        traceSettleTasks[traceID]?.cancel()
        traceSettleTasks[traceID] = nil
        updateExecutionTrace(traceID: traceID, state: .failed, summary: summary)
        scheduleExecutionTraceDismiss(traceID: traceID, after: 4)
    }

    @MainActor
    private func clearFinishedExecutionTraces() {
        let finishedIDs = messageExecutionTraces.values
            .filter { !$0.state.isActive }
            .map(\.id)

        for traceID in finishedIDs {
            traceDismissTasks[traceID]?.cancel()
            traceDismissTasks[traceID] = nil
            traceSettleTasks[traceID]?.cancel()
            traceSettleTasks[traceID] = nil
            messageExecutionTraces.removeValue(forKey: traceID)
        }

        refreshCurrentExecutionTrace()
    }

    @MainActor
    private func scheduleExecutionTraceDismiss(traceID: UUID, after delay: TimeInterval) {
        traceDismissTasks[traceID]?.cancel()
        traceDismissTasks[traceID] = Task { @MainActor [weak self] in
            let duration = UInt64(max(delay, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: duration)
            guard let self else { return }
            self.messageExecutionTraces.removeValue(forKey: traceID)
            self.traceDismissTasks[traceID] = nil
            self.traceSettleTasks[traceID]?.cancel()
            self.traceSettleTasks[traceID] = nil
            self.refreshCurrentExecutionTrace()
        }
    }

    @MainActor
    private func scheduleTraceSettlementIfNeeded(forAssistantMessageID messageID: UUID, content: String) {
        guard let traceID = traceID(forAssistantMessageID: messageID),
              let trace = messageExecutionTraces[traceID],
              trace.state.isActive else {
            return
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProcessingPlaceholderContent(trimmed) else {
            traceSettleTasks[traceID]?.cancel()
            traceSettleTasks[traceID] = nil
            return
        }

        traceSettleTasks[traceID]?.cancel()
        traceSettleTasks[traceID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self,
                  let currentTrace = self.messageExecutionTraces[traceID],
                  currentTrace.state.isActive else {
                return
            }
            self.completeExecutionTrace(traceID: traceID, summary: "结果已经返回到聊天窗口")
            LogInfo("Trace quiet-settled after assistant content stabilized: \(traceID.uuidString)")
        }
    }

    @MainActor
    private func traceID(forAssistantMessageID messageID: UUID) -> UUID? {
        messageExecutionTraces.values.first { $0.assistantMessageID == messageID }?.id
    }

    private func isProcessingPlaceholderContent(_ content: String) -> Bool {
        guard content.hasPrefix("⏳ ") else { return false }
        return content.contains("正在思考") ||
            content.contains("正在继续处理") ||
            content.contains("正在连接") ||
            content.contains("正在直接调用")
    }

    @MainActor
    func executionTrace(forMessageID messageID: UUID) -> ExecutionTrace? {
        messageExecutionTraces.values
            .filter { trace in
                if let assistantMessageID = trace.assistantMessageID {
                    return assistantMessageID == messageID
                }
                return trace.anchorMessageID == messageID
            }
            .sorted { lhs, rhs in
                if lhs.state.isActive != rhs.state.isActive {
                    return lhs.state.isActive && !rhs.state.isActive
                }
                return lhs.startedAt > rhs.startedAt
            }
            .first
    }

    @MainActor
    private func refreshCurrentExecutionTrace() {
        currentExecutionTrace = messageExecutionTraces.values
            .filter(\.state.isActive)
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }
    
    // MARK: - 辅助方法
    
    @MainActor
    private func ensureScreenRecordingAccessForScreenshot() -> Bool {
        if #available(macOS 10.15, *) {
            guard !isRestartingForScreenRecordingPermission else { return false }

            if CGPreflightScreenCaptureAccess() {
                isWaitingForScreenRecordingAuthorization = false
                return true
            }

            isWaitingForScreenRecordingAuthorization = true
            appendSystemMessage(
                """
                为了截图，我需要先获得 macOS 的“屏幕与系统音频录制”权限。

                我会打开系统设置。你授权后回到当前这个开发版应用，我会重新打开现在这份源码版实例，不会再跳到旧版 App。
                """
            )

            let granted = CGRequestScreenCaptureAccess()
            if granted {
                appendSystemMessage("已经检测到截图权限可用，正在重新打开当前源码版应用以让权限生效。")
                restartCurrentAppForScreenRecordingPermission()
            } else if let settingsURL = screenRecordingSettingsURL {
                NSWorkspace.shared.open(settingsURL)
            }

            return false
        }

        return true
    }

    @MainActor
    private func resumePendingScreenRecordingFlowIfNeeded() {
        guard isWaitingForScreenRecordingAuthorization, !isRestartingForScreenRecordingPermission else {
            return
        }

        if #available(macOS 10.15, *), CGPreflightScreenCaptureAccess() {
            isWaitingForScreenRecordingAuthorization = false
            appendSystemMessage("已检测到你刚刚授予了截图权限，正在重新打开当前源码版应用。")
            restartCurrentAppForScreenRecordingPermission()
        }
    }

    @MainActor
    private func resumePendingKimiCLILoginFlowIfNeeded() async {
        guard isWaitingForKimiCLILogin,
              let agentID = pendingKimiCLILoginAgentID,
              let agent = agentStore.agent(withId: agentID) else {
            return
        }

        let status = await agentStore.validateLocalCodingRuntimeStatus()
        guard status.isValid else {
            return
        }

        isWaitingForKimiCLILogin = false
        pendingKimiCLILoginAgentID = nil

        appendSystemMessage(
            "✅ 已检测到 \(agent.displayName) 的 Kimi CLI 登录恢复成功。你现在可以继续提问了。"
        )
        await reconcileInterruptedTaskSessions(trigger: "kimi-login-restored")
    }

    @MainActor
    private func restartCurrentAppForScreenRecordingPermission() {
        guard !isRestartingForScreenRecordingPermission else { return }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        isRestartingForScreenRecordingPermission = true

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    CommandRunner.shared.appendSystemMessage(
                        "我已经拿到截图权限，但重新打开当前源码版应用时失败了：\(error.localizedDescription)"
                    )
                    CommandRunner.shared.fallbackRelaunchCurrentApp(at: bundleURL)
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    @MainActor
    private func fallbackRelaunchCurrentApp(at bundleURL: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]

        do {
            try task.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        } catch {
            isRestartingForScreenRecordingPermission = false
            appendSystemMessage(
                "截图权限已经准备好了，但我没能重新拉起当前源码版应用。你可以手动重新打开这份开发版 App。"
            )
        }
    }

    @MainActor
    private func completeScreenshotFlow(with screenshotPath: String) {
        lastScreenshotPath = screenshotPath

        appendSystemMessage(
            "📸 截图已保存: \(screenshotPath)",
            images: [screenshotPath]
        )

        guard !agentStore.needsInitialSetup else {
            presentInitialSetupPrompt(for: "分析截图")
            return
        }

        if let currentAgent = orchestrator.currentAgent {
            if currentAgent.supportsImageAnalysis {
                Task {
                    await processInput("分析这张截图", images: [screenshotPath])
                }
            } else {
                handleVisionGap(screenshotPath: screenshotPath)
            }
        } else {
            handleVisionGap(screenshotPath: screenshotPath)
        }
    }

    @MainActor
    private func appendSystemMessage(_ content: String, images: [String] = []) {
        let systemMessage = ChatMessage(
            id: UUID(),
            role: .system,
            content: content,
            timestamp: Date(),
            images: images
        )
        messages.append(systemMessage)
    }

    @MainActor
    private func appendAssistantConversationMessage(_ content: String) {
        let assistantMessage = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date()
        )
        messages.append(assistantMessage)
    }

    private func restorePersistedState() {
        isRestoringPersistedState = true
        defer { isRestoringPersistedState = false }

        messages = StorageManager.shared.getRecentMessages(limit: 50)
        taskSessions = normalizeRestoredTaskSessions(executionJournal.loadTaskSessions())
        executionJournal.saveTaskSessions(taskSessions)
    }

    private func normalizeRestoredTaskSessions(_ sessions: [AgentTaskSession]) -> [AgentTaskSession] {
        let restoredAt = Date()
        return sessions.map { session in
            var normalized = session
            switch normalized.status {
            case .queued, .running:
                normalized.status = .partial
                normalized.statusSummary = "应用重新打开，正在回查上次中断的结果"
                normalized.canResume = true
                normalized.isExpanded = true
                normalized.updatedAt = restoredAt
            case .partial, .waitingUser:
                normalized.canResume = true
            case .completed, .failed:
                break
            }
            return normalized
        }
    }

    /// 保存截图到桌面
    private func saveScreenshotToDesktop() -> String? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let filename = "screenshot-\(dateFormatter.string(from: Date())).png"
        
        let desktopPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(filename)
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-x", desktopPath.path]

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        guard task.terminationStatus == 0,
              FileManager.default.fileExists(atPath: desktopPath.path) else {
            return nil
        }

        return desktopPath.path
    }
    
    /// 旧方法：通过通知显示能力缺口（保留弹窗选项）
    private func handleCapabilityGap(_ gap: CapabilityGap) {
        // 仍然发送通知，让 UI 层决定是否显示弹窗
        NotificationCenter.default.post(
            name: NSNotification.Name("ShowCapabilityWizard"),
            object: gap
        )
    }
    
    /// 清除对话历史
    func clearMessages() {
        messages.removeAll()
    }

    func loadHistory() {
        restorePersistedState()
    }

    func clearHistory() {
        messages.removeAll()
        taskSessions.removeAll()
        StorageManager.shared.clearHistory()
        executionJournal.clear()
    }

    func screenshotAndAsk() {
        handleScreenshot()
    }

    func clipboardAndAsk() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.isEmpty else { return }
        Task {
            await processInput(text)
        }
    }

    func showInitialSetupGuidance(for action: String? = nil) {
        if Thread.isMainThread {
            presentInitialSetupPrompt(for: action)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.presentInitialSetupPrompt(for: action)
            }
        }
    }

    private func presentInitialSetupPrompt(for action: String? = nil) {
        let actionText = action ?? "使用 OpenClaw"
        let content = """
        ⚙️ 当前还没有可用的 LLM 或 CLI Agent

        在首次使用前，请先完成一次模型配置，然后再继续\(actionText)。
        你可以先配置本地 Kimi CLI，或者添加其他需要 API Key 的 Agent。
        """

        let isDuplicatePrompt = messages.last?.metadata?[initialSetupPromptKey] == "true"
        if !isDuplicatePrompt {
            let promptMessage = ChatMessage(
                id: UUID(),
                role: .system,
                content: content,
                timestamp: Date(),
                metadata: [initialSetupPromptKey: "true"]
            )
            messages.append(promptMessage)
        }

        NotificationCenter.default.post(
            name: NSNotification.Name("ShowInitialSetupWizard"),
            object: nil
        )
    }
}

// 注意: ChatMessage 定义在 ChatModels.swift 中共享使用
