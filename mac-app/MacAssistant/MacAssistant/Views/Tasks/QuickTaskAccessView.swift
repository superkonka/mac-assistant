//
//  QuickTaskAccessView.swift
//  MacAssistant
//
//  快速任务访问视图 - 替代原TaskSessionTabsView，提供任务快速入口
//

import SwiftUI

/// 快速任务访问视图 - 显示在顶部工具栏的快捷任务入口
struct QuickTaskAccessView: View {
    @StateObject private var taskManager = UnifiedTaskManager.shared
    @State private var showTaskManager = false
    @State private var showPopover = false
    private var totalTaskCount: Int {
        taskManager.statistics.total
    }
    
    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 28)
                    .background(Color.secondary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                if totalTaskCount > 0 {
                    Text("\(min(totalTaskCount, 99))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue)
                        .clipShape(Capsule())
                        .offset(x: 6, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .help("快捷任务列表")
        .accessibilityLabel("快捷任务列表")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            QuickTaskListPopover(onOpenManager: {
                showPopover = false
                showTaskManager = true
            })
            .frame(width: 350, height: 400)
        }
        .sheet(isPresented: $showTaskManager) {
            UnifiedTaskManagerView()
                .frame(minWidth: 600, minHeight: 500)
        }
    }
}

// MARK: - Quick Task List Popover

struct QuickTaskListPopover: View {
    let onOpenManager: (() -> Void)?
    @StateObject private var taskManager = UnifiedTaskManager.shared
    @Environment(\.dismiss) private var dismiss

    init(onOpenManager: (() -> Void)? = nil) {
        self.onOpenManager = onOpenManager
    }
    
    private var recentTasks: [UnifiedTask] {
        Array(taskManager.tasks(filteredBy: .all).prefix(5))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack {
                Text("最近任务")
                    .font(.headline)
                
                Spacer()
                
                Button("查看全部") {
                    dismiss()
                    onOpenManager?()
                }
                .font(.caption)
            }
            .padding()
            
            Divider()
            
            // 任务列表
            if recentTasks.isEmpty {
                EmptyTaskPopoverView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(recentTasks) { task in
                            QuickTaskRow(task: task)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    // 点击任务，恢复或查看
                                    handleTaskTap(task)
                                }
                        }
                    }
                }
            }
            
            Divider()
            
            // 底部操作
            HStack {
                Button {
                    dismiss()
                    onOpenManager?()
                } label: {
                    Label("任务管理器", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                if taskManager.hasPendingExceptionTasks {
                    Button {
                        // 处理异常任务
                        handleExceptionTasks()
                    } label: {
                        Label("处理异常", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
    
    private func handleTaskTap(_ task: UnifiedTask) {
        // 异常恢复任务特殊处理
        if task.type == .exceptionRecovery && task.status == .pending {
            // 发送通知给 CommandRunner 恢复会话
            if let gatewaySessionKey = task.gatewaySessionKey,
               let originalRequest = task.originalRequest {
                NotificationCenter.default.post(
                    name: .resumeTaskSessionNotification,
                    object: nil,
                    userInfo: [
                        "gatewaySessionKey": gatewaySessionKey,
                        "originalRequest": originalRequest,
                        "taskID": task.id
                    ]
                )
            }
        } else {
            // 普通任务处理
            switch task.status {
            case .pending, .paused, .failed:
                Task {
                    await taskManager.startTask(id: task.id)
                }
            case .running:
                // 查看正在运行的任务详情
                break
            case .completed:
                // 查看完成结果
                break
            }
        }
        dismiss()
    }
    
    private func handleExceptionTasks() {
        // 找到第一个待处理的异常恢复任务
        if let exceptionTask = taskManager.tasks(filteredBy: .exception)
            .first(where: { $0.status == .pending }) {
            
            if let gatewaySessionKey = exceptionTask.gatewaySessionKey,
               let originalRequest = exceptionTask.originalRequest {
                NotificationCenter.default.post(
                    name: .resumeTaskSessionNotification,
                    object: nil,
                    userInfo: [
                        "gatewaySessionKey": gatewaySessionKey,
                        "originalRequest": originalRequest,
                        "taskID": exceptionTask.id
                    ]
                )
            }
        }
        dismiss()
    }
}

// MARK: - Quick Task Row

struct QuickTaskRow: View {
    let task: UnifiedTask
    
    var body: some View {
        HStack(spacing: 10) {
            // 状态图标
            TaskStatusIcon(status: task.status)
                .frame(width: 20, height: 20)
            
            // 内容
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                
                if let timeAgo = timeAgoString(from: task.updatedAt) {
                    Text(timeAgo)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // 操作提示
            if task.status == .pending || task.status == .failed {
                Image(systemName: "play.circle")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(task.status == .running ? Color.blue.opacity(0.05) : Color.clear)
    }
    
    private func timeAgoString(from date: Date) -> String? {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Empty Task Popover View

struct EmptyTaskPopoverView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            
            Text("暂无任务")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Text("创建任务来跟踪和管理你的工作")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Preview

#Preview {
    QuickTaskAccessView()
        .padding()
}
