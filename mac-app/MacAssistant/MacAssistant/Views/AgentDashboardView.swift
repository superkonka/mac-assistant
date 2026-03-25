//
//  AgentDashboardView.swift
//  MacAssistant
//
//  Agent 管理仪表盘 - macOS 原生风格重构
//

import SwiftUI

// MARK: - 主视图
struct AgentDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var agentStore = AgentStore.shared
    @StateObject private var healthMonitor = AgentHealthMonitor.shared
    @State private var showingWizard = false
    @State private var selectedAgent: Agent?
    @State private var showingDeleteConfirm = false
    @State private var searchText = ""
    @State private var selectedViewMode: ViewMode = .grid
    
    enum ViewMode: String, CaseIterable {
        case grid = "网格"
        case pipeline = "流水线"
        case list = "列表"
    }
    
    var filteredAgents: [Agent] {
        if searchText.isEmpty { return agentStore.agents }
        return agentStore.agents.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.model.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var onlineAgents: [Agent] {
        filteredAgents.filter { healthMonitor.status(for: $0)?.isOnline == true }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 工具栏
                toolbarView
                
                Divider()
                
                // 主内容区
                ScrollView {
                    switch selectedViewMode {
                    case .grid:
                        GridView(
                            agents: filteredAgents,
                            healthMonitor: healthMonitor,
                            onSelect: { selectedAgent = $0 },
                            onDelete: { agentToDelete in
                                selectedAgent = agentToDelete
                                showingDeleteConfirm = true
                            }
                        )
                    case .pipeline:
                        PipelineView(
                            agents: filteredAgents,
                            healthMonitor: healthMonitor
                        )
                    case .list:
                        CompactListView(
                            agents: filteredAgents,
                            healthMonitor: healthMonitor
                        )
                    }
                }
                .padding()
                
                // 底部状态栏
                statusBarView
            }
            .navigationTitle("Agent 管理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showingWizard) {
                AgentConfigurationWizard { newAgent in
                    if agentStore.shouldAutoAdoptAsCurrent(newAgent) {
                        agentStore.switchToAgent(newAgent)
                    }
                }
            }
            .sheet(item: $selectedAgent) { agent in
                AgentDetailSheet(agent: agent, healthMonitor: healthMonitor)
            }
            .alert("确认删除", isPresented: $showingDeleteConfirm, presenting: selectedAgent) { agent in
                Button("删除", role: .destructive) {
                    agentStore.deleteAgent(agent)
                }
                Button("取消", role: .cancel) {}
            } message: { agent in
                Text("确定要删除 「\(agent.name)」吗？此操作不可撤销。")
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
    
    // MARK: - 工具栏
    private var toolbarView: some View {
        HStack(spacing: 16) {
            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("搜索", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .frame(width: 180)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
            )
            
            Spacer()
            
            // 视图切换
            Picker("", selection: $selectedViewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Image(systemName: iconForMode(mode))
                        .help(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            
            Spacer()
            
            // 添加按钮
            Button(action: { showingWizard = true }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("新建 Agent")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - 状态栏
    private var statusBarView: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("\(onlineAgents.count) 在线")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 6, height: 6)
                Text("\(agentStore.agents.count - onlineAgents.count) 离线")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if let current = agentStore.currentAgent {
                HStack(spacing: 4) {
                    Text("当前:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(current.name)
                        .font(.system(size: 11, weight: .medium))
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(height: 0.5)
                .frame(maxHeight: .infinity, alignment: .top)
        )
    }
    
    private func iconForMode(_ mode: ViewMode) -> String {
        switch mode {
        case .grid: return "square.grid.2x2"
        case .pipeline: return "arrow.right.arrow.left"
        case .list: return "list.bullet"
        }
    }
}

// MARK: - 网格视图
struct GridView: View {
    let agents: [Agent]
    let healthMonitor: AgentHealthMonitor
    let onSelect: (Agent) -> Void
    let onDelete: (Agent) -> Void
    
    var body: some View {
        LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 260, maximum: 300), spacing: 12)
        ], spacing: 12) {
            ForEach(agents) { agent in
                AgentCard(
                    agent: agent,
                    status: healthMonitor.status(for: agent),
                    stats: healthMonitor.stats(for: agent),
                    onTap: { onSelect(agent) },
                    onDelete: { onDelete(agent) }
                )
            }
        }
    }
}

// MARK: - Agent 卡片（重构版）
struct AgentCard: View {
    let agent: Agent
    let status: AgentHealthStatus?
    let stats: AgentHealthMonitor.AgentStats?
    let onTap: () -> Void
    let onDelete: () -> Void
    
    @State private var showingQuickTest = false
    
    private var isOnline: Bool {
        status?.isOnline ?? false
    }
    
    private var isCurrent: Bool {
        AgentStore.shared.currentAgent?.id == agent.id
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部
            HStack(spacing: 10) {
                // 头像 + 状态
                ZStack(alignment: .bottomTrailing) {
                    Text(agent.emoji)
                        .font(.system(size: 24))
                        .frame(width: 40, height: 40)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                    
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(agent.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        
                        if agent.isDefault {
                            Text("默认")
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(3)
                        }
                    }
                    
                    Text(agent.model)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // 菜单
                Menu {
                    let canUse = AgentStore.shared.canUse(agent)
                    Button("设为当前对话") {
                        if canUse { AgentStore.shared.switchToAgent(agent) }
                    }
                    .disabled(!canUse)
                    
                    if !agent.isDefault {
                        Button("设为默认") {
                            if canUse { AgentStore.shared.setDefaultAgent(agent) }
                        }
                        .disabled(!canUse)
                    }
                    
                    Divider()
                    
                    Button("快速测试") { showingQuickTest = true }
                    Button("编辑配置") { onTap() }
                    
                    Divider()
                    
                    Button("删除", role: .destructive) { onDelete() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            // 角色标签（简化）
            if !agentRoles.isEmpty {
                HStack(spacing: 4) {
                    ForEach(agentRoles.prefix(3), id: \.self) { role in
                        HStack(spacing: 2) {
                            Image(systemName: role.icon)
                                .font(.system(size: 8))
                            Text(role.displayName)
                                .font(.system(size: 9))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(role.color.opacity(0.1))
                        .foregroundColor(role.color)
                        .cornerRadius(4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            
            // 统计信息（精简）
            HStack(spacing: 12) {
                if let stats = stats, stats.totalCalls > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bubble.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                        Text("\(stats.totalCalls)")
                            .font(.system(size: 10))
                    }
                    
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(stats.successRate > 0.9 ? .green : .orange)
                        Text("\(Int(stats.successRate * 100))%")
                            .font(.system(size: 10))
                    }
                    
                    if stats.averageLatency > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                            Text(String(format: "%.1fs", stats.averageLatency))
                                .font(.system(size: 10))
                        }
                    }
                }
                
                Spacer()
                
                // Provider 标识
                Text(agent.provider.displayName)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            
            // 底部操作栏
            HStack(spacing: 0) {
                let canUse = AgentStore.shared.canUse(agent)
                
                Button {
                    showingQuickTest = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                        Text("测试")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(!isOnline)
                .opacity(isOnline ? 1 : 0.4)
                
                Spacer()
                
                if isCurrent {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.blue)
                        Text("当前")
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                    }
                } else if isOnline && canUse {
                    Button {
                        AgentStore.shared.switchToAgent(agent)
                    } label: {
                        Text("切换")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                } else {
                    Text(isOnline ? "不可用" : "离线")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrent ? Color.blue.opacity(0.5) : Color.gray.opacity(0.15), lineWidth: isCurrent ? 1.5 : 0.5)
        )
        .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 2)
        .onTapGesture {
            onTap()
        }
        .sheet(isPresented: $showingQuickTest) {
            QuickTestSheet(agent: agent)
        }
    }
    
    private var agentStore: AgentStore { .shared }
    
    private var agentRoles: [AgentRole] {
        AgentStore.shared.roleProfile(for: agent).sortedRoles
    }
    
    private var statusColor: Color {
        status?.color ?? .gray
    }
}

// MARK: - 流水线视图
struct PipelineView: View {
    let agents: [Agent]
    let healthMonitor: AgentHealthMonitor
    
    var body: some View {
        VStack(spacing: 16) {
            PipelineSection(
                title: "Planner",
                icon: "point.topleft.down.curvedto.point.bottomright.up",
                color: .blue,
                agents: agents.filter { AgentStore.shared.hasRole(.planner, for: $0) },
                healthMonitor: healthMonitor
            )
            
            ArrowDown()
            
            PipelineSection(
                title: "子任务",
                icon: "square.stack.3d.up",
                color: .green,
                agents: agents.filter { AgentStore.shared.hasRole(.subtaskWorker, for: $0) },
                healthMonitor: healthMonitor
            )
            
            ArrowDown()
            
            PipelineSection(
                title: "回退",
                icon: "arrow.trianglehead.clockwise",
                color: .purple,
                agents: agents.filter { AgentStore.shared.hasRole(.fallback, for: $0) },
                healthMonitor: healthMonitor
            )
        }
        .padding()
    }
}

struct PipelineSection: View {
    let title: String
    let icon: String
    let color: Color
    let agents: [Agent]
    let healthMonitor: AgentHealthMonitor
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text("\(agents.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(3)
                Spacer()
            }
            
            if agents.isEmpty {
                Text("暂无 Agent")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Color.gray.opacity(0.03))
                    .cornerRadius(6)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(agents) { agent in
                        PipelineAgentChip(
                            agent: agent,
                            status: healthMonitor.status(for: agent),
                            isCurrent: AgentStore.shared.currentAgent?.id == agent.id
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(color.opacity(0.02))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.1), lineWidth: 0.5)
        )
    }
}

struct PipelineAgentChip: View {
    let agent: Agent
    let status: AgentHealthStatus?
    let isCurrent: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            Text(agent.emoji)
                .font(.system(size: 12))
            Text(agent.name)
                .font(.system(size: 11))
            
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.blue)
            }
            
            Circle()
                .fill(status?.color ?? .gray)
                .frame(width: 5, height: 5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isCurrent ? Color.blue : Color.gray.opacity(0.15), lineWidth: isCurrent ? 1 : 0.5)
        )
    }
}

