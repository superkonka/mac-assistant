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
            Text(agent.emoji)
                .font(.title2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))

                    if agent.isDefault {
                        inlineLabel("默认主")
                    }

                    if isCurrentMain {
                        inlineLabel("当前主会话", tint: .blue)
                    }

                    if isPlannerPreferred {
                        inlineLabel("Planner", tint: .orange)
                    }
                }

                Text(agent.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                Text("\(agent.provider.displayName) • \(agent.model)")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                FlowLayout(spacing: 6) {
                    ForEach(roleProfile.sortedRoles) { role in
                        AgentRoleBadge(role: role)
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    if !isCurrentMain && roleProfile.contains(.primaryChat) {
                        Button("切到主会话") {
                            onSwitchCurrent()
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }

                    if !agent.isDefault {
                        Button("设默认") {
                            onSetDefault()
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }

                HStack(spacing: 8) {
                    if !isPlannerPreferred {
                        Button("设为 Planner") {
                            onSetPlanner()
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }

                    Menu("角色") {
                        ForEach(AgentRole.allCases) { role in
                            Button {
                                onToggleRole(role, !roleProfile.contains(role))
                            } label: {
                                HStack {
                                    Text(role.displayName)
                                    Spacer()
                                    if roleProfile.contains(role) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    .font(.caption)

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func inlineLabel(_ text: String, tint: Color = .green) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14))
            .foregroundColor(tint)
            .cornerRadius(4)
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
