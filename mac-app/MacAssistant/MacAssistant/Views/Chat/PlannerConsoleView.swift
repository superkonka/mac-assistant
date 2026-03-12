import SwiftUI

struct PlannerConsoleView: View {
    @ObservedObject private var preferences = UserPreferenceStore.shared
    @ObservedObject private var agentStore = AgentStore.shared
    @ObservedObject private var shadowMonitor = PlannerShadowMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryCard
            controlsCard
            moduleDeck
            shadowLogSection
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Planner Console")
                .font(.system(size: 15, weight: .semibold))

            Text(summaryText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.green.opacity(0.18), lineWidth: 1)
        )
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Planner 模式")
                .font(.system(size: 13, weight: .semibold))

            Picker(
                "主 Planner",
                selection: Binding(
                    get: { preferences.plannerPrimaryStrategy },
                    set: { preferences.plannerPrimaryStrategy = $0 }
                )
            ) {
                ForEach(PlannerPrimaryStrategy.allCases) { strategy in
                    Text(strategy.displayName).tag(strategy)
                }
            }
            .pickerStyle(.segmented)

            Text(preferences.plannerPrimaryStrategy.summary)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Planner Agent")
                        .font(.system(size: 13, weight: .semibold))
                    Text("用于影子判定，或在“Planner Agent 接管”模式下直接担任主意图分析器。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 12)

                Picker(
                    "Planner Agent",
                    selection: Binding(
                        get: { preferences.plannerPreferredAgentID ?? "__auto__" },
                        set: { newValue in
                            preferences.plannerPreferredAgentID = (newValue == "__auto__") ? nil : newValue
                        }
                    )
                ) {
                    Text("自动选择").tag("__auto__")
                    ForEach(agentStore.usableAgents, id: \.id) { agent in
                        Text("\(agent.emoji) \(agent.name)").tag(agent.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
                .disabled(agentStore.usableAgents.isEmpty)
            }

            Toggle(isOn: Binding(
                get: { preferences.plannerShadowEnabled },
                set: { preferences.plannerShadowEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("启用影子对比")
                        .font(.system(size: 13, weight: .semibold))
                    Text("额外跑一条备用 planner，只记录 diff，不直接接管主流程。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private var moduleDeck: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("链路模块")
                .font(.system(size: 13, weight: .semibold))

            moduleRow(
                title: "Planner",
                icon: "point.topleft.down.curvedto.point.bottomright.up",
                status: preferences.plannerPrimaryStrategy.displayName,
                detail: effectivePlannerAgentText
            )
            moduleRow(
                title: "Dispatcher",
                icon: "arrow.triangle.branch",
                status: "已启用",
                detail: "负责决定主会话、side task 或并行子任务。"
            )
            moduleRow(
                title: "Link Research",
                icon: "link.badge.plus",
                status: "并行抓取",
                detail: "URL 研究类请求会拆成主回答 + 链接抓取子任务。"
            )
            moduleRow(
                title: "Result Collector",
                icon: "tray.full",
                status: "已启用",
                detail: "等待主回答和 side task 完成后，再补充研究结果。"
            )
            moduleRow(
                title: "Local System Guard",
                icon: "desktopcomputer",
                status: "受保护",
                detail: "本地系统操作只在高置信度时才会截走，不再乱吃普通对话。"
            )
            moduleRow(
                title: "Fallback / Self-heal",
                icon: "cross.case",
                status: "已启用",
                detail: "负责 Agent 回退、Kimi 登录恢复和 OpenClaw 自愈。"
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.03))
        )
    }

    private func moduleRow(title: String, icon: String, status: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.blue)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))

                    Text(status)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule())
                }

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private var shadowLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最近影子判定")
                        .font(.system(size: 13, weight: .semibold))
                    Text("这里记录主 planner 和影子 planner 的差异，方便后续切换更便宜或更新的模型。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !shadowMonitor.entries.isEmpty {
                    Button("清空记录") {
                        shadowMonitor.clear()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
                }
            }

            if shadowMonitor.entries.isEmpty {
                Text(preferences.plannerShadowEnabled ? "暂无影子判定记录。开启后发起几条消息，这里会出现 match / diff 结果。" : "影子判定当前未启用。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(shadowMonitor.entries.prefix(6))) { entry in
                        plannerShadowLogRow(entry)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.03))
        )
    }

    private func plannerShadowLogRow(_ entry: PlannerShadowLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(entry.matched ? "MATCH" : "DIFF")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(entry.matched ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((entry.matched ? Color.green : Color.orange).opacity(0.12))
                    .clipShape(Capsule())

                Text(entry.requestPreview)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Spacer()

                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Text("主: \(entry.primaryPlannerID) · \(entry.primaryDecision)")
                .font(.system(size: 11))
            Text("影: \(entry.shadowPlannerID) · \(entry.shadowDecision)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke((entry.matched ? Color.green : Color.orange).opacity(0.14), lineWidth: 1)
        )
    }

    private var effectivePlannerAgentText: String {
        if let agentID = preferences.plannerPreferredAgentID,
           let agent = agentStore.usableAgents.first(where: { $0.id == agentID }) {
            return "当前绑定到 \(agent.displayName)。"
        }
        return "当前为自动选择。"
    }

    private var summaryText: String {
        let primary = preferences.plannerPrimaryStrategy.displayName
        let shadow = preferences.plannerShadowEnabled ? "已开启影子对比" : "未开启影子对比"
        return "这里管理意图分析与调度链路。当前主策略：\(primary)。\(shadow) 你可以把更便宜或更新的模型绑定成 Planner Agent，专门优化这条链路，而不影响主回答模型。"
    }
}