struct ArrowDown: View {
    var body: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 14))
            .foregroundColor(.secondary.opacity(0.4))
    }
}

// MARK: - 紧凑列表视图
struct CompactListView: View {
    let agents: [Agent]
    let healthMonitor: AgentHealthMonitor
    
    var body: some View {
        LazyVStack(spacing: 4) {
            ForEach(agents) { agent in
                CompactAgentRow(
                    agent: agent,
                    status: healthMonitor.status(for: agent),
                    stats: healthMonitor.stats(for: agent)
                )
            }
        }
    }
}

struct CompactAgentRow: View {
    let agent: Agent
    let status: AgentHealthStatus?
    let stats: AgentHealthMonitor.AgentStats?
    
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(status?.color ?? .gray)
                .frame(width: 6, height: 6)
            
            Text(agent.emoji)
                .font(.system(size: 16))
            
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.system(size: 12, weight: .medium))
                Text(agent.model)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 角色标签
            HStack(spacing: 3) {
                ForEach(AgentStore.shared.roleProfile(for: agent).sortedRoles.prefix(2), id: \.self) { role in
                    Image(systemName: role.icon)
                        .font(.system(size: 8))
                        .foregroundColor(role.color)
                        .help(role.displayName)
                }
            }
            
            // 统计
            if let stats = stats, stats.totalCalls > 0 {
                HStack(spacing: 8) {
                    Text("\(stats.totalCalls)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("\(Int(stats.successRate * 100))%")
                        .font(.system(size: 11))
                        .foregroundColor(stats.successRate > 0.9 ? .green : .orange)
                }
                .frame(width: 70, alignment: .trailing)
            } else {
                Spacer()
                    .frame(width: 70)
            }
            
            // 操作
            let canUse = AgentStore.shared.canUse(agent)
            let isCurrent = AgentStore.shared.currentAgent?.id == agent.id
            
            if isCurrent {
                HStack(spacing: 2) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9))
                    Text("当前")
                        .font(.system(size: 10))
                }
                .foregroundColor(.blue)
                .frame(width: 50)
            } else {
                Button {
                    AgentStore.shared.switchToAgent(agent)
                } label: {
                    Text("切换")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(status?.isOnline != true || !canUse)
                .frame(width: 50)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.1), lineWidth: 0.5)
        )
    }
}

