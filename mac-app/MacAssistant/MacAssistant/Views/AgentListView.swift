//
//  AgentListView.swift
//  MacAssistant
//

import SwiftUI

struct AgentListView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var agentStore = AgentStore.shared
    @State private var showingWizard = false
    @State private var selectedGap: CapabilityGap?
    @State private var showingDeleteConfirm = false
    @State private var agentToDelete: Agent?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header

                Divider()

                List {
                    Section(header: Text("角色分工").font(.caption)) {
                        roleOverview
                    }

                    Section(header: Text("所有 Agents").font(.caption)) {
                        ForEach(agentStore.agents) { agent in
                            AgentRow(
                                agent: agent,
                                roleProfile: agentStore.roleProfile(for: agent),
                                isCurrentMain: agentStore.currentAgent?.id == agent.id,
                                isPlannerPreferred: agentStore.plannerPreferredAgent?.id == agent.id,
                                onSwitchCurrent: {
                                    agentStore.switchToAgent(agent)
                                },
                                onSetDefault: {
                                    agentStore.setDefaultAgent(agent)
                                },
                                onSetPlanner: {
                                    agentStore.setRole(.planner, enabled: true, for: agent)
                                    agentStore.setPlannerPreferredAgent(agent)
                                },
                                onToggleRole: { role, enabled in
                                    agentStore.setRole(role, enabled: enabled, for: agent)
                                },
                                onDelete: {
                                    agentToDelete = agent
                                    showingDeleteConfirm = true
                                }
                            )
                        }
                    }

                    Section(header: Text("可用能力").font(.caption)) {
                        FlowLayout(spacing: 8) {
                            ForEach(agentStore.allCapabilities, id: \.self) { capability in
                                AgentCapabilityBadge(capability: capability)
                            }
                        }
                    }
                }
                .listStyle(.inset)

                Spacer(minLength: 60)
            }

            VStack {
                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                        .background(
                            Circle()
                                .fill(Color(NSColor.windowBackgroundColor))
                                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                        )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 620, height: 640)
        .sheet(isPresented: $showingWizard) {
            AgentConfigurationWizard(gap: selectedGap) { newAgent in
                if agentStore.shouldAutoAdoptAsCurrent(newAgent) {
                    agentStore.switchToAgent(newAgent)
                }
            }
        }
        .alert("确认删除", isPresented: $showingDeleteConfirm, presenting: agentToDelete) { agent in
            Button("删除", role: .destructive) {
                agentStore.deleteAgent(agent)
            }
            Button("取消", role: .cancel) {}
        } message: { agent in
            Text("确定要删除 Agent 「\(agent.name)」吗？此操作不可撤销。")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent 管理")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(agentStore.agents.count) 个 Agents，当前主会话 / Planner / 子任务 / 回退角色已拆开管理")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { showingWizard = true }) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.blue)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("添加新 Agent")
        }
        .padding()
    }

    private var roleOverview: some View {
        VStack(spacing: 10) {
            RoleLaneCard(
                title: "主会话",
                icon: "text.bubble",
                accent: .blue,
                detail: "当前主对话与默认主 Agent",
                agents: agentStore.primaryChatAgents(usableOnly: false),
                selectedAgentID: agentStore.currentAgent?.id
            )

            RoleLaneCard(
                title: "Planner",
                icon: "point.topleft.down.curvedto.point.bottomright.up",
                accent: .orange,
                detail: "秘书层 / 意图分析 / 调度",
                agents: agentStore.plannerAgents(usableOnly: false),
                selectedAgentID: agentStore.plannerPreferredAgent?.id
            )

            RoleLaneCard(
                title: "子任务池",
                icon: "square.stack.3d.up",
                accent: .green,
                detail: "独立 side task worker，不影响主会话",
                agents: agentStore.subtaskWorkerAgents(usableOnly: false),
                selectedAgentID: nil
            )

            RoleLaneCard(
                title: "回退池",
                icon: "arrow.trianglehead.clockwise",
                accent: .purple,
                detail: "主 Agent 失败时参与自愈回退",
                agents: agentStore.fallbackAgents(usableOnly: false),
                selectedAgentID: nil
            )

            RoleLaneCard(
                title: "仅手动",
                icon: "hand.raised",
                accent: .gray,
                detail: "不会参与自动路由，只在手动指定时使用",
                agents: agentStore.manualOnlyAgents(usableOnly: false),
                selectedAgentID: nil
            )
        }
        .padding(.vertical, 4)
    }
}

