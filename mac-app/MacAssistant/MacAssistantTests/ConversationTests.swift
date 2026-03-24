//
//  ConversationTests.swift
//  MacAssistantTests
//
//  对话系统自测
//

import XCTest
@testable import MacAssistant

/// 自测类 - 验证修复是否生效
class ConversationTests: XCTestCase {
    private func makeEnvelope(
        text: String,
        lastMessage: ChatMessage? = nil,
        creationFlowActive: Bool = false,
        activeWorkflowDesignContext: WorkflowDesignContinuationContext? = nil,
        activeBrowserSession: BrowserSession? = nil
    ) -> RequestEnvelope {
        RequestEnvelope(
            originalText: text,
            images: [],
            sessionTopology: ConversationControlStore.shared.currentTopology(),
            currentAgent: nil,
            needsInitialSetup: false,
            lastMessage: lastMessage,
            creationFlowActive: creationFlowActive,
            resumableTaskSessionID: nil,
            activeWorkflowDesignContext: activeWorkflowDesignContext,
            activeBrowserSession: activeBrowserSession,
            activeBrowserSnapshot: activeBrowserSession?.latestSnapshot,
            activeBrowserObservation: activeBrowserSession?.latestObservation ??
                activeBrowserSession?.latestSnapshot.map(BrowserObservation.init(snapshot:)),
            activeBrowserDelta: activeBrowserSession?.latestDelta,
            activeBrowserPlannerState: activeBrowserSession?.plannerState
        )
    }
    
    // MARK: - 测试 1: 意图检测敏感度
    
    func testIntentDetectionSensitivity() {
        let intelligence = ConversationIntelligence.shared
        
        // 应该检测到的明确命令
        let shouldDetect = [
            ("截图", AISkill.screenshot),
            ("截个屏", AISkill.screenshot),
            ("screenshot", AISkill.screenshot),
            ("review 代码", AISkill.codeReview),
            ("翻译成英文", AISkill.translateText),
            ("总结一下", AISkill.summarizeText),
            ("搜索一下", AISkill.webSearch),
        ]
        
        for (input, expectedSkill) in shouldDetect {
            let parsed = intelligence.analyzeInput(input)
            XCTAssertEqual(parsed.detectedSkill?.rawValue, expectedSkill.rawValue, 
                "'\(input)' 应该检测到 \(expectedSkill.name)")
        }
        
        // 不应该检测到的模糊表述
        let shouldNotDetect = [
            "截个图看看",           // 模糊，只是说说
            "不用截图",             // 否定
            "截图算了",             // 否定
            "看看这个",             // 太模糊
            "翻译一下",             // 缺少目标语言
            "帮我看看",             // 太模糊
        ]
        
        for input in shouldNotDetect {
            let parsed = intelligence.analyzeInput(input)
            XCTAssertNil(parsed.detectedSkill, 
                "'\(input)' 不应该触发任何 Skill，但检测到了 \(parsed.detectedSkill?.name ?? "")")
        }
    }
    
    // MARK: - 测试 2: 用户偏好系统
    
    func testUserPreferences() {
        let prefs = UserPreferenceStore.shared
        
        // 重置
        prefs.resetAllPreferences()
        
        // 测试记录拒绝
        prefs.recordSkillRejection(.screenshot)
        XCTAssertTrue(prefs.shouldSkipDetection(.screenshot), 
            "被拒绝的 Skill 应该跳过检测")
        
        // 测试记录接受
        prefs.recordSkillAcceptance(.translateText)
        prefs.recordSkillAcceptance(.translateText)
        prefs.recordSkillAcceptance(.translateText)
        XCTAssertTrue(prefs.shouldAutoConfirm(.translateText),
            "使用3次的 Skill 应该自动确认")
        
        // 清理
        prefs.resetAllPreferences()
    }
    
    // MARK: - 测试 3: Agent 能力检查
    
