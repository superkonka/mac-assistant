//
//  UnifiedTaskManagerView.swift
//  MacAssistant
//
//  统一任务管理视图 - 支持直达选中任务和继续处理
//

import SwiftUI

enum TaskManagerTab: String, CaseIterable {
    case inbox = "收件箱"
    case running = "运行中"
    case scheduled = "已排期"
    case history = "历史"

    var icon: String {
        switch self {
        case .inbox:
            return "tray.full"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .scheduled:
            return "calendar.badge.clock"
        case .history:
            return "clock.arrow.circlepath"
        }
    }
}

struct UnifiedTaskManagerView: View {
    @StateObject private var manager = UnifiedTaskManager.shared
    @State private var selectedTab: TaskManagerTab = .inbox
    @State private var showSmartTaskCreation = false
    @State private var showSubtasks = false
    @State private var searchText = ""
    @State private var expandedTaskIDs: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                toolbarView
                filterBarView
                taskListView
            }
            .frame(minWidth: 420, minHeight: 520)
            .sheet(isPresented: $showSmartTaskCreation) {
                SmartTaskCreationView()
            }
            .onAppear {
                revealSelectedTask(using: proxy)
            }
            .onChange(of: manager.selectedTaskID) { _ in
                revealSelectedTask(using: proxy)
            }
        }
    }

    private var toolbarView: some View {
        HStack {
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
            .frame(width: 220)

            if hiddenSubtaskCount > 0 || showSubtasks {
                Button {
                    showSubtasks.toggle()
                } label: {
                    Image(systemName: showSubtasks ? "rectangle.stack" : "rectangle.stack.badge.person.crop")
                    Text(showSubtasks ? "收起子任务" : "显示子任务 \(hiddenSubtaskCount)")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button {
                showSmartTaskCreation = true
            } label: {
                Image(systemName: "plus")
                Text("新建任务")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            
            // 关闭按钮
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var filterBarView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(TaskManagerTab.allCases, id: \.self) { tab in
                    FilterTabButton(
                        title: tab.rawValue,
                        icon: tab.icon,
                        count: taskCount(for: tab),
                        isSelected: selectedTab == tab,
                        action: { selectedTab = tab }
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

    private var taskListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                let filteredTasks = filteredAndSortedTasks

                if filteredTasks.isEmpty {
                    emptyStateView
                } else {
                    ForEach(filteredTasks) { task in
                        UnifiedTaskRow(
                            context: selectedTab,
                            task: task,
                            isExpanded: expandedTaskIDs.contains(task.id),
                            isSelected: manager.selectedTaskID == task.id,
                            onToggleDetails: { toggleDetails(for: task.id) }
                        )
                        .id(task.id)
                    }
                }
            }
            .padding()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedTab.icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(emptyStateTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            if selectedTab == .inbox {
                Button("创建第一个任务") {
                    showSmartTaskCreation = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var emptyStateTitle: String {
        switch selectedTab {
        case .inbox:
            return "收件箱为空"
        case .running:
            return "没有执行中的任务"
        case .scheduled:
            return "没有已排期的任务"
        case .history:
            return "暂无历史任务"
        }
    }

    private var filteredAndSortedTasks: [UnifiedTask] {
        let baseTasks: [UnifiedTask]
        let includeGroupedSubtasks = showSubtasks || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch selectedTab {
        case .inbox:
            baseTasks = manager.attentionTasks(includeGroupedSubtasks: includeGroupedSubtasks)
        case .running:
            baseTasks = manager.activeTasks(includeGroupedSubtasks: includeGroupedSubtasks)
        case .scheduled:
            baseTasks = manager.scheduledTasks(includeGroupedSubtasks: includeGroupedSubtasks)
        case .history:
            baseTasks = manager.historyTasks(includeGroupedSubtasks: includeGroupedSubtasks)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            return baseTasks
        }

        return baseTasks.filter { task in
            task.title.localizedCaseInsensitiveContains(query) ||
            task.description.localizedCaseInsensitiveContains(query) ||
            task.inputContext.localizedCaseInsensitiveContains(query) ||
            (task.errorMessage?.localizedCaseInsensitiveContains(query) ?? false) ||
            (task.result?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func taskCount(for tab: TaskManagerTab) -> Int {
        switch tab {
        case .inbox:
            return manager.attentionTasks(includeGroupedSubtasks: showSubtasks).count
        case .running:
            return manager.activeTasks(includeGroupedSubtasks: showSubtasks).count
        case .scheduled:
            return manager.scheduledTasks(includeGroupedSubtasks: showSubtasks).count
        case .history:
            return manager.historyTasks(includeGroupedSubtasks: showSubtasks).count
        }
    }

    private var hiddenSubtaskCount: Int {
        manager.hiddenGroupedSubtaskCount(for: selectedTab)
    }

    private func toggleDetails(for taskID: String) {
        manager.focusTask(id: taskID)

        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedTaskIDs.contains(taskID) {
                expandedTaskIDs.remove(taskID)
            } else {
                expandedTaskIDs.insert(taskID)
            }
        }
    }

    private func revealSelectedTask(using proxy: ScrollViewProxy) {
        guard let selectedTaskID = manager.selectedTaskID,
              manager.task(id: selectedTaskID) != nil else {
            return
        }

        if !filteredAndSortedTasks.contains(where: { $0.id == selectedTaskID }) {
            if let selectedTask = manager.task(id: selectedTaskID) {
                if selectedTask.type == .smartSubtask {
                    showSubtasks = true
                }
                selectedTab = tab(for: selectedTask)
            }
            searchText = ""
        }

        expandedTaskIDs.insert(selectedTaskID)

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(selectedTaskID, anchor: .center)
            }
        }
    }

    private func tab(for task: UnifiedTask) -> TaskManagerTab {
        if manager.attentionTasks().contains(where: { $0.id == task.id }) {
            return .inbox
        }
        if manager.activeTasks().contains(where: { $0.id == task.id }) {
            return .running
        }
        if manager.scheduledTasks().contains(where: { $0.id == task.id }) {
            return .scheduled
        }
        return .history
    }
}

struct FilterTabButton: View {
    let title: String
    let icon: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
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

struct UnifiedTaskRow: View {
    let context: TaskManagerTab
    let task: UnifiedTask
    let isExpanded: Bool
    let isSelected: Bool
    let onToggleDetails: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                TaskStatusIcon(status: task.status)

                Image(systemName: task.type.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(task.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)

                        if task.type == .exceptionRecovery {
                            taskKindTag("异常恢复", tint: .orange)
                        } else if task.type == .smartSubtask {
                            taskKindTag("子任务", tint: .secondary)
                        } else if task.type == .background {
                            taskKindTag("后台", tint: .indigo)
                        }
                    }

                    Text(primaryDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !metaSummary.isEmpty {
                        Text(metaSummary)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    if !trailingTimeText.isEmpty {
                        Text(trailingTimeText)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    TaskStatusBadge(task: task, context: context)

                    if isHovered {
                        TaskActionButtons(context: context, task: task)
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.5) : Color.clear,
                        lineWidth: 2
                    )
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .onTapGesture(perform: onToggleDetails)

            if isExpanded {
                UnifiedTaskDetailView(task: task)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var primaryDetail: String {
        switch context {
        case .history:
            if let result = task.result, !result.isEmpty {
                return String(result.prefix(72))
            }
            if let error = task.errorMessage, !error.isEmpty {
                return error
            }
        case .inbox:
            if let error = task.errorMessage, !error.isEmpty {
                return error
            }
        case .scheduled, .running:
            break
        }

        if !task.description.isEmpty {
            return task.description
        }
        if !task.inputContext.isEmpty {
            return String(task.inputContext.prefix(72))
        }
        return task.strategy.displayName
    }

    private var metaSummary: String {
        switch context {
        case .inbox:
            let stateLabel: String
            if task.type == .exceptionRecovery {
                stateLabel = "等待继续恢复"
            } else if task.status == .failed {
                stateLabel = "等待重试"
            } else {
                stateLabel = "等待处理"
            }
            return "\(stateLabel) · 最近变化 \(absoluteDateTime(task.updatedAt))"
        case .running:
            if let executionTime = task.executionTime {
                return "已运行 \(formatTimeInterval(executionTime)) · 最近变化 \(relativeTime(task.updatedAt))"
            }
            if let startedAt = task.startedAt {
                return "开始于 \(absoluteDateTime(startedAt)) · 最近变化 \(relativeTime(task.updatedAt))"
            }
            return "最近变化 \(relativeTime(task.updatedAt))"
        case .scheduled:
            guard let scheduledTime = task.scheduledTime else {
                return "已排期，等待触发"
            }

            if primaryDetail.hasPrefix("自动重试") {
                return "下次重试 \(absoluteDateTime(scheduledTime)) · \(relativeTime(scheduledTime))"
            }
            return "下次执行 \(absoluteDateTime(scheduledTime)) · \(relativeTime(scheduledTime))"
        case .history:
            let finishedAt = task.completedAt ?? task.updatedAt
            if let executionTime = task.executionTime {
                return "完成于 \(absoluteDateTime(finishedAt)) · 耗时 \(formatTimeInterval(executionTime))"
            }
            return "完成于 \(absoluteDateTime(finishedAt))"
        }
    }

    private var trailingTimeText: String {
        switch context {
        case .scheduled:
            guard let scheduledTime = task.scheduledTime else { return "" }
            return absoluteClockTime(scheduledTime)
        case .history:
            return relativeTime(task.completedAt ?? task.updatedAt)
        case .inbox, .running:
            return relativeTime(task.updatedAt)
        }
    }

    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return String(format: "%.1fs", interval)
        }

        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return "\(minutes)m \(seconds)s"
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteClockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func absoluteDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private func taskKindTag(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

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

struct TaskStatusBadge: View {
    let task: UnifiedTask
    let context: TaskManagerTab

    var body: some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(backgroundColor.opacity(0.15))
            .foregroundStyle(foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var backgroundColor: Color {
        switch context {
        case .scheduled:
            return isRetryWaiting ? .orange : .indigo
        case .inbox where task.status == .paused:
            return .orange
        default:
            switch task.status {
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

    private var title: String {
        switch context {
        case .scheduled:
            return isRetryWaiting ? "重试等待" : "已排期"
        case .inbox where task.status == .paused:
            return "待处理"
        default:
            return task.status.displayName
        }
    }

    private var isRetryWaiting: Bool {
        task.description.hasPrefix("自动重试")
    }

    private var foregroundColor: Color {
        backgroundColor
    }
}

struct TaskActionButtons: View {
    let context: TaskManagerTab
    let task: UnifiedTask
    @StateObject private var manager = UnifiedTaskManager.shared

    var body: some View {
        HStack(spacing: 4) {
            if let primaryAction {
                Button(action: primaryAction.handler) {
                    Image(systemName: primaryAction.icon)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(primaryAction.tint)
                .help(primaryAction.label)
            }

            Button {
                manager.removeTask(id: task.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("移除任务")
        }
    }

    private var primaryAction: TaskRowAction? {
        switch context {
        case .scheduled:
            return TaskRowAction(
                icon: "play.fill",
                label: "立即执行",
                tint: .blue
            ) {
                Task { await manager.startTask(id: task.id) }
            }
        case .running:
            switch task.status {
            case .running:
                return TaskRowAction(
                    icon: "pause.fill",
                    label: "暂停",
                    tint: .orange
                ) {
                    manager.pauseTask(id: task.id)
                }
            case .pending, .paused:
                return TaskRowAction(
                    icon: "play.fill",
                    label: "继续执行",
                    tint: .blue
                ) {
                    Task { await manager.startTask(id: task.id) }
                }
            case .failed:
                return TaskRowAction(
                    icon: "arrow.counterclockwise",
                    label: "重试",
                    tint: .blue
                ) {
                    Task { await manager.retryTask(id: task.id) }
                }
            case .completed:
                return nil
            }
        case .inbox:
            switch task.status {
            case .failed:
                return TaskRowAction(
                    icon: "arrow.counterclockwise",
                    label: "重试",
                    tint: .blue
                ) {
                    Task { await manager.retryTask(id: task.id) }
                }
            case .pending, .paused:
                return TaskRowAction(
                    icon: "play.fill",
                    label: task.type == .exceptionRecovery ? "继续恢复" : "继续处理",
                    tint: .orange
                ) {
                    Task { await manager.continueTask(id: task.id) }
                }
            case .running:
                return TaskRowAction(
                    icon: "pause.fill",
                    label: "暂停",
                    tint: .orange
                ) {
                    manager.pauseTask(id: task.id)
                }
            case .completed:
                return nil
            }
        case .history:
            switch task.status {
            case .completed:
                return TaskRowAction(
                    icon: "arrow.triangle.branch",
                    label: "继续处理",
                    tint: .green
                ) {
                    Task { await manager.continueTask(id: task.id) }
                }
            case .failed:
                return TaskRowAction(
                    icon: "arrow.counterclockwise",
                    label: "重新处理",
                    tint: .blue
                ) {
                    Task { await manager.retryTask(id: task.id) }
                }
            case .pending, .paused:
                return TaskRowAction(
                    icon: "play.fill",
                    label: "继续执行",
                    tint: .blue
                ) {
                    Task { await manager.startTask(id: task.id) }
                }
            case .running:
                return TaskRowAction(
                    icon: "pause.fill",
                    label: "暂停",
                    tint: .orange
                ) {
                    manager.pauseTask(id: task.id)
                }
            }
        }
    }
}

private struct TaskRowAction {
    let icon: String
    let label: String
    let tint: Color
    let handler: () -> Void
}

struct UnifiedTaskDetailView: View {
    let task: UnifiedTask

    @StateObject private var manager = UnifiedTaskManager.shared
    @StateObject private var logger = ExecutionLogger.shared
    @State private var followUpText = ""
    @State private var isSubmitting = false
    @State private var showExecutionLog = false

    private var currentTask: UnifiedTask {
        manager.task(id: task.id) ?? task
    }

    private var canContinue: Bool {
        currentTask.status != .running
    }

    private var continueButtonTitle: String {
        if !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "补充并继续"
        }

        switch currentTask.status {
        case .pending:
            return "开始执行"
        case .paused:
            return "继续执行"
        case .completed, .failed:
            return "继续处理"
        case .running:
            return "执行中"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()

            taskMeta

            if !currentTask.messages.isEmpty {
                messageHistory
            }

            if !currentTask.logs.isEmpty {
                logHistory
            }

            if let error = currentTask.errorMessage, !error.isEmpty {
                detailCard(title: "错误信息", tint: .red) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }

            if let result = currentTask.result, !result.isEmpty {
                detailCard(title: "执行结果", tint: .green) {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(8)
                }
            }

            continueSection
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private var taskMeta: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                metaChip(title: currentTask.type.displayName, tint: .secondary)
                metaChip(title: currentTask.status.displayName, tint: statusColor)

                if let scheduledTime = currentTask.scheduledTime, currentTask.status == .pending {
                    metaChip(title: scheduledTime.formatted(date: .omitted, time: .shortened), tint: .orange)
                }
            }

            HStack(spacing: 16) {
                Text("创建于 \(currentTask.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let updatedAt = currentTask.completedAt ?? currentTask.startedAt {
                    Text("最近变化 \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var messageHistory: some View {
        let recentMessages: [TaskMessage] = Swift.Array(currentTask.messages.suffix(10))
        let hasMoreMessages = currentTask.messages.count > 10

        return detailCard(title: "对话历史", tint: .blue) {
            VStack(alignment: .leading, spacing: 8) {
                TaskMessageHistoryList(messages: recentMessages)
                
                if hasMoreMessages {
                    Text("还有 \(currentTask.messages.count - 10) 条消息...")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var logHistory: some View {
        let recentLogs: [TaskLogEntry] = Swift.Array(currentTask.logs.suffix(20))
        let hasMoreLogs = currentTask.logs.count > 20

        return detailCard(title: "执行日志", tint: .secondary) {
            VStack(alignment: .leading, spacing: 8) {
                TaskLogHistoryList(logs: recentLogs)
                
                if hasMoreLogs {
                    Text("还有 \(currentTask.logs.count - 20) 条日志...")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                
                // 查看完整执行链路按钮
                if let sessionID = executionSessionID {
                    Button {
                        showExecutionLog = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal")
                                .font(.caption)
                            Text("查看完整执行链路")
                                .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showExecutionLog) {
                        ExecutionLogView(sessionID: sessionID)
                    }
                }
            }
        }
    }
    
    /// 获取执行链路日志的 sessionID
    private var executionSessionID: String? {
        // 优先使用 task.id 查找 ExecutionLogger 中的会话
        if logger.getSession(currentTask.id) != nil {
            return currentTask.id
        }
        // 其次尝试使用 gatewaySessionKey
        if let gatewayKey = currentTask.gatewaySessionKey,
           logger.getSession(gatewayKey) != nil {
            return gatewayKey
        }
        // 查找包含 task.id 的会话（可能通过其他方式关联）
        for session in logger.getAllSessions() {
            if session.userRequest.contains(currentTask.inputContext.prefix(20)) {
                return session.id
            }
        }
        return nil
    }

    private var continueSection: some View {
        detailCard(title: "继续处理", tint: .accentColor) {
            VStack(alignment: .leading, spacing: 10) {
                if canContinue {
                    TextField("补充说明、追加要求，或直接点击继续处理...", text: $followUpText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                        .disabled(isSubmitting)
                } else {
                    Text("任务执行中。可以先暂停，或等待本次执行结束后再补充要求。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    primaryActionButton

                    if currentTask.status == .running {
                        Button("暂停") {
                            manager.pauseTask(id: currentTask.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if currentTask.status == .failed {
                        Button("仅重试") {
                            Task { await manager.retryTask(id: currentTask.id) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        Button(continueButtonTitle) {
            submitContinue()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(isSubmitting || !canContinue)
    }

    private func submitContinue() {
        let trimmed = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)

        isSubmitting = true
        Task {
            await manager.continueTask(
                id: currentTask.id,
                with: trimmed.isEmpty ? nil : trimmed
            )

            await MainActor.run {
                if !trimmed.isEmpty {
                    manager.appendLog(
                        id: currentTask.id,
                        message: "用户补充说明：\(trimmed)",
                        source: "UnifiedTaskDetailView"
                    )
                }
                followUpText = ""
                isSubmitting = false
            }
        }
    }

    private func detailCard<Content: View>(title: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(tint)

            content()
        }
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func metaChip(title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch currentTask.status {
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

private struct TaskMessageHistoryList: View {
    let messages: [TaskMessage]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                SwiftUI.ForEach(messages, id: \TaskMessage.id) { (message: TaskMessage) in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(message.role == .user ? Color.blue : Color.green)
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.agentName ?? roleTitle(for: message.role))
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Text(message.content)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 150)
    }

    private func roleTitle(for role: TaskMessage.TaskMessageRole) -> String {
        switch role {
        case .user:
            return "用户"
        case .assistant:
            return "助手"
        case .system:
            return "系统"
        case .cli:
            return "CLI"
        }
    }
}

private struct TaskLogHistoryList: View {
    let logs: [TaskLogEntry]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                SwiftUI.ForEach(logs, id: \TaskLogEntry.id) { (log: TaskLogEntry) in
                    HStack(alignment: .top, spacing: 8) {
                        Text(log.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, alignment: .leading)

                        Text(log.message)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxHeight: 120)
    }
}

#Preview {
    UnifiedTaskManagerView()
        .frame(width: 760, height: 620)
}
