//
//  ToDoListView.swift
//  MacAssistant
//
//  任务列表视图 - 完整的ToDoList管理界面
//

import SwiftUI

struct ToDoListView: View {
    @StateObject private var taskManager = TaskManager.shared
    @StateObject private var agentStore = AgentStore.shared
    @State private var selectedTab: TaskTab = .pending
    @State private var showClearConfirmation = false
    @State private var showAgentPicker = false
    @State private var selectedTaskForAgent: TaskItem?
    @State private var showTaskDetail = false
    
    enum TaskTab: String, CaseIterable {
        case pending = "待执行"
        case running = "执行中"
        case completed = "已完成"
        
        var icon: String {
            switch self {
            case .pending: return "circle"
            case .running: return "arrow.triangle.2.circlepath"
            case .completed: return "checkmark.circle"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            headerView
            
            // 标签切换
            tabPicker
            
            Divider()
            
            // 任务列表
            taskList
        }
        .frame(width: 400, height: 600)
        .background(Color(.windowBackgroundColor))
        .alert("选择执行Agent", isPresented: $showAgentPicker) {
            ForEach(agentStore.usableAgents) { agent in
                Button(agent.name) {
                    if let task = selectedTaskForAgent {
                        taskManager.assignAgentToTask(taskID: task.id, agent: agent)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请为此任务选择一个执行Agent")
        }
        .alert("确认清空", isPresented: $showClearConfirmation) {
            Button("清空", role: .destructive) {
                taskManager.clearCompletedTasks()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要清空所有已完成任务吗？此操作不可撤销。")
        }
        .sheet(isPresented: $showTaskDetail) {
            if let task = taskManager.selectedTask {
                TaskAgentChatView(task: task)
            }
        }
        .onAppear {
            // 检查是否有需要分配Agent的任务
            if taskManager.showAgentSelectionAlert,
               let taskID = taskManager.pendingAgentAssignmentTaskID,
               let task = taskManager.pendingTasks.first(where: { $0.id == taskID }) {
                selectedTaskForAgent = task
                showAgentPicker = true
            }
        }
    }
    
    // MARK: - 子视图
    
    private var headerView: some View {
        HStack {
            Text("任务列表")
                .font(.system(size: 16, weight: .semibold))
            
            Spacer()
            
            // 清空按钮（仅已完成标签显示）
            if selectedTab == .completed && !taskManager.completedTasks.isEmpty {
                Button(action: { showClearConfirmation = true }) {
                    Label("清空", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
            }
            
            // 关闭按钮
            Button(action: { 
                // 关闭popover的逻辑由调用方处理
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.05))
    }
    
    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(TaskTab.allCases, id: \.self) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    private func tabButton(for tab: TaskTab) -> some View {
        let isSelected = selectedTab == tab
        let count = taskCount(for: tab)
        
        return Button(action: { selectedTab = tab }) {
            HStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12))
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.15))
                        .foregroundColor(isSelected ? .blue : .secondary)
                        .cornerRadius(8)
                }
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
    
    private var taskList: some View {
        List {
            switch selectedTab {
            case .pending:
                pendingTasksSection
            case .running:
                runningTasksSection
            case .completed:
                completedTasksSection
            }
        }
        .listStyle(.plain)
    }
    
    private var pendingTasksSection: some View {
        Section {
            if taskManager.pendingTasks.isEmpty {
                emptyStateView(message: "暂无待执行的任务")
            } else {
                ForEach(taskManager.pendingTasks) { task in
                    PendingTaskRow(
                        task: task,
                        onStart: { taskManager.startTask(task.id) },
                        onPauseToggle: { taskManager.pauseTask(task.id) },
                        onDestroy: { taskManager.destroyTask(task.id) },
                        onSelect: {
                            taskManager.selectedTask = task
                            showTaskDetail = true
                        }
                    )
                }
            }
        }
    }
    
    private var runningTasksSection: some View {
        Section {
            if taskManager.runningTasks.isEmpty {
                emptyStateView(message: "暂无执行中的任务")
            } else {
                ForEach(taskManager.runningTasks) { task in
                    RunningTaskRow(
                        task: task,
                        onSelect: {
                            taskManager.selectedTask = task
                            showTaskDetail = true
                        }
                    )
                }
            }
        }
    }
    
    private var completedTasksSection: some View {
        Section {
            if taskManager.completedTasks.isEmpty {
                emptyStateView(message: "暂无已完成的任务")
            } else {
                ForEach(taskManager.completedTasks) { task in
                    CompletedTaskRow(
                        task: task,
                        onReactivate: {
                            if let task = taskManager.reactivateTask(task.id) {
                                taskManager.selectedTask = task
                                showTaskDetail = true
                            }
                        },
                        onSelect: {
                            taskManager.selectedTask = task
                            showTaskDetail = true
                        }
                    )
                }
            }
        }
    }
    
    private func emptyStateView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(.top, 40)
    }
    
    // MARK: - 辅助方法
    
    private func taskCount(for tab: TaskTab) -> Int {
        switch tab {
        case .pending: return taskManager.pendingTasks.count
        case .running: return taskManager.runningTasks.count
        case .completed: return taskManager.completedTasks.count
        }
    }
}

// MARK: - 任务行视图

/// 待执行任务行
struct PendingTaskRow: View {
    let task: TaskItem
    let onStart: () -> Void
    let onPauseToggle: () -> Void
    let onDestroy: () -> Void
    let onSelect: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: task.isPaused ? "pause.circle" : "circle")
                    .foregroundColor(task.isPaused ? .orange : .secondary)
                    .font(.system(size: 14))
                
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                
                Spacer()
                
                // 状态标签
                if task.isPaused {
                    Text("已暂停")
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundColor(.orange)
                        .cornerRadius(4)
                }
            }
            
            // 执行时间
            if let scheduledTime = task.scheduledTime {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text("计划执行: \(formatTime(scheduledTime))")
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary)
            }
            