// MARK: - Agent 健康监控
@MainActor
class AgentHealthMonitor: ObservableObject {
    static let shared = AgentHealthMonitor()
    
    @Published private var statuses: [String: AgentHealthStatus] = [:]
    @Published private var statsData: [String: AgentStats] = [:]
    
    struct AgentStats {
        var totalCalls: Int = 0
        var successfulCalls: Int = 0
        var totalResponseTime: TimeInterval = 0
        var lastUsedAt: Date?
        
        var successRate: Double {
            guard totalCalls > 0 else { return 0 }
            return Double(successfulCalls) / Double(totalCalls)
        }
        
        var averageLatency: TimeInterval {
            guard totalCalls > 0 else { return 0 }
            return totalResponseTime / Double(totalCalls)
        }
    }
    
    func status(for agent: Agent) -> AgentHealthStatus? {
        statuses[agent.id]
    }
    
    func stats(for agent: Agent) -> AgentStats? {
        statsData[agent.id]
    }
    
    var totalCallsToday: Int {
        statsData.values.reduce(0) { $0 + $1.totalCalls }
    }
    
    var averageLatency: TimeInterval {
        let total = statsData.values.reduce(0.0) { $0 + $1.totalResponseTime }
        let count = statsData.values.reduce(0) { $0 + $1.totalCalls }
        guard count > 0 else { return 0 }
        return total / Double(count)
    }
    