    func testAgentCapabilityCheck() {
        // 创建一个不支持 Vision 的 Agent
        let agent = Agent(
            name: "Test Agent",
            emoji: "🤖",
            description: "测试 Agent",
            provider: .ollama,
            model: "test-model",
            capabilities: [.textChat],
            isDefault: false
        )
        
        // 检查能力
        XCTAssertFalse(agent.supports(.vision), 
            "Test Agent 不应该支持 vision")
        XCTAssertFalse(agent.supportsImageAnalysis,
            "Test Agent 不应该支持图片分析")
        
        // 创建支持 Vision 的 Agent
        let visionAgent = Agent(
            name: "Vision Agent",
            emoji: "👁️",
            description: "视觉 Agent",
            provider: .openai,
            model: "gpt-4o",
            capabilities: [.textChat, .vision, .imageAnalysis],
            isDefault: false
        )
        
        XCTAssertTrue(visionAgent.supports(.vision),
            "Vision Agent 应该支持 vision")
        XCTAssertTrue(visionAgent.supportsImageAnalysis,
            "Vision Agent 应该支持图片分析")
    }
    
    // MARK: - 测试 4: 输入解析
    
    func testInputParsing() {
        let intelligence = ConversationIntelligence.shared
        
        // 测试 @提及
        let atInput = "@GPT-4V 分析图片"
        let atParsed = intelligence.analyzeInput(atInput)
        XCTAssertTrue(atParsed.hasMentions, "应该检测到 @提及")
        
        // 测试 /命令
        let slashInput = "/screenshot"
        let slashParsed = intelligence.analyzeInput(slashInput)
        XCTAssertNotNil(slashParsed.skillCommand, "应该检测到 /命令")
        
        // 测试纯净文本
        let cleanInput = "这是一段普通对话"
        let cleanParsed = intelligence.analyzeInput(cleanInput)
        XCTAssertEqual(cleanParsed.cleanText, cleanInput, "普通文本应保持不变")
        XCTAssertFalse(cleanParsed.hasMentions, "普通文本不应有提及")
    }

    func testPendingFlowCancelHeuristic() {
        XCTAssertTrue(RequestPlanningHeuristics.shouldCancelPendingFlow("取消吧"))
        XCTAssertTrue(RequestPlanningHeuristics.shouldCancelPendingFlow("退出当前流程"))
        XCTAssertTrue(RequestPlanningHeuristics.shouldCancelPendingFlow("算了"))
        XCTAssertFalse(RequestPlanningHeuristics.shouldCancelPendingFlow("为什么没有取消按钮"))
    }

    func testWorkflowApprovalDecisionHeuristic() {
        XCTAssertEqual(RequestPlanningHeuristics.workflowApprovalDecision(from: "确认"), true)
        XCTAssertEqual(RequestPlanningHeuristics.workflowApprovalDecision(from: "通过"), true)
        XCTAssertEqual(RequestPlanningHeuristics.workflowApprovalDecision(from: "拒绝"), false)
        XCTAssertEqual(RequestPlanningHeuristics.workflowApprovalDecision(from: "先别执行"), false)
    }

    func testPriorityLocalPlanCancelsCreationFlow() async {
        let envelope = makeEnvelope(
            text: "取消吧",
            creationFlowActive: true
        )

        let plan = await RuleBasedRequestPlannerProvider.shared.priorityLocalPlan(envelope)

        guard let plan else {
            return XCTFail("应返回取消挂起流程的优先计划")
        }

        guard case .cancelPendingFlow = plan.primaryAction else {
            return XCTFail("创建流程中的取消命令应优先命中 cancelPendingFlow，实际为 \(plan.summary)")
        }

        XCTAssertTrue(plan.shouldAppendUserMessage, "取消命令应作为主会话用户消息保留")
    }

    func testPriorityLocalPlanCancelsPendingWorkflowGuidance() async {
        let lastMessage = ChatMessage(
            role: .assistant,
            content: "是否继续这次业务规划引导？",
            metadata: [
                "pending_workflow_design": "true",
                "workflow_original_input": "帮我设计一个每周汇总服务"
            ]
        )
        let envelope = makeEnvelope(
            text: "退出",
            lastMessage: lastMessage
        )

        let plan = await RuleBasedRequestPlannerProvider.shared.priorityLocalPlan(envelope)

        guard let plan else {
            return XCTFail("应返回取消挂起流程的优先计划")
        }

        guard case .cancelPendingFlow = plan.primaryAction else {
            return XCTFail("挂起引导中的退出命令应优先命中 cancelPendingFlow，实际为 \(plan.summary)")
        }
    }