            // Agent信息
            if let agentName = task.assignedAgentName {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                    Text("Agent: \(agentName)")
                        .font(.system(size: 11))
                }
                .foregroundColor(.blue.opacity(0.8))
            }
            
            // 操作按钮
            HStack(spacing: 8) {
                Button(action: onStart) {
                    Label("开始", systemImage: "play.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.blue)
                .disabled(task.isPaused || task.assignedAgentID == nil)
                
                Button(action: onPauseToggle) {
                    Label(task.isPaused ? "恢复" : "暂停", systemImage: task.isPaused ? "play" : "pause")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Spacer()
                
                Button(action: onDestroy) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                
                Button(action: onSelect) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// 执行中任务行
struct RunningTaskRow: View {
    let task: TaskItem
    let onSelect: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // 旋转动画图标
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.blue)
                    .font(.system(size: 14))
                    .rotationEffect(.degrees(0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: UUID())
                
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                
                Spacer()
                
                Text("执行中...")
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(4)
            }
            
            // Agent信息
            if let agentName = task.assignedAgentName {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                    Text("执行Agent: \(agentName)")
                        .font(.system(size: 11))
                }
                .foregroundColor(.blue.opacity(0.8))
            }
            
            // 最新日志预览
            if let latestLog = task.logs.last {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(latestLog.message.prefix(40))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            HStack {
                Spacer()
                
                Button(action: onSelect) {
                    Label("查看详情", systemImage: "eye")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

/// 已完成任务行
struct CompletedTaskRow: View {
    let task: TaskItem
    let onReactivate: () -> Void
    let onSelect: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(task.status == .completed ? .green : .red)
                    .font(.system(size: 14))
                
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .strikethrough(task.status == .completed)
                
                Spacer()
                
                Text(task.status == .completed ? "已完成" : "失败")
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(task.status == .completed ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                    .foregroundColor(task.status == .completed ? .green : .red)
                    .cornerRadius(4)
            }
            
            // 结果摘要
            if let result = task.result {
                Text(result.prefix(60))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            // 执行时间
            if let executionTime = task.executionTime {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                    Text("耗时: \(String(format: "%.1f", executionTime))s")
                        .font(.system(size: 10))
                }
                .foregroundColor(.secondary.opacity(0.7))
            }
            
            HStack {
                Button(action: onReactivate) {
                    Label("继续处理", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Spacer()
                
                Button(action: onSelect) {
                    Label("查看详情", systemImage: "eye")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

#Preview {
    ToDoListView()
}
