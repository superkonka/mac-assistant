import SwiftUI

struct TaskSessionTabsView: View {
    let sessions: [AgentTaskSession]
    let selectedSessionID: String?
    let onToggleSelection: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessions) { session in
                    TaskSessionTabItem(
                        session: session,
                        isSelected: session.id == selectedSessionID,
                        onTap: { onToggleSelection(session.id) }
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }
}

struct TaskSessionInspectorPanel: View {
    let session: AgentTaskSession
    var onClose: (() -> Void)? = nil
    var onResume: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summarySection

                    if session.canResume {
                        actionsSection
                    }

                    detailsGrid
                    requestSection
                    attachmentsSection
                    runtimeSection
                    transcriptSection
                    resultSection
                }
                .padding(16)
            }
            .frame(maxHeight: 360)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppColors.controlBackground.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(session.status.taskBorderColor.opacity(0.9), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: session.status.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(session.status.taskAccentColor)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(session.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    Text(session.status.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(session.status.taskAccentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(session.status.taskAccentColor.opacity(0.12))
                        )
                }

                Text("更新时间 \(session.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if session.status == .running {
                ProgressView()
                    .controlSize(.small)
            }

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("状态摘要")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            Text(session.statusSummary)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(session.status.taskBackgroundColor)
                )
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 10) {
            if let onResume {
                Button(action: onResume) {
                    Text(session.status == .waitingUser ? "重新检查" : "继续处理")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Text(resumeDescription)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var detailsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("任务信息")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 180), spacing: 12, alignment: .top)
                ],
                alignment: .leading,
                spacing: 12
            ) {
                TaskSessionDetailField(title: "任务 ID", value: session.id)
                TaskSessionDetailField(title: "意图", value: session.intentName)
                TaskSessionDetailField(title: "主会话 Agent", value: session.mainAgentName ?? "未记录")
                TaskSessionDetailField(title: "执行 Agent", value: session.delegateAgentName ?? "未记录")
                TaskSessionDetailField(title: "执行 Agent ID", value: session.delegateAgentID ?? "未记录")
                TaskSessionDetailField(title: "创建时间", value: formatted(session.createdAt))
                TaskSessionDetailField(title: "更新时间", value: formatted(session.updatedAt))
                TaskSessionDetailField(title: "主消息 ID", value: session.linkedMainMessageID?.uuidString ?? "未关联")
                TaskSessionDetailField(title: "消息数", value: "\(session.messages.count)")
                TaskSessionDetailField(title: "详情展开状态", value: session.isExpanded ? "已展开" : "已折叠")
                TaskSessionDetailField(title: "可恢复", value: session.canResume ? "是" : "否")
                TaskSessionDetailField(title: "上次回查", value: session.lastReconciledAt.map(formatted) ?? "未回查")
            }
        }
    }

    private var requestSection: some View {
        TaskSessionDetailBlock(
            title: "原始请求",
            content: session.originalRequest
        )
    }

    @ViewBuilder
    private var attachmentsSection: some View {
        let images = session.inputImages ?? []
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("输入附件")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(images, id: \.self) { path in
                        TaskSessionPathRow(path: path)
                    }
                }
            }
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("运行上下文")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 180), spacing: 12, alignment: .top)
                ],
                alignment: .leading,
                spacing: 12
            ) {
                TaskSessionDetailField(title: "Gateway Session Key", value: session.gatewaySessionKey ?? "未记录")
                TaskSessionDetailField(title: "Gateway Run ID", value: session.gatewayRunID ?? "未记录")
                TaskSessionDetailField(title: "Conversation Session ID", value: session.gatewayConversationSessionID ?? "未记录")
                TaskSessionDetailField(title: "请求启动时间", value: session.requestStartedAt.map(formatted) ?? "未记录")
            }

            TaskSessionDetailBlock(
                title: "最近一次 Assistant 输出",
                content: session.latestAssistantText ?? "未记录"
            )
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("任务详情")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            if session.messages.isEmpty {
                Text("当前还没有写入子任务详情。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.03))
                    )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.messages) { message in
                        TaskSessionInspectorMessageRow(message: message)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let resultSummary = session.resultSummary, !resultSummary.isEmpty {
            TaskSessionDetailBlock(
                title: "结果摘要",
                content: resultSummary,
                accent: .green,
                backgroundOpacity: 0.09
            )
        }

        if let errorMessage = session.errorMessage, !errorMessage.isEmpty {
            TaskSessionDetailBlock(
                title: session.status == .failed ? "失败原因" : "状态补充",
                content: errorMessage,
                accent: session.status == .waitingUser ? .yellow : .orange,
                backgroundOpacity: 0.09
            )
        }
    }

    private var resumeDescription: String {
        if let lastReconciledAt = session.lastReconciledAt {
            return "上次检查 \(lastReconciledAt.formatted(date: .omitted, time: .shortened))"
        }
        return "本地已保留上下文，可继续回查"
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct TaskSessionTabItem: View {
    let session: AgentTaskSession
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: session.status.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(session.status.taskAccentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(session.status.displayName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if session.status == .running {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minWidth: 138, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(isSelected ? session.status.taskBackgroundColor : Color.black.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(
                        isSelected ? session.status.taskBorderColor : Color.black.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct TaskSessionDetailField: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.03))
        )
    }
}

private struct TaskSessionDetailBlock: View {
    let title: String
    let content: String
    var accent: Color = .secondary
    var backgroundOpacity: Double = 0.06

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent)

            Text(content)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(accent.opacity(backgroundOpacity))
                )
        }
    }
}

private struct TaskSessionInspectorMessageRow: View {
    let message: TaskSessionMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(roleTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(roleColor)

                if let agentName = message.agentName, !agentName.isEmpty {
                    Text(agentName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Text(message.content)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.03))
        )
    }

    private var roleTitle: String {
        switch message.role {
        case .user:
            return "请求"
        case .assistant:
            return "执行"
        case .system:
            return "状态"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .user:
            return .blue
        case .assistant:
            return .green
        case .system:
            return .secondary
        }
    }
}

private struct TaskSessionPathRow: View {
    let path: String

    var body: some View {
        Text(path)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.primary)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.03))
            )
    }
}

private extension TaskSessionStatus {
    var taskAccentColor: Color {
        switch self {
        case .queued:
            return .secondary
        case .running:
            return .blue
        case .partial:
            return .teal
        case .waitingUser:
            return .yellow
        case .completed:
            return .green
        case .failed:
            return .orange
        }
    }

    var taskBackgroundColor: Color {
        switch self {
        case .queued:
            return Color.gray.opacity(0.08)
        case .running:
            return Color.blue.opacity(0.09)
        case .partial:
            return Color.teal.opacity(0.1)
        case .waitingUser:
            return Color.yellow.opacity(0.12)
        case .completed:
            return Color.green.opacity(0.09)
        case .failed:
            return Color.orange.opacity(0.12)
        }
    }

    var taskBorderColor: Color {
        switch self {
        case .queued:
            return Color.gray.opacity(0.22)
        case .running:
            return Color.blue.opacity(0.28)
        case .partial:
            return Color.teal.opacity(0.3)
        case .waitingUser:
            return Color.yellow.opacity(0.34)
        case .completed:
            return Color.green.opacity(0.26)
        case .failed:
            return Color.orange.opacity(0.32)
        }
    }
}