    func testBrowserStartURLHeuristic() {
        XCTAssertEqual(
            RequestPlanningHeuristics.browserStartURL(from: "打开 github"),
            "https://github.com"
        )
        XCTAssertEqual(
            RequestPlanningHeuristics.browserStartURL(from: "https://example.com/login"),
            "https://example.com/login"
        )
        XCTAssertNil(
            RequestPlanningHeuristics.browserStartURL(from: "你现在接受whatsapp上的消息，来扮演一个专业的程序解答别人的问题")
        )
    }

    func testPriorityLocalPlanStartsBrowserSession() async {
        let envelope = makeEnvelope(text: "打开 https://example.com/login")

        let plan = await RuleBasedRequestPlannerProvider.shared.priorityLocalPlan(envelope)

        guard let plan else {
            return XCTFail("应返回浏览器会话启动计划")
        }

        guard case .startBrowserSession(let url, _) = plan.primaryAction else {
            return XCTFail("打开网址应命中 startBrowserSession，实际为 \(plan.summary)")
        }

        XCTAssertEqual(url, "https://example.com/login")
    }

    func testPriorityLocalPlanContinuesBrowserSession() async {
        let snapshot = BrowserPageSnapshot(
            title: "GitHub Login",
            url: "https://github.com/login",
            textExcerpt: "Sign in to GitHub",
            pageKind: .login,
            authState: .needsLogin,
            actionableElements: [],
            screenshotPath: nil,
            capturedAt: Date()
        )
        let browserSession = BrowserSession(
            currentURL: snapshot.url,
            latestSnapshot: snapshot,
            status: .waitingUser
        )
        let envelope = makeEnvelope(
            text: "看看这个页面",
            activeBrowserSession: browserSession
        )

        let plan = await RuleBasedRequestPlannerProvider.shared.priorityLocalPlan(envelope)

        guard let plan else {
            return XCTFail("应返回浏览器会话继续计划")
        }

        guard case .continueBrowserSession(let sessionID, _) = plan.primaryAction else {
            return XCTFail("当前页面 follow-up 应命中 continueBrowserSession，实际为 \(plan.summary)")
        }

        XCTAssertEqual(sessionID, browserSession.id)
    }

    func testPriorityLocalPlanPromotesWhatsAppSessionToWorkflowClarification() async {
        let snapshot = BrowserPageSnapshot(
            title: "WhatsApp",
            url: "https://web.whatsapp.com",
            textExcerpt: "Chats Messages",
            pageKind: .chat,
            authState: .ready,
            actionableElements: [],
            screenshotPath: nil,
            capturedAt: Date()
        )
        let browserSession = BrowserSession(
            currentURL: snapshot.url,
            latestSnapshot: snapshot,
            status: .waitingUser
        )
        let envelope = makeEnvelope(
            text: "你现在接受whatsapp上的消息，来扮演一个专业的程序解答别人的问题",
            activeBrowserSession: browserSession
        )

        let plan = await RuleBasedRequestPlannerProvider.shared.priorityLocalPlan(envelope)

        guard let plan else {
            return XCTFail("应返回浏览器会话继续计划")
        }

        guard case .requestWorkflowClarification(let candidate, let missingSlots) = plan.primaryAction else {
            return XCTFail("活动 WhatsApp 会话中的高层托管指令应先进入 workflow 澄清，实际为 \(plan.summary)")
        }

        XCTAssertEqual(plan.intentKind, .workflow)
        XCTAssertEqual(candidate.name, "网页聊天接待助手")
        XCTAssertFalse(missingSlots.isEmpty, "高层托管诉求应要求补齐回复模式或处理范围")
    }

