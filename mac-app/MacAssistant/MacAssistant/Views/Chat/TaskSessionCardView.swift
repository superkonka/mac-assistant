//
//  TaskSessionCardView.swift
//  MacAssistant
//

import SwiftUI

struct TaskSessionCardView: View {
    let session: AgentTaskSession
    var onToggle: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            summary
            metadata

            if session.isExpanded {
                Divider()
                transcript
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: session.status.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(session.status.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(statusColor)
            }

            Spacer()

            if session.status == .running {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            }

            Button(action: { onToggle?() }) {
                Image(systemName: session.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var summary: some View {
        Text(session.statusSummary)
            .font(.system(size: 12))
            .foregroundColor(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if let mainAgentName = session.mainAgentName, !mainAgentName.isEmpty {
                TaskSessionTag(label: "Main", value: mainAgentName)
            }

            if let delegateAgentName = session.delegateAgentName, !delegateAgentName.isEmpty {
                TaskSessionTag(label: "Agent", value: delegateAgentName)
            }

            TaskSessionTag(label: "任务", value: session.intentName)
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(session.messages) { message in
                TaskSessionMessageRow(message: message)
            }

            if let resultSummary = session.resultSummary,
               !resultSummary.isEmpty,
               session.status == .completed {
                TaskSessionResultRow(
                    title: "回流摘要",
                    content: resultSummary,
                    accent: .green
                )
            }

            if let errorMessage = session.errorMessage,
               !errorMessage.isEmpty,
               session.status == .failed {
                TaskSessionResultRow(
                    title: "失败原因",
                    content: errorMessage,
                    accent: .orange
                )
            }
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .queued:
            return .secondary
        case .running:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .orange
        }
    }

    private var cardBackground: Color {
        switch session.status {
        case .queued:
            return Color.gray.opacity(0.06)
        case .running:
            return Color.blue.opacity(0.06)
        case .completed:
            return Color.green.opacity(0.06)
        case .failed:
            return Color.orange.opacity(0.08)
        }
    }

    private var cardBorder: Color {
        switch session.status {
        case .queued:
            return Color.gray.opacity(0.2)
        case .running:
            return Color.blue.opacity(0.25)
        case .completed:
            return Color.green.opacity(0.22)
        case .failed:
            return Color.orange.opacity(0.28)
        }
    }
}

private struct TaskSessionTag: View {
    let label: String
    let value: String

    var body: some View {
        Text("\(label) · \(value)")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.04))
            )
    }
}

private struct TaskSessionMessageRow: View {
    let message: TaskSessionMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

                Text(message.timestamp, style: .time)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Text(message.content)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
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

private struct TaskSessionResultRow: View {
    let title: String
    let content: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent)

            Text(content)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(accent.opacity(0.08))
        )
    }
}
