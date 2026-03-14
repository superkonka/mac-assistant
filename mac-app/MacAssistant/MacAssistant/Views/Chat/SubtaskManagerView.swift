//
//  SubtaskManagerView.swift
//  MacAssistant
//
//  子任务管理器 - 独立入口，按状态分组展示
//

import SwiftUI

struct SubtaskManagerView: View {
    let sessions: [AgentTaskSession]
    let onSelectSession: (AgentTaskSession) -> Void
    let onCreateSubtask: () -> Void
    let onDeleteSession: ((String) -> Void)?
    
    @State private var showingPopover = false
    @State private var selectedDetailSession: AgentTaskSession? = nil
    
    // 按状态分组
    private var runningSessions: [AgentTaskSession] {
        sessions.filter { $0.status == .running || $0.status == .queued || $0.status == .partial }
    }
    
    private var completedSessions: [AgentTaskSession] {
        sessions.filter { $0.status == .completed }
    }
    
    private var failedSessions: [AgentTaskSession] {
        sessions.filter { $0.status == .failed || $0.status == .waitingUser }
    }
    
    private var totalCount: Int {
        sessions.count
    }
    
    private var activeCount: Int {
        runningSessions.count
    }
    
    var body: some View {
        Button(action: { showingPopover = true }) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 14))
                
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.system(size: 11, weight: .semibold))
                }
                
                if totalCount > 0 {
                    Text("/\(totalCount)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(activeCount > 0 ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(activeCount > 0 ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .help("子任务管理")
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            SubtaskPopoverContent(
                runningSessions: runningSessions,
                completedSessions: completedSessions,
                failedSessions: failedSessions,
                onSelectSession: { session in
                    showingPopover = false
                    selectedDetailSession = session
                },
                onCreateSubtask: {
                    showingPopover = false
                    onCreateSubtask()
                },
                onDeleteSession: onDeleteSession
            )
            .frame(width: 380, height: 480)
        }
        .sheet(item: $selectedDetailSession) { session in
            SubtaskDetailView(session: session, onDelete: {
                onDeleteSession?(session.id)
                selectedDetailSession = nil
            })
            .frame(minWidth: 600, minHeight: 500)
        }
    }
}

private struct SubtaskPopoverContent: View {
    let runningSessions: [AgentTaskSession]
    let completedSessions: [AgentTaskSession]
    let failedSessions: [AgentTaskSession]
    let onSelectSession: (AgentTaskSession) -> Void
    let onCreateSubtask: () -> Void
    let onDeleteSession: ((String) -> Void)?
    
    var body: some View {
        VStack(spacing: 0) {
            // 头部
            header
            
            Divider()
            
            // 内容列表
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 进行中
                    if !runningSessions.isEmpty {
                        SessionSection(
                            title: "进行中",
                            icon: "play.circle.fill",
                            color: .blue,
                            sessions: runningSessions,
                            onSelect: onSelectSession,
                            onDelete: nil
                        )
                    }
                    
                    // 已完成
                    if !completedSessions.isEmpty {
                        SessionSection(
                            title: "已完成",
                            icon: "checkmark.circle.fill",
                            color: .green,
                            sessions: completedSessions,
                            onSelect: onSelectSession,
                            onDelete: onDeleteSession
                        )
                    }
                    
                    // 失败/等待
                    if !failedSessions.isEmpty {
                        SessionSection(
                            title: "失败 / 等待处理",
                            icon: "exclamationmark.triangle.fill",
                            color: .orange,
                            sessions: failedSessions,
                            onSelect: onSelectSession,
                            onDelete: onDeleteSession
                        )
                    }
                    
                    // 空状态
                    if runningSessions.isEmpty && completedSessions.isEmpty && failedSessions.isEmpty {
                        EmptyStateView()
                    }
                }
                .padding(16)
            }
            
            Divider()
            
            // 底部创建按钮
            footer
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("子任务")
                    .font(.system(size: 14, weight: .semibold))
                
                let total = runningSessions.count + completedSessions.count + failedSessions.count
                Text("\(total) 个子任务")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                if !runningSessions.isEmpty {
                    StatusDot(color: .blue, count: runningSessions.count)
                }
                if !completedSessions.isEmpty {
                    StatusDot(color: .green, count: completedSessions.count)
                }
                if !failedSessions.isEmpty {
                    StatusDot(color: .orange, count: failedSessions.count)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    private var footer: some View {
        HStack {
            Spacer()
            
            Button(action: onCreateSubtask) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                    Text("新建子任务")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.blue)
                .cornerRadius(6)
            }
            .buttonStyle(PlainButtonStyle())
            .help("通过 Planner 对话创建新子任务")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct SessionSection: View {
    let title: String
    let icon: String
    let color: Color
    let sessions: [AgentTaskSession]
    let onSelect: (AgentTaskSession) -> Void
    let onDelete: ((String) -> Void)?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 分组标题
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(color)
                
                Text("\(sessions.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(4)
                
                Spacer()
            }
            
            // 任务列表
            VStack(spacing: 6) {
                ForEach(sessions) { session in
                    DeletableSessionRow(
                        session: session,
                        accentColor: color,
                        onTap: { onSelect(session) },
                        onDelete: onDelete
                    )
                }
            }
        }
    }
}