    func testPlannerPromotesComplexRequestToStructuredSubtaskPlan() async {
        let envelope = makeEnvelope(
            text: "分析磁盘空间、清理缓存，并执行命令发送结果给我"
        )

        let plan = await RuleBasedRequestPlannerProvider.shared.plan(envelope)

        guard case .executeSubtaskPlan(let subtaskPlan, let originalInput) = plan.primaryAction else {
            return XCTFail("复杂多意图请求应命中 executeSubtaskPlan，实际为 \(plan.summary)")
        }

        XCTAssertEqual(originalInput, "分析磁盘空间、清理缓存，并执行命令发送结果给我")
        XCTAssertGreaterThan(subtaskPlan.blueprints.count, 1, "应至少拆出多个子任务蓝图")
        XCTAssertEqual(plan.effectiveDispatchAssignments.count, subtaskPlan.blueprints.count)
        XCTAssertFalse(plan.selectedResources.serviceIDs.isEmpty, "子任务规划应带出相关执行资源")
        XCTAssertTrue(
            subtaskPlan.signals.contains(where: { $0.kind == .externalCommunication || $0.kind == .destructiveAction }),
            "复杂拆解结果应显式带出沟通或破坏性风险信号"
        )
        XCTAssertTrue(
            plan.effectiveDispatchAssignments.contains(where: \.requiresApproval),
            "高风险子任务拆解应把审批需求透传到执行分配"
        )
        XCTAssertTrue(
            plan.committeeSignals.contains(where: { $0.triggerReason == .highRisk }),
            "包含发送/回复等高风险词的复杂子任务请求应带出专家组风险信号"
        )
        XCTAssertTrue(
            plan.evidence.contains(where: { $0.description.contains("匹配能力") }),
            "子任务规划应把匹配能力写入 planner 证据链"
        )
        XCTAssertTrue(
            plan.evidence.contains(where: { $0.description.contains("拆解信号") }),
            "子任务规划应把结构化拆解信号写入 planner 证据链"
        )
    }

    func testPriorityLocalPlanStartsPublishedWorkflowDraftAfterConfirmation() async throws {
        let draft = try await MainActor.run { () throws -> WorkflowDraft in
            let candidate = WorkflowCandidate(
                name: "日报发送",
                description: "整理日报并发送",
                stepsPreview: ["收集信息/数据", "分析处理", "发送/通知"],
                estimatedSteps: 3,
                needsConfirmation: true,
                requiredCapabilities: [],
                missingSlots: []
            )
            return try WorkflowDraftService.shared.createDraft(
                from: candidate,
                originalInput: "帮我创建一个日报发送 workflow"
            )
        }
        defer {
            Task { @MainActor in
                try? WorkflowDraftStore.shared.delete(id: draft.id)
            }
        }

        let lastMessage = ChatMessage(
            role: .assistant,
            content: "Workflow 草稿已准备就绪。",
            metadata: [
                "workflow_draft_id": draft.id,
                "pending_workflow_draft": "true"
            ]
        )
        let envelope = makeEnvelope(text: "确认", lastMessage: lastMessage)

        let plan = await RuleBasedRequestPlannerProvider.shared.priorityLocalPlan(envelope)

        guard let plan else {
            return XCTFail("应返回 workflow 草稿确认计划")
        }

        guard case .startWorkflowRun(let definitionID, _) = plan.primaryAction else {
            return XCTFail("确认 ready draft 应命中 startWorkflowRun，实际为 \(plan.summary)")
        }

        XCTAssertEqual(definitionID, draft.id)
    }

    func testPriorityLocalPlanContinuesWorkflowDraftClarification() async throws {
        let draft = try await MainActor.run { () throws -> WorkflowDraft in
            let draft = WorkflowDraft(
                name: "通知发送",
                description: "给指定对象发送通知",
                originalInput: "帮我做一个通知 workflow",
                suggestedSteps: [WorkflowStepDef(name: "发送/通知", kind: .action)],
                missingSlots: [
                    PlanningSlot(
                        name: "recipient",
                        description: "目标接收者",
                        isRequired: true,
                        value: nil
                    )
                ],
                status: .clarifying
            )
            try WorkflowDraftStore.shared.save(draft)
            return draft
        }
        defer {
            Task { @MainActor in
                try? WorkflowDraftStore.shared.delete(id: draft.id)
            }
        }

        let lastMessage = ChatMessage(
            role: .assistant,
            content: "我还需要知道目标接收者。",
            metadata: [
                "workflow_draft_id": draft.id,
                "pending_workflow_clarification": "true"
            ]
        )
        let envelope = makeEnvelope(text: "发给张三", lastMessage: lastMessage)

        let plan = await RuleBasedRequestPlannerProvider.shared.priorityLocalPlan(envelope)

        guard let plan else {
            return XCTFail("应返回 workflow 澄清继续计划")
        }

        guard case .requestWorkflowClarification(_, let slots) = plan.primaryAction else {
            return XCTFail("补槽位输入应继续 workflow clarifying，实际为 \(plan.summary)")
        }

        XCTAssertEqual(plan.metadata["workflow_draft_id"], draft.id)
        XCTAssertEqual(slots.first(where: { $0.name == "recipient" })?.value, "张三")
    }

