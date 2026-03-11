//
//  ChatView.swift
//  MacAssistant
//
//  主聊天界面 - 自然融合 Agents 和 Skills
//

import SwiftUI
import Combine

struct ChatView: View {
    @StateObject private var commandRunner = CommandRunner.shared
    @StateObject private var agentStore = AgentStore.shared
    @StateObject private var orchestrator = AgentOrchestrator.shared
    @StateObject private var intelligence = ConversationIntelligence.shared
    @StateObject private var clawDoctor = OpenClawDoctor.shared
    
    @State private var inputText: String = ""
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var showAgentList: Bool = false
    @State private var showWizard: Bool = false
    @State private var showSkills: Bool = false
    @State private var showClawDoctor: Bool = false
    @State private var currentGap: CapabilityGap? = nil
    @State private var hasAutoPresentedInitialSetup = false
    @State private var lastStreamingScrollAt: Date = .distantPast
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            topBar
            
            Divider()
            
            // 消息列表
            messageList

            if shouldShowProcessingStatusDock {
                processingStatusDock
            }
            
            Divider()
            
            // 当前 Agent 指示器
            currentAgentBar
            
            // 智能输入区域
            IntelligentInputView(
                text: $inputText,
                onSend: sendMessage,
                onTakeScreenshot: takeScreenshot,
                onShowSkills: { showSkills = true }
            )
        }
        .frame(minWidth: 600, minHeight: 500)
        .onAppear {
            setupNotifications()
            presentInitialSetupIfNeeded()
            clawDoctor.startMonitoring()
        }
        .onChange(of: agentStore.usableAgents.count) { _ in
            presentInitialSetupIfNeeded()
        }
        .sheet(isPresented: $showAgentList) {
            AgentListView()
        }
        .sheet(isPresented: $showWizard) {
            AgentConfigurationWizard(
                gap: currentGap,
                isInitialSetup: currentGap == nil && agentStore.needsInitialSetup,
                onComplete: { agent in
                    showWizard = false
                    orchestrator.switchToAgent(agent)
                    hasAutoPresentedInitialSetup = false
                    
                    let successMessage = ChatMessage(
                        id: UUID(),
                        role: MessageRole.assistant,
                        content: """
                        ✅ Agent 创建成功！
                        
                        \(agent.displayName) 已就绪，已自动切换。
                        现在可以重新发送您的请求了。
                        """,
                        timestamp: Date()
                    )
                    commandRunner.messages.append(successMessage)
                }
            )
        }
        .popover(isPresented: $showSkills, attachmentAnchor: .point(.top), arrowEdge: .top) {
            SkillsListView()
                .frame(width: 760, height: 540)
        }
        .popover(isPresented: $showClawDoctor, attachmentAnchor: .point(.top), arrowEdge: .top) {
            OpenClawDoctorPanelView(doctor: clawDoctor)
        }
    }
    
    // MARK: - 子视图
    
    private var topBar: some View {
        HStack {
            // Agent 选择器
            Button(action: { showAgentList = true }) {
                HStack(spacing: 4) {
                    Text(orchestrator.currentAgent?.emoji ?? "🤖")
                    Text(orchestrator.currentAgent?.name ?? (agentStore.needsInitialSetup ? "配置 Agent" : "选择 Agent"))
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }
            .buttonStyle(PlainButtonStyle())

            OpenClawStatusEntry(doctor: clawDoctor) {
                showClawDoctor = true
            }
            
            Spacer()
            
            // 快速提示
            if let suggestion = orchestrator.getSuggestion(for: inputText) {
                Text(suggestion)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // 设置按钮
            Button(action: { showSkills = true }) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14))
            }
            .buttonStyle(PlainButtonStyle())
            .help("Skills")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.controlBackground)
    }
    
    private var messageList: some View {
        GeometryReader { geometry in
            let availableBubbleWidth = max(geometry.size.width - 24, 320)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        if commandRunner.messages.isEmpty && agentStore.needsInitialSetup {
                            InitialSetupCard {
                                currentGap = nil
                                showWizard = true
                            }
                        }

                        ForEach(commandRunner.messages) { message in
                            let trace = commandRunner.executionTrace(forMessageID: message.id)
                            let hidesPlaceholderBubble = shouldHideAssistantPlaceholder(message, trace: trace)

                            if !hidesPlaceholderBubble {
                                MessageBubble(
                                    message: message,
                                    availableWidth: availableBubbleWidth,
                                    taskSession: commandRunner.taskSession(for: message.linkedTaskSessionID),
                                    onToggleTaskSession: {
                                        if let taskSessionID = message.linkedTaskSessionID {
                                            commandRunner.toggleTaskSessionExpansion(taskSessionID)
                                        }
                                    },
                                    onResumeTaskSession: {
                                        if let taskSessionID = message.linkedTaskSessionID {
                                            commandRunner.resumeTaskSession(taskSessionID)
                                        }
                                    }
                                )
                                .id(messageRenderIdentity(for: message))
                            }

                            if let trace {
                                TraceStripView(
                                    trace: trace,
                                    availableWidth: availableBubbleWidth
                                )
                            }
                        }

                        if commandRunner.isProcessing && commandRunner.currentExecutionTrace == nil {
                            TypingIndicator()
                        }
                    }
                    .id(messageListRevision)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 12)
                }
                .onChange(of: commandRunner.messages.count) { _ in
                    scrollToBottom(proxy: proxy, animated: true)
                }
                .onChange(of: commandRunner.currentExecutionTrace?.id) { _ in
                    scrollToBottom(proxy: proxy, animated: false)
                }
            }
        }
    }
    
    private var currentAgentBar: some View {
        HStack {
            if let agent = orchestrator.currentAgent {
                Text("\(agent.emoji) \(agent.name) · \(agent.model)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                // 能力标签
                HStack(spacing: 4) {
                    ForEach(agent.capabilities.prefix(3), id: \.self) { capability in
                        CapabilityBadge(capability: capability)
                    }
                }
                
                Spacer()
                
                // 提示使用 @
                Text("提示: 输入 @ 切换 Agent")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
            } else {
                Text(agentStore.needsInitialSetup ? "尚未配置可用 LLM / CLI Agent" : "未选择 Agent")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(AppColors.controlBackground.opacity(0.5))
    }

    private var processingStatusDock: some View {
        InlineProcessingBar(
            trace: commandRunner.currentExecutionTrace,
            fallbackAgentName: orchestrator.currentAgent?.displayName ?? "当前 Agent"
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppColors.controlBackground.opacity(0.62))
    }
    
    // MARK: - 动作

    private func messageRenderIdentity(for message: ChatMessage) -> String {
        var hasher = Hasher()
        hasher.combine(message.id)
        hasher.combine(message.content)
        hasher.combine(message.agentId)
        hasher.combine(message.agentName)
        hasher.combine(message.linkedTaskSessionID)
        return "\(message.id.uuidString)-\(hasher.finalize())"
    }

    private var messageListRevision: String {
        commandRunner.messages
            .map { messageRenderIdentity(for: $0) }
            .joined(separator: "|")
    }

    private var shouldShowProcessingStatusDock: Bool {
        guard commandRunner.isProcessing else { return false }
        guard let trace = commandRunner.currentExecutionTrace else { return true }

        let inlineMessageID = trace.assistantMessageID ?? trace.anchorMessageID
        return !commandRunner.messages.contains(where: { $0.id == inlineMessageID })
    }

    private func shouldHideAssistantPlaceholder(_ message: ChatMessage, trace: ExecutionTrace?) -> Bool {
        guard trace != nil, message.role == .assistant else { return false }
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.hasPrefix("⏳ ") else { return false }
        return content.contains("正在思考") ||
            content.contains("正在继续处理") ||
            content.contains("正在连接") ||
            content.contains("正在直接调用")
    }
    
    private func sendMessage(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if agentStore.needsInitialSetup {
            currentGap = nil
            showWizard = true
            commandRunner.showInitialSetupGuidance(for: "开始对话")
            return
        }

        inputText = ""
        
        Task {
            await commandRunner.processInput(text)
        }
    }
    
    private func takeScreenshot() {
        commandRunner.handleScreenshot()
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ShowCapabilityWizard"),
            object: nil,
            queue: .main
        ) { notification in
            if let gap = notification.object as? CapabilityGap {
                currentGap = gap
                showWizard = true
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ShowInitialSetupWizard"),
            object: nil,
            queue: .main
        ) { _ in
            currentGap = nil
            showWizard = true
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ShowSkillsBrowser"),
            object: nil,
            queue: .main
        ) { _ in
            showSkills = true
        }
    }
    
    // MARK: - 辅助方法
    
    private func scrollToBottom(
        proxy: ScrollViewProxy,
        animated: Bool,
        throttleInterval: TimeInterval? = nil
    ) {
        let now = Date()
        if let throttleInterval,
           now.timeIntervalSince(lastStreamingScrollAt) < throttleInterval {
            return
        }
        lastStreamingScrollAt = now

        if let lastMessage = commandRunner.messages.last {
            let action = {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    action()
                }
            } else {
                action()
            }
        }
    }

    private func presentInitialSetupIfNeeded(force: Bool = false) {
        guard agentStore.needsInitialSetup else {
            hasAutoPresentedInitialSetup = false
            return
        }

        guard force || !hasAutoPresentedInitialSetup else { return }
        currentGap = nil
        showWizard = true
        hasAutoPresentedInitialSetup = true
    }
}

struct CapabilityBadge: View {
    let capability: Capability
    
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: capability.icon)
                .font(.system(size: 8))
            Text(capability.displayName)
                .font(.system(size: 9))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.blue.opacity(0.1))
        .foregroundColor(.blue)
        .cornerRadius(4)
    }
}

