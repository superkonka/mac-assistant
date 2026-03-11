//
//  ContentView.swift
//  Agent 版 - 直接调用 Kimi CLI + Skill 系统
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var runner: CommandRunner
    @EnvironmentObject var autoAgent: AutoAgent
    @StateObject private var orchestrator = AgentOrchestrator.shared
    @StateObject private var agentStore = AgentStore.shared
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    
    // Agent 系统相关状态
    @State private var showingAgentList = false
    @State private var showingWizard = false
    @State private var currentGap: CapabilityGap?
    @State private var showingGapAlert = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 测试条 - 如果能看到说明应用已更新
            Color.red.frame(height: 20)
            
            // Agent 切换栏
            agentBar
            
            // CLI 进度走马灯（吸顶）
            CLIMarqueeView()
            
            Divider()
            
            // 消息列表
            messagesList
            
            Divider()
            
            // 输入区域
            inputArea
        }
        .frame(width: 500, height: 700)
        .onAppear {
            runner.loadHistory()
            isInputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowCapabilityDiscovery"))) { notification in
            if let gap = notification.object as? CapabilityGap {
                currentGap = gap
                showingWizard = true
            }
        }
    }
    
    // MARK: - Agent 切换栏
    
    var agentBar: some View {
        HStack(spacing: 12) {
            // 当前 Agent 信息
            if let currentAgent = orchestrator.currentAgent {
                HStack(spacing: 6) {
                    Text(currentAgent.emoji)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text(currentAgent.name)
                            .font(.system(size: 12, weight: .medium))
                        Text(currentAgent.provider.displayName)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
                .onTapGesture {
                    showingAgentList = true
                }
            }
            
            Spacer()
            
            // OpenClaw 状态指示器
            OpenClawStatusView(compactMode: true)
            
            // 添加 Agent 按钮
            Button(action: { showingAgentList = true }) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 20, height: 20)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }
            .buttonStyle(PlainButtonStyle())
            .help("管理 Agents")
            
            Button("清空") {
                runner.clearHistory()
            }
            .font(.caption)
            .buttonStyle(LinkButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $showingAgentList) {
            AgentListView()
        }
        .sheet(isPresented: $showingWizard) {
            AgentConfigurationWizard(gap: currentGap) { newAgent in
                orchestrator.switchToAgent(newAgent)
            }
        }
    }
    
    // MARK: - 分析面板
    
    var analysisPanel: some View {
        VStack(spacing: 8) {
            // 待处理通知
            ForEach(autoAgent.pendingNotifications.prefix(3)) { notification in
                NotificationBanner(notification: notification)
            }
            
            // 最新分析结果
            if let analysis = autoAgent.lastAnalysis {
                AnalysisCard(analysis: analysis)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
    
    // MARK: - 消息列表
    
    var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(runner.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    
                    if runner.isLoading {
                        LoadingView()
                            .id("loading")
                    }
                }
                .padding()
            }
            .onChange(of: runner.messages.count) { _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }
    
    func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastId = runner.messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }
    
    // MARK: - 输入区域
    
    var inputArea: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("输入消息或命令...", text: $inputText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($isInputFocused)
                    .onSubmit { send() }
                
                Button(action: send) {
                    Image(systemName: runner.isLoading ? "hourglass" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(canSend ? .blue : .gray)
                }
                .disabled(!canSend)
                .buttonStyle(PlainButtonStyle())
            }
            
            HStack(spacing: 10) {
                QuickButton(icon: "camera", text: "截图") { inputText = "/截图"; send() }
                QuickButton(icon: "doc.on.clipboard", text: "剪贴板") { inputText = "/剪贴板"; send() }
                QuickButton(icon: "magnifyingglass", text: "搜索") { inputText = "/搜索 "; isInputFocused = true }
                QuickButton(icon: "brain.head.profile", text: "分析") { inputText = "/分析"; send() }
                QuickButton(icon: "questionmark.circle", text: "帮助") { inputText = "/帮助"; send() }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    var canSend: Bool {
        !inputText.isEmpty && !runner.isLoading
    }
    
    func send() {
        guard canSend else { return }
        let text = inputText
        inputText = ""
        isInputFocused = true
        // TODO: 调用 runner 发送消息
    }
}

// MARK: - 能力缺口提示

struct CapabilityGapAlert: View {
    let gap: CapabilityGap
    @Binding var isPresented: Bool
    let onConfigure: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 40))
                .foregroundColor(.yellow)
            
            Text("需要 \(gap.missingCapability.displayName) 能力")
                .font(.headline)
            
            Text(gap.solutionDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            HStack(spacing: 12) {
                Button("跳过") {
                    isPresented = false
                }
                .buttonStyle(SecondaryButtonStyle())
                
                Button("配置 Agent") {
                    onConfigure()
                    isPresented = false
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 350)
    }
}

// MARK: - 通知横幅

struct NotificationBanner: View {
    let notification: AgentNotification
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(.system(size: 12, weight: .medium))
                Text(notification.message)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            Spacer()
            
            if let action = notification.action {
                Button(action: action) {}
                .font(.caption)
                .buttonStyle(BorderedButtonStyle())
            }
        }
        .padding(8)
        .background(backgroundColor.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(backgroundColor.opacity(0.3), lineWidth: 1)
        )
    }
    
    var iconName: String {
        switch notification.type {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .action: return "bolt.fill"
        case .suggestion: return "lightbulb"
        case .alert: return "exclamationmark.octagon"
        case .systemAlert: return "exclamationmark.octagon.fill"
        case .insight: return "magnifyingglass"
        case .reminder: return "clock"
        case .automation: return "gearshape.2"
        @unknown default: return "questionmark.circle"
        }
    }
    
    var iconColor: Color {
        switch notification.type {
        case .info: return .blue
        case .warning: return .orange
        case .action: return .purple
        case .suggestion: return .green
        case .alert: return .red
        case .systemAlert: return .red
        case .insight: return .cyan
        case .reminder: return .yellow
        case .automation: return .indigo
        @unknown default: return .gray
        }
    }
    
    var backgroundColor: Color {
        iconColor
    }
}

// MARK: - 分析卡片

struct AnalysisCard: View {
    let analysis: AnalysisResult
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("环境分析", systemImage: "brain")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("置信度: \(Int(analysis.confidence * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if !analysis.findings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(analysis.findings.prefix(2), id: \.content) { finding in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(finding.source == .openclaw ? Color.blue : Color.green)
                                .frame(width: 4, height: 4)
                            Text(finding.content)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - 其他组件

struct LoadingView: View {
    @State private var isAnimating = false
    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.gray).frame(width: 6, height: 6)
                        .scaleEffect(isAnimating ? 1.2 : 0.8)
                        .opacity(isAnimating ? 1 : 0.5)
                        .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: isAnimating)
                }
            }
            .padding(8)
            Spacer()
        }
        .onAppear { isAnimating = true }
    }
}

struct QuickButton: View {
    let icon: String
    let text: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 14))
                Text(text).font(.caption2)
            }
            .foregroundColor(.secondary)
            .frame(width: 45)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