    func testPriorityLocalPlanContinuesPendingWorkflowRun() async {
        let lastMessage = ChatMessage(
            role: .assistant,
            content: "当前 workflow 需要重新规划。",
            metadata: [
                "pending_workflow_run": "true",
                "pending_workflow_replan": "true",
                "workflow_run_id": "run-123",
                "workflow_task_definition_id": "task-456",
                "workflow_step_id": "step-789"
            ]
        )
        let envelope = makeEnvelope(
            text: "改成先读取未读消息，再生成回复草稿",
            lastMessage: lastMessage
        )

        let plan = await RuleBasedRequestPlannerProvider.shared.priorityLocalPlan(envelope)

        guard let plan else {
            return XCTFail("应返回 workflow run 继续计划")
        }

        guard case .continueWorkflowRun(let runID, let stepID, let userResponse) = plan.primaryAction else {
            return XCTFail("待重规划 workflow 应命中 continueWorkflowRun，实际为 \(plan.summary)")
        }

        XCTAssertEqual(runID, "run-123")
        XCTAssertEqual(stepID, "step-789")
        XCTAssertEqual(userResponse, "改成先读取未读消息，再生成回复草稿")
        XCTAssertEqual(plan.metadata["workflow_task_definition_id"], "task-456")
    }

    @MainActor
    func testWorkflowRunCoordinatorArchivesTerminalRunsAfterCompletion() async throws {
        let definitionID = "workflow-test-\(UUID().uuidString)"
        let runID = "workflow-run-\(UUID().uuidString)"

        let definition = WorkflowDefinition(
            id: definitionID,
            name: "空 Workflow",
            description: "用于验证完成态归档",
            steps: []
        )
        try WorkflowDefinitionStore.shared.save(definition)

        defer {
            try? WorkflowDefinitionStore.shared.delete(id: definitionID)
        }

        _ = try await WorkflowRunCoordinator.shared.startWorkflow(
            definitionID: definitionID,
            runID: runID
        )

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(
            WorkflowRunCoordinator.shared.allActiveRunIDs().contains(runID),
            "已完成的 workflow run 不应继续停留在 activeRuns 中"
        )
        XCTAssertNotNil(
            WorkflowRunCoordinator.shared.runState(runID: runID),
            "已完成的 workflow run 仍应保留快照供任务中心和反思链路查询"
        )
    }

    @MainActor
    func testWorkflowRunCoordinatorRequiresPreviewConfirmationBeforeApplyingReplan() async throws {
        let definitionID = "workflow-preview-\(UUID().uuidString)"
        let runID = "workflow-preview-run-\(UUID().uuidString)"

        let definition = WorkflowDefinition(
            id: definitionID,
            name: "审批 Workflow",
            description: "用于验证重规划预览",
            steps: [
                WorkflowStepDef(
                    name: "人工审批",
                    kind: .approval
                )
            ]
        )
        try WorkflowDefinitionStore.shared.save(definition)

        var previewDraftID: String?

        defer {
            if let previewDraftID {
                try? WorkflowDraftStore.shared.delete(id: previewDraftID)
            }
            WorkflowRunCoordinator.shared.cancelWorkflow(runID: runID)
            try? WorkflowDefinitionStore.shared.delete(id: definitionID)
        }

        _ = try await WorkflowRunCoordinator.shared.startWorkflow(
            definitionID: definitionID,
            runID: runID
        )

        try await Task.sleep(nanoseconds: 150_000_000)
        WorkflowRunCoordinator.shared.markNeedsReplan(runID: runID, reason: "需要调整后续步骤")

        let preview = try WorkflowRunCoordinator.shared.prepareReplan(
            runID: runID,
            userInput: "先读取未读消息，再生成回复草稿"
        )
        previewDraftID = preview.draftID

        XCTAssertEqual(preview.proposedSteps.map(\.name), ["先读取未读消息", "再生成回复草稿"])
        XCTAssertEqual(
            WorkflowDraftStore.shared.draft(id: preview.draftID)?.context?.purpose,
            .replan,
            "runtime replan preview 应该落成带 replan context 的 workflow draft"
        )
        XCTAssertNotNil(
            WorkflowRunCoordinator.shared.runState(runID: runID)?.pendingReplan,
            "生成重规划预览后，runState 应保留待确认方案"
        )

        _ = try WorkflowRunCoordinator.shared.applyPreparedReplan(runID: runID)

        let updatedState = WorkflowRunCoordinator.shared.runState(runID: runID)
        XCTAssertNil(updatedState?.pendingReplan, "确认应用后不应继续保留待确认方案")
        XCTAssertTrue(
            updatedState?.checkpoints.contains(where: { $0.kind == .replanRequested }) == true,
            "应记录 replan preview 检查点"
        )
        XCTAssertTrue(
            updatedState?.checkpoints.contains(where: { $0.kind == .replanExecuted }) == true,
            "确认应用后应记录 replan executed 检查点"
        )
        XCTAssertEqual(
            WorkflowDraftStore.shared.draft(id: preview.draftID)?.status,
            .appliedToRun,
            "确认应用后，对应的 runtime replan draft 应标记为 appliedToRun"
        )
    }