struct InitialSetupCard: View {
    let onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("首次使用先配置模型")
                .font(.system(size: 18, weight: .semibold))

            Text("当前还没有可用的 LLM 或 CLI Agent。先完成一次配置，后续聊天、截图分析和 Skills 才能工作。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Button("立即配置") {
                onConfigure()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AppColors.controlBackground)
        .cornerRadius(12)
    }
}

struct TypingIndicator: View {
    @State private var offset: CGFloat = 0
    
    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 6, height: 6)
                        .offset(y: offset)
                        .animation(
                            .easeInOut(duration: 0.5)
                            .repeatForever()
                            .delay(Double(i) * 0.15),
                            value: offset
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppColors.controlBackground)
            .cornerRadius(12)
        }
        .onAppear {
            offset = -4
        }
    }
}

private struct InlineProcessingBar: View {
    let trace: ExecutionTrace?
    let fallbackAgentName: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsedText(referenceDate: context.date))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.75))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.blue.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.blue.opacity(0.16), lineWidth: 1)
        )
    }

    private var title: String {
        guard let trace else {
            return "\(fallbackAgentName) 正在处理你的请求"
        }
        switch trace.state {
        case .routing:
            return "正在选择处理线路"
        case .running:
            return "\(trace.agentName) 正在执行"
        case .fallback:
            return "\(trace.agentName) 正在自动接管"
        case .synthesizing:
            return "正在整理最终回复"
        case .completed:
            return "结果已经返回"
        case .failed:
            return "这次请求没有顺利完成"
        }
    }

    private var subtitle: String {
        guard let trace else {
            return "请求已提交，正在等待第一段有效结果返回到聊天窗口。"
        }
        switch trace.state {
        case .routing:
            return "系统正在判断能力和执行路线，接下来会把请求发送给目标 Agent。"
        case .running:
            return trace.summary.isEmpty ? "请求已发出，正在等待结果流写回聊天气泡。" : trace.summary
        case .fallback:
            return trace.summary.isEmpty ? "原线路不可用，系统正在自动切换到备用线路。" : trace.summary
        case .synthesizing:
            return trace.summary.isEmpty ? "执行已经结束，正在把结果整理成当前对话里的最终答复。" : trace.summary
        case .completed:
            return trace.summary
        case .failed:
            return trace.summary
        }
    }

    private func elapsedText(referenceDate: Date) -> String {
        let startDate = trace?.startedAt ?? referenceDate
        let elapsed = max(0, Int(referenceDate.timeIntervalSince(startDate)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        if minutes > 0 {
            return String(format: "已耗时 %d:%02d", minutes, seconds)
        }
        return "已耗时 \(seconds)s"
    }
}

// MARK: - Preview

#Preview {
    ChatView()
        .frame(width: 600, height: 500)
}