    init() {}
}

enum AgentHealthStatus {
    case online
    case degraded
    case offline
    case unknown
    
    var isOnline: Bool {
        self == .online || self == .degraded
    }
    
    var color: Color {
        switch self {
        case .online: return .green
        case .degraded: return .orange
        case .offline: return .red
        case .unknown: return .gray
        }
    }
}

// MARK: - 快速测试面板
struct QuickTestSheet: View {
    let agent: Agent
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            QuickTestPanel(agent: agent)
                .navigationTitle("测试: \(agent.name)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
        .frame(width: 450, height: 350)
    }
}

struct QuickTestPanel: View {
    let agent: Agent
    @State private var testResults: [TestResult] = []
    @State private var isRunning = false
    
    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 10) {
                TestButton(
                    icon: "network",
                    title: "连通性",
                    color: .blue
                ) {
                    runTest(type: .connectivity)
                }
                
                TestButton(
                    icon: "bubble.left.fill",
                    title: "对话",
                    color: .green
                ) {
                    runTest(type: .chat)
                }
                
                TestButton(
                    icon: "photo.fill",
                    title: "图片",
                    color: .purple,
                    isDisabled: !agent.supports(.vision)
                ) {
                    runTest(type: .vision)
                }
                
                TestButton(
                    icon: "doc.text.fill",
                    title: "文档",
                    color: .orange,
                    isDisabled: !agent.supports(.documentAnalysis)
                ) {
                    runTest(type: .document)
                }
            }
            
            Divider()
            
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(testResults) { result in
                        TestResultRow(result: result)
                    }
                }
            }
        }
        .padding()
    }
    
    private func runTest(type: TestType) {
        isRunning = true
        let startTime = Date()
        
        Task {
            do {
                let result = try await performTest(type: type)
                let latency = Date().timeIntervalSince(startTime)
                
                await MainActor.run {
                    testResults.insert(result.withLatency(latency), at: 0)
                    isRunning = false
                }
            } catch {
                let latency = Date().timeIntervalSince(startTime)
                await MainActor.run {
                    testResults.insert(TestResult(
                        type: type,
                        success: false,
                        message: error.localizedDescription,
                        latency: latency,
                        timestamp: Date()
                    ), at: 0)
                    isRunning = false
                }
            }
        }
    }
    
    private func performTest(type: TestType) async throws -> TestResult {
        let runtime = NativeConversationRuntimeAdapter.shared
        
        switch type {
        case .connectivity:
            // 检查 Agent 是否配置正确
            let isAvailable = AgentStore.shared.canUse(agent)
            return TestResult(
                type: type,
                success: isAvailable,
                message: isAvailable ? "Agent 可正常使用" : "Agent 未配置或不可用",
                latency: 0,
                timestamp: Date()
            )
            
        case .chat:
            // 发送测试消息
            let response = try await runtime.sendMessage(
                agent: agent,
                sessionKey: "test-\(UUID().uuidString)",
                sessionLabel: "Test",
                requestID: UUID().uuidString,
                text: "Hello, this is a test message. Please reply with 'OK'.",
                images: [],
                systemPrompt: nil,
                onAssistantText: nil
            )
            let success = !response.isEmpty
            return TestResult(
                type: type,
                success: success,
                message: success ? "收到回复: \(String(response.prefix(50)))" : "未收到有效回复",
                latency: 0,
                timestamp: Date()
            )
            
        case .vision:
            // 测试图片能力配置
            let hasVision = agent.supports(.vision)
            return TestResult(
                type: type,
                success: hasVision,
                message: hasVision ? "Agent 支持图片分析" : "Agent 未配置图片分析能力",
                latency: 0,
                timestamp: Date()
            )
            
        case .document:
            // 测试文档处理能力
            let hasDocSupport = agent.supports(.documentAnalysis)
            return TestResult(
                type: type,
                success: hasDocSupport,
                message: hasDocSupport ? "Agent 支持文档处理" : "Agent 未配置文档处理能力",
                latency: 0,
                timestamp: Date()
            )
        }
    }
}

