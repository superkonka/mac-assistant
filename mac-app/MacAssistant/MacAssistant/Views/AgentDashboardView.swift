//
//  AgentDashboardView.swift
//  MacAssistant
//
//  全新 Agent 管理仪表盘 - 优化版
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
            $0.description.localizedCaseInsensitiveContains(searchText) ||
            $0.provider.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var onlineAgents: [Agent] {
        filteredAgents.filter { healthMonitor.status(for: $0)?.isOnline == true }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部概览栏
                OverviewBar(
                    totalAgents: agentStore.agents.count,
                    onlineCount: onlineAgents.count,
                    todayCalls: healthMonitor.totalCallsToday,
                    avgLatency: healthMonitor.averageLatency
                )
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                // 工具栏
                HStack(spacing: 16) {
                    // 搜索框
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("搜索 Agent...", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(8)
                    .frame(width: 200)
                    
                    Spacer()
                    
                    // 视图切换
                    Picker("视图", selection: $selectedViewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: iconForMode(mode))
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    
                    Spacer()
                    
                    // 添加按钮
                    Button(action: { showingWizard = true }) {
                        Label("新建 Agent", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                
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
            }
            .navigationTitle("Agent 管理")
            .navigationSubtitle("\(onlineAgents.count)/\(agentStore.agents.count) 在线")
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
        .frame(minWidth: 900, minHeight: 600)
    }
    
    private func iconForMode(_ mode: ViewMode) -> String {
        switch mode {
        case .grid: return "square.grid.2x2"
        case .pipeline: return "arrow.right.arrow.left"
        case .list: return "list.bullet"
        }
    }
}

// MARK: - 概览栏
struct OverviewBar: View {
    let totalAgents: Int
    let onlineCount: Int
    let todayCalls: Int
    let avgLatency: TimeInterval
    
    var body: some View {
        HStack(spacing: 24) {
            StatCard(
                icon: "cpu",
                title: "Agents",
                value: "\(totalAgents)",
                subtitle: "\(onlineCount) 在线",
                color: .blue
            )
            
            StatCard(
                icon: "checkmark.shield.fill",
                title: "健康度",
                value: "\(Int(Double(onlineCount) / Double(max(totalAgents, 1)) * 100))%",
                subtitle: onlineCount == totalAgents ? "全部正常" : "\(totalAgents - onlineCount) 离线",
                color: onlineCount == totalAgents ? .green : .orange
            )
            
            StatCard(
                icon: "bubble.left.and.bubble.right.fill",
                title: "今日调用",
                value: "\(todayCalls)",
                subtitle: "较昨日 +12%",
                color: .purple
            )
            
            StatCard(
                icon: "bolt.fill",
                title: "平均响应",
                value: String(format: "%.1fs", avgLatency),
                subtitle: avgLatency < 1.0 ? "快速" : avgLatency < 3.0 ? "正常" : "较慢",
                color: avgLatency < 3.0 ? .green : .orange
            )
            
            Spacer()
        }
    }
}

struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(color)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(value)
                .font(.system(size: 24, weight: .bold))
            
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 100, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
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
            GridItem(.adaptive(minimum: 280, maximum: 320), spacing: 16)
        ], spacing: 16) {
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

// MARK: - Agent 卡片
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
    
    private var statusColor: Color {
        status?.color ?? .gray
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 头部
            HStack(spacing: 12) {
                // 头像 + 状态指示
                ZStack(alignment: .bottomTrailing) {
                    Text(agent.emoji)
                        .font(.system(size: 36))
                        .frame(width: 56, height: 56)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(12)
                    
                    // 状态指示点
                    Circle()
                        .fill(statusColor)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .offset(x: 4, y: 4)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.system(size: 15, weight: .semibold))
                        
                        if agent.isDefault {
                            DefaultBadge()
                        }
                    }
                    
                    Text("\(agent.provider.displayName) · \(agent.model)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 菜单
                Menu {
                    let canUse = AgentStore.shared.canUse(agent)
                    Button("设为当前对话") {
                        if canUse {
                            AgentStore.shared.switchToAgent(agent)
                        }
                    }
                    .disabled(!canUse)
                    
                    if !agent.isDefault {
                        Button("设为默认") {
                            if canUse {
                                AgentStore.shared.setDefaultAgent(agent)
                            }
                        }
                        .disabled(!canUse)
                    }
                    
                    Divider()
                    
                    Button("快速测试...") {
                        showingQuickTest = true
                    }
                    
                    Button("编辑配置...") {
                        onTap()
                    }
                    
                    Divider()
                    
                    Button("删除", role: .destructive) {
                        onDelete()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
            
            Divider()
            
            // 角色标签
            FlowLayout(spacing: 6) {
                ForEach(agentRoles, id: \.self) { role in
                    RoleTag(role: role, isActive: true)
                }
            }
            
            // 能力图标
            HStack(spacing: 8) {
                ForEach(agent.capabilities.prefix(4), id: \.self) { cap in
                    CapabilityIcon(capability: cap)
                }
            }
            
            Divider()
            
            // 统计信息
            HStack(spacing: 16) {
                if let stats = stats {
                    StatItem(icon: "bubble.fill", value: "\(stats.totalCalls)", label: "调用")
                    StatItem(icon: "checkmark.circle.fill", value: "\(Int(stats.successRate * 100))%", label: "成功率")
                    StatItem(icon: "clock.fill", value: String(format: "%.1fs", stats.averageLatency), label: "平均")
                } else {
                    StatItem(icon: "bubble.fill", value: "--", label: "调用")
                    StatItem(icon: "checkmark.circle.fill", value: "--", label: "成功率")
                    StatItem(icon: "clock.fill", value: "--", label: "平均")
                }
            }
            
            // 底部操作
            HStack(spacing: 8) {
                Button {
                    showingQuickTest = true
                } label: {
                    Label("测试", systemImage: "bolt.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isOnline)
                
                Spacer()
                
                let canUse = AgentStore.shared.canUse(agent)
                if isOnline && canUse {
                    Button {
                        AgentStore.shared.switchToAgent(agent)
                    } label: {
                        Text("设为当前")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Text(isOnline ? "不可用" : "离线")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(statusColor.opacity(0.3), lineWidth: agentStore.currentAgent?.id == agent.id ? 2 : 0)
        )
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
}

struct DefaultBadge: View {
    var body: some View {
        Text("默认")
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.blue.opacity(0.15))
            .foregroundColor(.blue)
            .cornerRadius(4)
    }
}

struct RoleTag: View {
    let role: AgentRole
    let isActive: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: role.icon)
                .font(.system(size: 9))
            Text(role.displayName)
                .font(.system(size: 10))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? role.color.opacity(0.15) : Color.gray.opacity(0.1))
        .foregroundColor(isActive ? role.color : .secondary)
        .cornerRadius(6)
    }
}

// 为了兼容性保留的别名
struct AgentRoleBadge: View {
    let role: AgentRole
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: role.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(role.displayName)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.05))
        .foregroundColor(.secondary)
        .clipShape(Capsule())
    }
}

struct CapabilityIcon: View {
    let capability: Capability
    
    var body: some View {
        Image(systemName: capability.icon)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .help(capability.displayName)
    }
}

struct StatItem: View {
    let icon: String
    let value: String
    let label: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 流水线视图
struct PipelineView: View {
    let agents: [Agent]
    let healthMonitor: AgentHealthMonitor
    
    var body: some View {
        VStack(spacing: 24) {
            // Planner 池
            PipelineSection(
                title: "Planner (主对话)",
                icon: "point.topleft.down.curvedto.point.bottomright.up",
                color: .blue,
                agents: agents.filter { AgentStore.shared.hasRole(.planner, for: $0) },
                healthMonitor: healthMonitor
            )
            
            ArrowDown()
            
            // 子任务池
            PipelineSection(
                title: "子任务池",
                icon: "square.stack.3d.up",
                color: .green,
                agents: agents.filter { AgentStore.shared.hasRole(.subtaskWorker, for: $0) },
                healthMonitor: healthMonitor
            )
            
            ArrowDown()
            
            // 回退池
            PipelineSection(
                title: "回退池",
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text("\(agents.count)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            if agents.isEmpty {
                Text("暂无 Agent")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
            } else {
                FlowLayout(spacing: 8) {
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
        .padding(16)
        .background(color.opacity(0.03))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.15), lineWidth: 1)
        )
    }
}

struct PipelineAgentChip: View {
    let agent: Agent
    let status: AgentHealthStatus?
    let isCurrent: Bool
    
    var body: some View {
        HStack(spacing: 6) {
            Text(agent.emoji)
                .font(.system(size: 14))
            Text(agent.name)
                .font(.system(size: 12))
            
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
            }
            
            Circle()
                .fill(status?.color ?? .gray)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrent ? Color.blue : Color.clear, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

struct ArrowDown: View {
    var body: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 20))
            .foregroundColor(.secondary.opacity(0.5))
    }
}

// MARK: - 紧凑列表视图
struct CompactListView: View {
    let agents: [Agent]
    let healthMonitor: AgentHealthMonitor
    
    var body: some View {
        LazyVStack(spacing: 8) {
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
        HStack(spacing: 12) {
            // 状态指示
            Circle()
                .fill(status?.color ?? .gray)
                .frame(width: 8, height: 8)
            
            Text(agent.emoji)
                .font(.system(size: 20))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 13, weight: .medium))
                Text("\(agent.provider.displayName) · \(agent.model)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 角色标签
            HStack(spacing: 4) {
                ForEach(AgentStore.shared.roleProfile(for: agent).sortedRoles.prefix(2), id: \.self) { role in
                    Text(role.displayName)
                        .font(.system(size: 9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(role.color.opacity(0.1))
                        .foregroundColor(role.color)
                        .cornerRadius(4)
                }
            }
            
            // 统计
            if let stats = stats {
                HStack(spacing: 12) {
                    Text("\(stats.totalCalls)")
                        .font(.system(size: 11, weight: .medium))
                    Text("\(Int(stats.successRate * 100))%")
                        .font(.system(size: 11))
                        .foregroundColor(stats.successRate > 0.9 ? .green : .orange)
                }
                .frame(width: 80)
            }
            
            // 操作
            HStack(spacing: 8) {
                let canUse = AgentStore.shared.canUse(agent)
                Button {
                    AgentStore.shared.switchToAgent(agent)
                } label: {
                    Text("设为当前")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(status?.isOnline != true || !canUse)
                .help(canUse ? "切换到此 Agent" : "Agent 未配置或不可用")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Agent 健康监控 (简化版)
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
    
    // 模拟数据
    init() {
        // 实际实现会定时检测
    }
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
    
    var icon: String {
        switch self {
        case .online: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .offline: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
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
                .navigationTitle("快速测试: \(agent.name)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
        .frame(width: 500, height: 400)
    }
}

struct QuickTestPanel: View {
    let agent: Agent
    @State private var testResults: [TestResult] = []
    @State private var isRunning = false
    
    var body: some View {
        VStack(spacing: 16) {
            Text("选择要测试的能力")
                .font(.headline)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                TestButton(
                    icon: "network",
                    title: "连通性",
                    description: "测试 API 连接",
                    color: .blue
                ) {
                    runTest(type: .connectivity)
                }
                
                TestButton(
                    icon: "bubble.left.fill",
                    title: "对话",
                    description: "发送测试消息",
                    color: .green
                ) {
                    runTest(type: .chat)
                }
                
                TestButton(
                    icon: "photo.fill",
                    title: "图片",
                    description: "测试图片分析",
                    color: .purple,
                    isDisabled: !agent.supports(.vision)
                ) {
                    runTest(type: .vision)
                }
                
                TestButton(
                    icon: "doc.text.fill",
                    title: "文档",
                    description: "测试文档处理",
                    color: .orange,
                    isDisabled: !agent.supports(.documentAnalysis)
                ) {
                    runTest(type: .document)
                }
            }
            
            Divider()
            
            // 测试结果
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(testResults) { result in
                        TestResultRow(result: result)
                    }
                }
            }
        }
        .padding()
    }
    
    private func runTest(type: TestType) {
        // 实际测试逻辑
    }
}

struct TestButton: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    var isDisabled: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(isDisabled ? .secondary : color)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(color.opacity(isDisabled ? 0.03 : 0.1))
            .cornerRadius(12)
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
}

enum TestType {
    case connectivity
    case chat
    case vision
    case document
    
    var name: String {
        switch self {
        case .connectivity: return "连通性"
        case .chat: return "对话"
        case .vision: return "图片"
        case .document: return "文档"
        }
    }
}

struct TestResultRow: View {
    let result: TestResult
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(result.success ? .green : .red)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(result.type.name)
                    .font(.system(size: 12, weight: .medium))
                Text(result.message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(String(format: "%.0fms", result.latency * 1000))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
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
        .frame(width: 600, height: 500)
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
            VStack(alignment: .leading, spacing: 20) {
                // 基本信息
                HStack(spacing: 16) {
                    Text(agent.emoji)
                        .font(.system(size: 48))
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.name)
                            .font(.title2)
                        Text(agent.description)
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                // 配置信息
                InfoSection(title: "配置") {
                    InfoRow(label: "Provider", value: agent.provider.displayName)
                    InfoRow(label: "Model", value: agent.model)
                    InfoRow(label: "Agent ID", value: agent.id)
                }
                
                // 能力列表
                InfoSection(title: "能力") {
                    FlowLayout(spacing: 8) {
                        ForEach(agent.capabilities, id: \.self) { cap in
                            Label(cap.displayName, systemImage: cap.icon)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(6)
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
            VStack(alignment: .leading, spacing: 16) {
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
            HStack(spacing: 12) {
                Image(systemName: role.icon)
                    .font(.system(size: 16))
                    .foregroundColor(role.color)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.displayName)
                        .font(.system(size: 14, weight: .medium))
                    Text(role.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 8)
    }
}

struct StatsTab: View {
    let agent: Agent
    let healthMonitor: AgentHealthMonitor
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let stats = healthMonitor.stats(for: agent) {
                    // 成功率
                    StatCardLarge(
                        title: "成功率",
                        value: "\(Int(stats.successRate * 100))%",
                        subtitle: "\(stats.successfulCalls)/\(stats.totalCalls) 成功调用",
                        color: stats.successRate > 0.9 ? .green : .orange
                    )
                    
                    // 响应时间
                    StatCardLarge(
                        title: "平均响应时间",
                        value: String(format: "%.2fs", stats.averageLatency),
                        subtitle: "基于 \(stats.totalCalls) 次调用",
                        color: stats.averageLatency < 2.0 ? .green : .orange
                    )
                    
                    // 最后使用
                    if let lastUsed = stats.lastUsedAt {
                        StatCardLarge(
                            title: "最后使用",
                            value: timeAgo(lastUsed),
                            subtitle: lastUsed.formatted(),
                            color: .blue
                        )
                    }
                } else {
                    Text("暂无统计数据")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(color)
            
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(color.opacity(0.05))
        .cornerRadius(12)
    }
}

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
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
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
        }
        .font(.system(size: 12))
    }
}

// MARK: - FlowLayout (复用)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
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
            let availableWidth = width > 0 ? width : .greatestFiniteMagnitude
            
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            var maxLineWidth: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if currentX + size.width > availableWidth, currentX > 0 {
                    maxLineWidth = max(maxLineWidth, currentX - spacing)
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                
                positions.append(CGPoint(x: currentX, y: currentY))
                currentX += size.width + spacing
                lineHeight = max(lineHeight, size.height)
            }
            
            maxLineWidth = max(maxLineWidth, max(0, currentX - spacing))
            let resolvedWidth = width > 0 ? width : maxLineWidth
            self.size = CGSize(width: resolvedWidth, height: currentY + lineHeight)
        }
    }
}

// MARK: - 预览
#Preview {
    AgentDashboardView()
}
