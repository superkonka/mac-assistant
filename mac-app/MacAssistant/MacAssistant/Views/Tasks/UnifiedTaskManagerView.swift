//
//  UnifiedTaskManagerView.swift
//  MacAssistant
//
//  统一任务管理视图 - 替代任务悬层和子任务面板
//

import SwiftUI

/// 统一任务管理视图
struct UnifiedTaskManagerView: View {
    @StateObject private var manager = UnifiedTaskManager.shared
    @State private var selectedFilter: TaskFilter = .all
    @State private var showSmartTaskCreation = false
    @State private var searchText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            toolbarView
            
            // 筛选标签栏
            filterBarView
            
            // 任务列表
            taskListView
        }
        .frame(minWidth: 400, minHeight: 500)
        .sheet(isPresented: $showSmartTaskCreation) {
            SmartTaskCreationView()
        }
    }
    
    // MARK: - Subviews
    
    /// 工具栏
    private var toolbarView: some View {
        HStack {
            // 标题和统计
            HStack(spacing: 8) {
                Text("任务管理")
                    .font(.headline)
                
                if manager.statistics.total > 0 {
                    Text("(\(manager.statistics.total))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // 搜索框
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索任务...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(width: 200)
            
            // 新建任务按钮
            Button {
                showSmartTaskCreation = true
            } label: {
                Image(systemName: "plus")
                Text("新建任务")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    /// 筛选标签栏
    private var filterBarView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(TaskFilter.allCases, id: \.self) { filter in
                    FilterTabButton(
                        filter: filter,
                        count: taskCount(for: filter),
                        isSelected: selectedFilter == filter,
                        action: { selectedFilter = filter }
                    )
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
    
    /// 任务列表
    private var taskListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                let filteredTasks = filteredAndSortedTasks
                
                if filteredTasks.isEmpty {
                    emptyStateView
                } else {
                    ForEach(filteredTasks) { task in
                        UnifiedTaskRow(task: task)
                            .id(task.id)
                    }
                }
            }
            .padding()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    /// 空状态
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedFilter.icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text(emptyStateTitle)
                .font(.headline)
                .foregroundStyle(.secondary)
            
            if selectedFilter == .all || selectedFilter == .pending {
                Button("创建第一个任务") {
                    showSmartTaskCreation = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
    
    private var emptyStateTitle: String {
        switch selectedFilter {
        case .all:
            return "暂无任务"
        case .pending:
            return "没有待执行的任务"
        case .running:
            return "没有执行中的任务"
        case .completed:
            return "没有已完成的任务"
        case .exception:
            return "没有异常恢复任务"
        }
    }
    
    // MARK: - Helpers
    
    /// 筛选并排序的任务
    private var filteredAndSortedTasks: [UnifiedTask] {
        let baseTasks = manager.tasks(filteredBy: selectedFilter)
        
        if searchText.isEmpty {
            return baseTasks
        }
        
        return baseTasks.filter { task in
            task.title.localizedCaseInsensitiveContains(searchText) ||
            task.description.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    /// 获取筛选器的任务数量
    private func taskCount(for filter: TaskFilter) -> Int {
        manager.tasks(filteredBy: filter).count
    }
}

// MARK: - Filter Tab Button

struct FilterTabButton: View {
    let filter: TaskFilter
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: filter.icon)
                    .font(.caption)
                Text(filter.rawValue)
                    .font(.subheadline)
                
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color.clear)
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Unified Task Row

struct UnifiedTaskRow: View {
    @State var task: UnifiedTask
    @State private var isHovered = false
    @State private var showDetails = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // 状态图标
                TaskStatusIcon(status: task.status)
                
                // 类型图标
                Image(systemName: task.type.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                
                // 内容
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    
                    if !task.description.isEmpty {
                        Text(task.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                // 右侧信息
                HStack(spacing: 8) {
                    // 执行时间
                    if let executionTime = task.executionTime {
                        Text(formatTimeInterval(executionTime))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    // 状态标签
                    TaskStatusBadge(status: task.status)
                    
                    // 操作按钮
                    if isHovered {
                        TaskActionButtons(task: task)
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(task.isSelected ? 0.5 : 0), lineWidth: 2)
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showDetails.toggle()
                }
            }
            
            // 展开详情
            if showDetails {
                UnifiedTaskDetailView(task: task)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
    
    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return String(format: "%.1fs", interval)
        } else {
            let minutes = Int(interval) / 60
            let seconds = Int(interval) % 60
            return "\(minutes)m \(seconds)s"
        }
    }
}

// MARK: - Task Status Icon

struct TaskStatusIcon: View {
    let status: UnifiedTaskStatus
    
    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 14))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(color.opacity(0.15))
            .clipShape(Circle())
    }
    
    private var iconName: String {
        switch status {
        case .pending:
            return "hourglass"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .paused:
            return "pause.fill"
        case .completed:
            return "checkmark"
        case .failed:
            return "exclamationmark"
        }
    }
    
    private var color: Color {
        switch status {
        case .pending:
            return .secondary
        case .running:
            return .blue
        case .paused:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }
}

// MARK: - Task Status Badge

struct TaskStatusBadge: View {
    let status: UnifiedTaskStatus
    
    var body: some View {
        Text(status.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(backgroundColor.opacity(0.15))
            .foregroundStyle(foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    
    private var backgroundColor: Color {
        switch status {
        case .pending:
            return .secondary
        case .running:
            return .blue
        case .paused:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }
    
    private var foregroundColor: Color {
        switch status {
        case .pending:
            return .secondary
        case .running:
            return .blue
        case .paused:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }
}

// MARK: - Task Action Buttons

struct TaskActionButtons: View {
    let task: UnifiedTask
    @StateObject private var manager = UnifiedTaskManager.shared
    
    var body: some View {
        HStack(spacing: 4) {
            switch task.status {
            case .pending, .paused:
                Button {
                    Task { await manager.startTask(id: task.id) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.blue)
                
            case .running:
                Button {
                    manager.pauseTask(id: task.id)
                } label: {
                    Image(systemName: "pause.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                
            case .failed:
                Button {
                    Task { await manager.retryTask(id: task.id) }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.blue)
                
            case .completed:
                EmptyView()
            }
            
            Button {
                manager.removeTask(id: task.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Task Detail View

struct UnifiedTaskDetailView: View {
    let task: UnifiedTask
    @StateObject private var manager = UnifiedTaskManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            
            // 消息历史（异常恢复和子任务）
            if !task.messages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("对话历史")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    
                    ForEach(task.messages.prefix(3)) { message in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(message.role == .user ? Color.blue : Color.green)
                                .frame(width: 6, height: 6)
                            
                            Text(message.content)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    
                    if task.messages.count > 3 {
                        Text("还有 \(task.messages.count - 3) 条消息...")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            
            // 日志（后台任务）
            if !task.logs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("执行日志")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    
                    ForEach(task.logs.prefix(3)) { log in
                        HStack(spacing: 8) {
                            Text(log.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            
                            Text(log.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            
            // 错误信息
            if let error = task.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text("错误信息")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                    
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
            
            // 结果预览
            if let result = task.result {
                VStack(alignment: .leading, spacing: 8) {
                    Text("执行结果")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                    
                    Text(result.prefix(200))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                    
                    if result.count > 200 {
                        Button("查看完整结果") {
                            // TODO: 显示完整结果
                        }
                        .font(.caption)
                    }
                }
            }
            
            // 操作区域
            HStack {
                Spacer()
                
                if task.type == .exceptionRecovery && task.status == .pending {
                    Button("继续处理") {
                        Task { await manager.startTask(id: task.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                
                if task.status == .failed {
                    Button("重试") {
                        Task { await manager.retryTask(id: task.id) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
}

// MARK: - Preview

#Preview {
    UnifiedTaskManagerView()
        .frame(width: 500, height: 600)
}