    func testTaskLegacyBridgePrefersPendingReplanDetailForWorkflow() {
        let definition = TaskDefinition(
            id: "workflow-task-definition",
            title: "WhatsApp 接待",
            kind: .workflow,
            source: .manual,
            workflowSpec: WorkflowSpec(
                definitionID: "workflow-def",
                bindings: [],
                initialContext: [:],
                executionMode: .interactive
            )
        )
        let run = TaskRun(
            id: "workflow-run",
            definitionID: definition.id,
            phase: .waitingInput,
            workflowState: WorkflowRunState(
                definitionID: "workflow-def",
                activeStepID: "reply-step",
                pendingReplan: PendingWorkflowReplan(
                    draftID: "replan-draft",
                    sourceStepID: "reply-step",
                    reason: "需要确认新的执行方案",
                    userInput: "改成先整理上下文，再回复用户",
                    requestedAt: Date(),
                    proposedSteps: [
                        WorkflowStepDef(name: "整理上下文", kind: .action),
                        WorkflowStepDef(name: "生成回复草稿", kind: .action)
                    ]
                ),
                blockingReason: .waitingUser("等待确认新的执行方案")
            )
        )

        let legacy = TaskLegacyBridge.makeLegacyTask(from: definition, runs: [run])
        XCTAssertTrue(
            legacy?.description.contains("等待确认新方案") == true,
            "任务中心详情应优先展示 workflow 的待确认新方案"
        )
    }

    @MainActor
    func testStepExecutorRegistryPrefersBindingKindForActionSteps() {
        let step = WorkflowStepDef(
            name: "调用服务",
            kind: .action,
            bindingID: "service-binding"
        )
        let binding = WorkflowBinding(
            id: "service-binding",
            name: "测试服务",
            kind: .service,
            targetID: "mock-service"
        )

        _ = WorkflowRunCoordinator.shared
        let executor = StepExecutorRegistry.shared.executor(for: step, binding: binding)

        XCTAssertTrue(
            executor is ServiceStepExecutor,
            "带 service binding 的 action 步骤应优先命中 ServiceStepExecutor"
        )
    }

    func testBrowserContinueNeedsBrowserContextForGenericContinue() {
        let snapshot = BrowserPageSnapshot(
            title: "GitHub Login",
            url: "https://github.com/login",
            textExcerpt: "Sign in to GitHub",
            pageKind: .login,
            authState: .needsLogin,
            actionableElements: [],
            screenshotPath: nil,
            capturedAt: Date()
        )
        let browserSession = BrowserSession(
            currentURL: snapshot.url,
            latestSnapshot: snapshot,
            status: .waitingUser
        )
        let unrelatedLastMessage = ChatMessage(
            role: .assistant,
            content: "我们继续刚才的代码任务。"
        )

        XCTAssertFalse(
            RequestPlanningHeuristics.shouldContinueBrowserSession(
                with: "继续",
                session: browserSession,
                lastMessage: unrelatedLastMessage
            ),
            "泛化的继续命令在没有浏览器上下文提示时，不应劫持到 browser session"
        )
    }