private struct DeletableSessionRow: View {
    let session: AgentTaskSession
    let accentColor: Color
    let onTap: () -> Void
    let onDelete: ((String) -> Void)?
    
    var body: some View {
        HStack(spacing: 0) {
            // 主要可点击区域
            Button(action: onTap) {
                HStack(spacing: 10) {
                    // 状态图标
                    ZStack {
                        Circle()
                            .fill(session.status.taskBackgroundColor)
                            .frame(width: 28, height: 28)
                        
                        if session.status == .running {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: session.status.symbolName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(session.status.taskAccentColor)
                        }
                    }
                    
                    // 内容
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        HStack(spacing: 6) {
                            Text(session.intentName)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            
                            Text("•")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.5))
                            
                            Text(session.updatedAt, style: .relative)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    // 箭头
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(PlainButtonStyle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(session.status.taskBorderColor.opacity(0.5), lineWidth: 1)
            )
            
            // 删除按钮（仅对已完成/失败的任务显示）
            if let onDelete = onDelete {
                Button(action: { onDelete(session.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 6)
                .help("删除此任务")
            }
        }
    }
}

private struct StatusDot: View {
    let color: Color
    let count: Int
    
    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(4)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.4))
            
            Text("暂无子任务")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            
            Text("点击下方「新建子任务」开始创建")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

// MARK: - 详情视图

private struct SubtaskDetailView: View {
    let session: AgentTaskSession
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 16, weight: .semibold))
                    
                    HStack(spacing: 8) {
                        StatusBadge(status: session.status)
                        Text("创建于 \(session.createdAt.formatted())")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    // 删除按钮
                    Button(action: {
                        onDelete()
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                            .frame(width: 32, height: 32)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("删除任务")
                    
                    // 关闭按钮
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("关闭")
                }
            }
            .padding(20)
            
            Divider()
            
            // 内容
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 状态摘要
                    if !session.statusSummary.isEmpty {
                        DetailSection(title: "状态摘要") {
                            Text(session.statusSummary)
                                .font(.system(size: 13))
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(session.status.taskBackgroundColor)
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(session.status.taskBorderColor, lineWidth: 1)
                                )
                        }
                    }
                    
                    // 原始请求
                    DetailSection(title: "原始请求") {
                        Text(session.originalRequest)
                            .font(.system(size: 13))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.03))
                            .cornerRadius(8)
                    }
                    
                    // 任务信息
                    DetailSection(title: "任务信息") {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)
                            ],
                            spacing: 12
                        ) {
                            InfoItem(title: "任务 ID", value: session.id)
                            InfoItem(title: "意图", value: session.intentName)
                            InfoItem(title: "主 Agent", value: session.mainAgentName ?? "未记录")
                            InfoItem(title: "执行 Agent", value: session.delegateAgentName ?? "未记录")
                            InfoItem(title: "消息数", value: "\(session.messages.count)")
                            InfoItem(title: "最后更新", value: session.updatedAt.formatted())
                        }
                    }
                    
                    // 执行结果
                    if let result = session.resultSummary, !result.isEmpty {
                        DetailSection(title: "执行结果") {
                            Text(result)
                                .font(.system(size: 13))
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.08))
                                .cornerRadius(8)
                        }
                    }
                    
                    // 错误信息
                    if let error = session.errorMessage, !error.isEmpty {
                        DetailSection(title: "错误信息") {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.orange)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.08))
                                .cornerRadius(8)
                        }
                    }
                    
                    // 消息记录
                    if !session.messages.isEmpty {
                        DetailSection(title: "消息记录 (\(session.messages.count))") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(session.messages) { message in
                                    MessageRow(message: message)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

private struct DetailSection<Content: View>: View {
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

private struct InfoItem: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.03))
        .cornerRadius(6)
    }
}

private struct MessageRow: View {
    let message: TaskSessionMessage
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
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
        .background(Color.black.opacity(0.03))
        .cornerRadius(8)
    }
    
    private var roleTitle: String {
        switch message.role {
        case .user: return "用户"
        case .assistant: return "助手"
        case .system: return "系统"
        }
    }
    
    private var roleColor: Color {
        switch message.role {
        case .user: return .blue
        case .assistant: return .green
        case .system: return .secondary
        }
    }
}

private struct StatusBadge: View {
    let status: TaskSessionStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbolName)
                .font(.system(size: 10))
            Text(status.displayName)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.taskBackgroundColor)
        .foregroundColor(status.taskAccentColor)
        .cornerRadius(4)
    }
}

// MARK: - Preview Helpers

private extension AgentTaskSession {

}
