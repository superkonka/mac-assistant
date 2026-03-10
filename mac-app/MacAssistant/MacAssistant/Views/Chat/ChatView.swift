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
    
    @State private var inputText: String = ""
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var showAgentList: Bool = false
    @State private var showWizard: Bool = false
    @State private var showSkills: Bool = false
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
        .background(Color(NSColor.controlBackgroundColor))
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
                            MessageBubble(
                                message: message,
                                availableWidth: availableBubbleWidth,
                                taskSession: commandRunner.taskSession(for: message.linkedTaskSessionID),
                                onToggleTaskSession: {
                                    if let taskSessionID = message.linkedTaskSessionID {
                                        commandRunner.toggleTaskSessionExpansion(taskSessionID)
                                    }
                                }
                            )
                            .equatable()
                            .id(message.id)

                            if let trace = commandRunner.currentExecutionTrace,
                               trace.anchorMessageID == message.id {
                                TraceStripView(
                                    trace: trace,
                                    availableWidth: availableBubbleWidth
                                )
                                    .equatable()
                            }
                        }

                        if commandRunner.isProcessing && commandRunner.currentExecutionTrace == nil {
                            TypingIndicator()
                        }
                    }
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
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
    
    // MARK: - 动作
    
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
        .background(Color(NSColor.controlBackgroundColor))
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
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
        .onAppear {
            offset = -4
        }
    }
}

// MARK: - Preview

#Preview {
    ChatView()
        .frame(width: 600, height: 500)
}