    func testBrowserContinueAcceptsGenericContinueAfterBrowserPrompt() {
        let snapshot = BrowserPageSnapshot(
            title: "GitHub Login",
            url: "https://github.com/login",
            textExcerpt: "Sign in to GitHub",
            pageKind: .login,
            authState: .needsLogin,
            actionableElements: [],
            screenshotPath: nil,
            capturedAt: Date()
        )
        let browserSession = BrowserSession(
            currentURL: snapshot.url,
            latestSnapshot: snapshot,
            status: .waitingUser
        )
        let browserPrompt = ChatMessage(
            role: .assistant,
            content: "我已经打开当前网页。",
            metadata: [
                BrowserConversationMetadataKeys.pendingSessionID: browserSession.id,
                BrowserConversationMetadataKeys.promptKind: "next_step"
            ]
        )

        XCTAssertTrue(
            RequestPlanningHeuristics.shouldContinueBrowserSession(
                with: "继续",
                session: browserSession,
                lastMessage: browserPrompt
            ),
            "浏览器明确提示后的继续命令，应继续当前 browser session"
        )
    }

    func testAssemblerReusesActiveBrowserScreenshotForImageRequest() {
        let screenshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-context-test-\(UUID().uuidString).png")
        FileManager.default.createFile(
            atPath: screenshotURL.path,
            contents: Data("test".utf8)
        )
        defer {
            try? FileManager.default.removeItem(at: screenshotURL)
        }

        let snapshot = BrowserPageSnapshot(
            title: "GitHub Login",
            url: "https://github.com/login",
            textExcerpt: "Sign in to GitHub",
            pageKind: .login,
            authState: .needsLogin,
            actionableElements: [],
            screenshotPath: screenshotURL.path,
            capturedAt: Date()
        )
        let browserSession = BrowserSession(
            currentURL: snapshot.url,
            latestSnapshot: snapshot,
            status: .waitingUser
        )

        let request = ContextAssembler().assemble(
            ConversationAssemblyInput(
                text: "分析当前页面截图",
                explicitImages: [],
                lastScreenshotPath: nil,
                sessionTopology: ConversationControlStore.shared.currentTopology(),
                currentAgent: nil,
                needsInitialSetup: false,
                lastMessage: nil,
                creationFlowActive: false,
                messages: [],
                taskSessions: [],
                activeBrowserSessionID: browserSession.id,
                browserSessions: [browserSession]
            )
        )

        XCTAssertEqual(request.images, [screenshotURL.path])
    }
}

// MARK: - 模拟运行测试

class SimulationTests: XCTestCase {
    
    /// 模拟完整对话流程
    func testFullConversationFlow() {
        print("\n========== 开始模拟对话测试 ==========\n")
        
        let scenarios = [
            ("普通对话", "你好", "应该正常响应"),
            ("明确截图", "截图", "应该触发截图 Skill"),
            ("模糊输入", "截个图看看", "不应该触发（有"看看"）"),
            ("否定输入", "不用截图", "不应该触发（有"不用"）"),
            ("/命令", "/screenshot", "应该触发 Skill 命令"),
        ]
        
        var passCount = 0
        var failCount = 0
        
        for (name, input, expectation) in scenarios {
            let parsed = ConversationIntelligence.shared.analyzeInput(input)
            
            // 判断测试是否通过
            var passed = false
            var actual = ""
            
            switch name {
            case "普通对话":
                passed = !parsed.hasMentions && parsed.detectedSkill == nil
                actual = passed ? "正常文本" : "异常触发"
            case "明确截图":
                passed = parsed.detectedSkill == .screenshot
                actual = parsed.detectedSkill?.name ?? "nil"
            case "模糊输入", "否定输入":
                passed = parsed.detectedSkill == nil
                actual = parsed.detectedSkill?.name ?? "未触发（正确）"
            case "/命令":
                passed = parsed.skillCommand != nil
                actual = parsed.skillCommand?.skill.name ?? "nil"
            default:
                passed = true
                actual = "未测试"
            }
            
            if passed {
                passCount += 1
                print("✅ \(name): 通过")
            } else {
                failCount += 1
                print("❌ \(name): 失败")
            }
            print("   输入: '\(input)'")
            print("   期望: \(expectation)")
            print("   实际: \(actual)")
            print("")
        }
        
        print("========== 测试结果: \(passCount) 通过, \(failCount) 失败 ==========\n")
        
        XCTAssertEqual(failCount, 0, "所有测试应该通过")
    }
}