struct TestButton: View {
    let icon: String
    let title: String
    let color: Color
    var isDisabled: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(isDisabled ? .secondary : color)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(color.opacity(isDisabled ? 0.03 : 0.08))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

struct TestResult: Identifiable {
    let id = UUID()
    let type: TestType
    let success: Bool
    let message: String
    let latency: TimeInterval
    let timestamp: Date
    
    func withLatency(_ newLatency: TimeInterval) -> TestResult {
        TestResult(
            type: type,
            success: success,
            message: message,
            latency: newLatency,
            timestamp: timestamp
        )
    }
}

enum TestType {
    case connectivity
    case chat
    case vision
    case document
}

struct TestResultRow: View {
    let result: TestResult
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(result.success ? .green : .red)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(result.type.name)
                    .font(.system(size: 11, weight: .medium))
                Text(result.message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(String(format: "%.0fms", result.latency * 1000))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(6)
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(4)
    }
}

extension TestType {
    var name: String {
        switch self {
        case .connectivity: return "连通性"
        case .chat: return "对话"
        case .vision: return "图片"
        case .document: return "文档"
        }
    }
}

// MARK: - Agent 详情面板
struct AgentDetailSheet: View {
    let agent: Agent
    let healthMonitor: AgentHealthMonitor
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            AgentDetailView(agent: agent, healthMonitor: healthMonitor)
                .navigationTitle(agent.name)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
        .frame(width: 550, height: 420)
    }
}

struct AgentDetailView: View {
    let agent: Agent
    let healthMonitor: AgentHealthMonitor
    
    var body: some View {
        TabView {
            OverviewTab(agent: agent, healthMonitor: healthMonitor)
                .tabItem {
                    Label("概览", systemImage: "chart.bar.fill")
                }
            
            RolesTab(agent: agent)
                .tabItem {
                    Label("角色", systemImage: "person.2.fill")
                }
            
            StatsTab(agent: agent, healthMonitor: healthMonitor)
                .tabItem {
                    Label("统计", systemImage: "chart.line.uptrend.xyaxis")
                }
        }
        .padding()
    }
}

struct OverviewTab: View {
    let agent: Agent
    let healthMonitor: AgentHealthMonitor
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text(agent.emoji)
                        .font(.system(size: 40))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name)
                            .font(.title3)
                        Text(agent.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                InfoSection(title: "配置") {
                    InfoRow(label: "Provider", value: agent.provider.displayName)
                    InfoRow(label: "Model", value: agent.model)
                }
                
                InfoSection(title: "能力") {
                    FlowLayout(spacing: 6) {
                        ForEach(agent.capabilities, id: \.self) { cap in
                            Label(cap.displayName, systemImage: cap.icon)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.08))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }
                    }
                }
            }
            .padding()
        }
    }
}