struct AgentRow: View {
    let agent: Agent
    let roleProfile: AgentRoleProfile
    let isCurrentMain: Bool
    let isPlannerPreferred: Bool
    let onSwitchCurrent: () -> Void
    let onSetDefault: () -> Void
    let onSetPlanner: () -> Void
    let onToggleRole: (AgentRole, Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // MARK: 左侧 - Agent 基本信息
            Text(agent.emoji)
                .font(.system(size: 28))
                .frame(width: 36, height: 36)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                // 名称行
                Text(agent.name)
                    .font(.system(size: 14, weight: .semibold))

                // 描述
                Text(agent.description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // 提供商信息
                Text("\(agent.provider.displayName) • \(agent.model)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))

                // 角色标签
                FlowLayout(spacing: 6) {
                    ForEach(roleProfile.sortedRoles) { role in
                        AgentRoleBadge(role: role)
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 16)

            // MARK: 右侧 - 状态与操作
            VStack(alignment: .trailing, spacing: 10) {
                // 状态标签组
                HStack(spacing: 6) {
                    if agent.isDefault {
                        StatusBadge(text: "默认主", color: .green)
                    }
                    if isCurrentMain {
                        StatusBadge(text: "当前主会话", color: .blue)
                    }
                    if isPlannerPreferred {
                        StatusBadge(text: "Planner", color: .orange)
                    }
                }

                // 操作按钮组
                HStack(spacing: 6) {
                    // 快速操作按钮
                    if !isCurrentMain && roleProfile.contains(.primaryChat) {
                        IconButton(
                            icon: "arrow.right.circle",
                            tooltip: "切到主会话",
                            action: onSwitchCurrent
                        )
                    }

                    if !agent.isDefault {
                        IconButton(
                            icon: "star.circle",
                            tooltip: "设为默认",
                            action: onSetDefault
                        )
                    }

                    if !isPlannerPreferred && roleProfile.contains(.planner) {
                        IconButton(
                            icon: "point.topleft.down.curvedto.point.bottomright.up.circle",
                            tooltip: "设为 Planner",
                            action: onSetPlanner
                        )
                    }

                    Divider()
                        .frame(height: 20)
                        .padding(.horizontal, 2)

                    // 角色 Menu
                    Menu {
                        ForEach(AgentRole.allCases) { role in
                            Button {
                                onToggleRole(role, !roleProfile.contains(role))
                            } label: {
                                HStack {
                                    Image(systemName: role.icon)
                                        .font(.system(size: 12))
                                    Text(role.displayName)
                                    Spacer()
                                    if roleProfile.contains(role) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person.2.badge.gearshape")
                                .font(.system(size: 12))
                            Text("角色")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(6)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    // 删除按钮
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.8))
                            .frame(width: 28, height: 28)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("删除 Agent")
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }
}

// MARK: - 辅助组件

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

private struct IconButton: View {
    let icon: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

private struct RoleLaneCard: View {
    let title: String
    let icon: String
    let accent: Color
    let detail: String
    let agents: [Agent]
    let selectedAgentID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(accent)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(agents.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(accent)
            }

            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            if agents.isEmpty {
                Text("暂无分配")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(agents, id: \.id) { agent in
                        Text(agent.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill((selectedAgentID == agent.id ? accent : Color.black).opacity(selectedAgentID == agent.id ? 0.14 : 0.05))
                            )
                            .foregroundColor(selectedAgentID == agent.id ? accent : .primary)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(accent.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.12), lineWidth: 1)
        )
    }
}

struct AgentRoleBadge: View {
    let role: AgentRole

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: role.icon)
                .font(.system(size: 9, weight: .medium))
            Text(role.displayName)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.gray.opacity(0.12))
        .foregroundColor(.secondary)
        .cornerRadius(4)
    }
}

struct AgentCapabilityBadge: View {
    let capability: Capability

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: capability.icon)
                .font(.system(size: 10))
            Text(capability.displayName)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.1))
        .foregroundColor(.secondary)
        .cornerRadius(4)
    }
}

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
