//
//  TaskAgentChatView.swift
//  MacAssistant
//
//  任务Agent对话界面 - 显示任务对话、CLI输出、支持追加提问
//

import SwiftUI

struct TaskAgentChatView: View {
    @State var task: TaskItem
    @StateObject private var taskManager = TaskManager.shared
    @StateObject private var agentStore = AgentStore.shared
    @State private var inputText: String = ""
    @State private var showLogViewer = false
    @State private var showAgentPicker = false
    @State private var isProcessing = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            headerView
            
            Divider()
            
            // 任务信息栏
            taskInfoBar
            
            Divider()
            
            // 消息列表
            messageList
            
            Divider()
            
            // 输入区域
            inputArea
        }
        .frame(minWidth: 600, minHeight: 500)
        .sheet(isPresented: $showLogViewer) {
            TaskLogViewer(task: task)
        }
        .sheet(isPresented: $showAgentPicker) {
            AgentPickerSheet(task: task)
        }
        .onAppear {
            // 刷新任务数据
            if let freshTask = taskManager.getTask(task.id) {
                task = freshTask
            }
        }
    }
    
    // MARK: - 子视图
    
    private var headerView: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    StatusBadge(status: task.status)
                    
                    if let agentName = task.assignedAgentName {
                        Text("• \(agentName)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // 日志查看按钮
            Button(action: { showLogViewer = true }) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("查看日志")
            
            // Agent选择按钮
            Button(action: { showAgentPicker = true }) {
                Image(systemName: "cpu")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("选择Agent")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.05))
    }
    
    private var taskInfoBar: some View {
        HStack(spacing: 12) {
            // 状态
            HStack(spacing: 4) {
                Image(systemName: statusIcon)
                    .font(.system(size: 10))
                Text(task.status.displayName)
                    .font(.system(size: 11))
            }
            .foregroundColor(statusColor)
            
            Divider()
                .frame(height: 12)
            
            // 创建时间
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 10))
                Text(formatDate(task.createdAt))
                    .font(.system(size: 11))
            }
            .foregroundColor(.secondary)
            
            if let executionTime = task.executionTime {
                Divider()
                    .frame(height: 12)
                
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text("耗时: \(String(format: "%.1f", executionTime))s")
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 操作按钮（根据状态）
            taskActionButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.03))
    }
    
    @ViewBuilder
    private var taskActionButtons: some View {
        switch task.status {
        case .pending:
            if task.isPaused {
                Button("恢复") {
                    taskManager.pauseTask(task.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
            } else {
                Button("开始执行") {
                    taskManager.startTask(task.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(task.assignedAgentID == nil)
            }
            
        case .running:
            Button("中断") {
                // 中断任务逻辑
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            
        case .completed, .failed:
            Button("继续处理") {
                if let reactivated = taskManager.reactivateTask(task.id) {
                    task = reactivated
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            
        case .paused:
            Button("恢复") {
                taskManager.pauseTask(task.id)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
        }
    }
    
    private var messageList: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(spacing: 12) {
                    ForEach(task.messages) { message in
                        TaskMessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .onChange(of: task.messages.count) { _ in
                    if let last = task.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
    
    private var inputArea: some View {
        HStack(spacing: 12) {
            TextField("追加提问或指令...", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .disabled(!canInput)
            
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(canInput && !inputText.isEmpty ? .blue : .secondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canInput || inputText.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.05))
    }
    
    // MARK: - 辅助属性
    
    private var statusIcon: String {
        switch task.status {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
    
    private var statusColor: Color {
        switch task.status {
        case .pending: return .secondary
        case .running: return .blue
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
    
    private var canInput: Bool {
        task.status == .pending || task.status == .running || task.status == .paused
    }
    
    // MARK: - 辅助方法
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
    
    private func sendMessage() {
        guard !inputText.isEmpty else { return }
        
        let content = inputText
        inputText = ""
        
        // 添加用户消息
        taskManager.addUserMessage(to: task.id, content: content)
        
        // 刷新任务
        if let freshTask = taskManager.getTask(task.id) {
            task = freshTask
        }
        
        // 如果是待执行状态，自动开始执行
        if task.status == .pending && !task.isPaused {
            taskManager.startTask(task.id)
        }
    }
}

// MARK: - 消息气泡

struct TaskMessageBubble: View {
    let message: TaskMessage
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // 发送者名称
                if message.role != .user {
                    Text(message.agentName ?? message.role.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                // 消息内容
                Text(message.content)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(backgroundColor)
                    .foregroundColor(foregroundColor)
                    .cornerRadius(12)
                
                // 时间
                Text(formatTime(message.timestamp))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            
            if message.role != .user {
                Spacer()
            }
        }
    }
    
    private var backgroundColor: Color {
        switch message.role {
        case .user:
            return .blue.opacity(0.15)
        case .assistant:
            return .secondary.opacity(0.1)
        case .system:
            return .orange.opacity(0.1)
        case .cli:
            return .black.opacity(0.05)
        }
    }
    
    private var foregroundColor: Color {
        switch message.role {
        case .cli:
            return .primary.opacity(0.8)
        default:
            return .primary
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 状态标签

struct StatusBadge: View {
    let status: TaskStatus
    
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.icon)
                .font(.system(size: 8))
            Text(status.displayName)
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .foregroundColor(color)
        .cornerRadius(4)
    }
    
    private var color: Color {
        switch status {
        case .pending: return .secondary
        case .running: return .blue
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - 日志查看器

struct TaskLogViewer: View {
    let task: TaskItem
    @StateObject private var taskManager = TaskManager.shared
    @State private var logContent: String = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("任务日志")
                    .font(.system(size: 16, weight: .semibold))
                
                Spacer()
                
                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            // 日志内容
            ScrollView {
                Text(logContent)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color.black.opacity(0.02))
        }
        .frame(width: 700, height: 500)
        .onAppear {
            // 从文件读取日志
            logContent = taskManager.getTaskLogContent(task.id)
            
            // 如果没有文件日志，显示内存中的日志
            if logContent.isEmpty {
                logContent = task.logs.map { "[\(formatTime($0.timestamp))] [\($0.level.rawValue.uppercased())] \($0.message)" }.joined(separator: "\n")
            }
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Agent选择器

struct AgentPickerSheet: View {
    let task: TaskItem
    @StateObject private var taskManager = TaskManager.shared
    @StateObject private var agentStore = AgentStore.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("选择执行Agent")
                    .font(.system(size: 16, weight: .semibold))
                
                Spacer()
                
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            // Agent列表
            List(agentStore.usableAgents) { agent in
                Button(action: {
                    taskManager.assignAgentToTask(taskID: task.id, agent: agent)
                    dismiss()
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent.name)
                                .font(.system(size: 13, weight: .medium))
                            Text(agent.model)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if task.assignedAgentID == agent.id {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 350, height: 400)
    }
}

// MARK: - 扩展

extension TaskMessage.TaskMessageRole {
    var displayName: String {
        switch self {
        case .user: return "用户"
        case .assistant: return "助手"
        case .system: return "系统"
        case .cli: return "CLI"
        }
    }
}

#Preview {
    TaskAgentChatView(task: TaskItem(
        title: "示例任务",
        description: "这是一个示例任务",
        messages: [
            TaskMessage(id: UUID(), role: .user, content: "帮我分析代码", timestamp: Date(), agentID: nil, agentName: nil),
            TaskMessage(id: UUID(), role: .assistant, content: "好的，我开始分析代码", timestamp: Date(), agentID: "1", agentName: "Kimi"),
            TaskMessage(id: UUID(), role: .cli, content: "Running analysis...\nFound 3 issues", timestamp: Date(), agentID: nil, agentName: "CLI")
        ]
    ))
}