struct RolesTab: View {
    let agent: Agent
    @StateObject private var agentStore = AgentStore.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AgentRole.allCases) { role in
                    RoleToggleRow(
                        role: role,
                        isOn: agentStore.roleProfile(for: agent).contains(role),
                        onToggle: { enabled in
                            agentStore.setRole(role, enabled: enabled, for: agent)
                        }
                    )
                }
            }
            .padding()
        }
    }
}

struct RoleToggleRow: View {
    let role: AgentRole
    let isOn: Bool
    let onToggle: (Bool) -> Void
    
    var body: some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { onToggle($0) }
        )) {
            HStack(spacing: 10) {
                Image(systemName: role.icon)
                    .font(.system(size: 14))
                    .foregroundColor(role.color)
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(role.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Text(role.summary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 6)
    }
}

struct StatsTab: View {
    let agent: Agent
    let healthMonitor: AgentHealthMonitor
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let stats = healthMonitor.stats(for: agent), stats.totalCalls > 0 {
                    StatCardLarge(
                        title: "成功率",
                        value: "\(Int(stats.successRate * 100))%",
                        subtitle: "\(stats.successfulCalls)/\(stats.totalCalls) 成功",
                        color: stats.successRate > 0.9 ? .green : .orange
                    )
                    
                    StatCardLarge(
                        title: "平均响应",
                        value: String(format: "%.2fs", stats.averageLatency),
                        subtitle: "基于 \(stats.totalCalls) 次调用",
                        color: stats.averageLatency < 2.0 ? .green : .orange
                    )
                    
                    if let lastUsed = stats.lastUsedAt {
                        StatCardLarge(
                            title: "最后使用",
                            value: timeAgo(lastUsed),
                            subtitle: lastUsed.formatted(date: .abbreviated, time: .shortened),
                            color: .blue
                        )
                    }
                } else {
                    Text("暂无统计数据")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 150)
                }
            }
            .padding()
        }
    }
    
    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct StatCardLarge: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(color)
            
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(color.opacity(0.05))
        .cornerRadius(8)
    }
}

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            content
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12))
        }
    }
}

// MARK: - 兼容组件（其他视图使用）
struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(color)
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Text(value)
                .font(.system(size: 20, weight: .semibold))
            
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 80, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.05))
        .cornerRadius(8)
    }
}

struct AgentRoleBadge: View {
    let role: AgentRole
    
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: role.icon)
                .font(.system(size: 8))
            Text(role.displayName)
                .font(.system(size: 9))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.05))
        .foregroundColor(.secondary)
        .cornerRadius(4)
    }
}

// MARK: - FlowLayout (Fixed)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        
        // 限制最大宽度避免无限计算
        let maxWidth: CGFloat = 10000
        let proposedWidth = min(proposal.width ?? maxWidth, maxWidth)
        let result = FlowResult(in: proposedWidth, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { continue }
            subview.place(
                at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y),
                proposal: .unspecified
            )
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in width: CGFloat, subviews: Subviews, spacing: CGFloat) {
            // 确保最小有效宽度，避免约束循环
            let minWidth: CGFloat = 1
            let availableWidth = max(width, minWidth)
            
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            var maxLineWidth: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                // 限制单个视图最大宽度
                let viewWidth = min(size.width, availableWidth)
                let viewHeight = size.height
                
                // 检查是否需要换行
                if currentX + viewWidth > availableWidth && currentX > 0 {
                    maxLineWidth = max(maxLineWidth, currentX - spacing)
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                
                positions.append(CGPoint(x: currentX, y: currentY))
                currentX += viewWidth + spacing
                lineHeight = max(lineHeight, viewHeight)
            }
            
            maxLineWidth = max(maxLineWidth, max(0, currentX - spacing))
            let finalWidth = width > 0 ? width : maxLineWidth
            // 确保返回有效尺寸
            self.size = CGSize(
                width: max(finalWidth, minWidth),
                height: max(currentY + lineHeight, 0)
            )
        }
    }
}

// MARK: - 预览
#Preview {
    AgentDashboardView()
}
