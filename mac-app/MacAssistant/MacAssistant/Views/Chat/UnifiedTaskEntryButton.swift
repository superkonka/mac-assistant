//
//  UnifiedTaskEntryButton.swift
//  MacAssistant
//
//  任务中心入口 - 统一最近任务与任务管理展示
//

import SwiftUI

struct UnifiedTaskEntryButton: View {
    @StateObject private var manager = UnifiedTaskManager.shared
    @State private var showTaskPanel = false
    @State private var isHovered = false

    private var highlightedCount: Int {
        manager.statistics.pending + manager.statistics.running + manager.statistics.failed
    }

    private var buttonState: ToolbarButtonState {
        if highlightedCount == 0 {
            return .idle
        }
        if manager.statistics.failed > 0 {
            return .error(count: highlightedCount)
        }
        return .active(count: highlightedCount)
    }

    var body: some View {
        Button {
            showTaskPanel.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .semibold))

                Text("任务")
                    .font(.system(size: 11, weight: .semibold))

                // 智能徽章
                if case let .active(count) = buttonState, count > 0 {
                    BadgeView(
                        count: count,
                        style: .highlighted,
                        color: .blue
                    )
                } else if case let .error(count) = buttonState, count > 0 {
                    BadgeView(
                        count: count,
                        style: .urgent,
                        color: .red
                    )
                }
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor)
                    .shadow(
                        color: shadowColor.opacity(isHovered ? 0.2 : 0.1),
                        radius: isHovered ? 3 : 2,
                        x: 0,
                        y: isHovered ? 1 : 0.5
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        borderGradient,
                        lineWidth: 1
                    )
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(taskHelpText)
        .accessibilityLabel("任务中心")
        .popover(isPresented: $showTaskPanel, arrowEdge: .top) {
            UnifiedTaskPanelView(onClose: { showTaskPanel = false })
                .frame(width: 440, height: 500)
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - 视觉属性

    private var foregroundColor: Color {
        switch buttonState {
        case .idle:
            return .primary
        case .active, .error:
            return .white
        case .warning:
            return .primary
        case .checking:
            return .secondary
        }
    }

    private var backgroundColor: Color {
        switch buttonState {
        case .idle:
            return Color.secondary.opacity(0.1)
        case .active:
            return Color.blue
        case .error:
            return Color.red.opacity(0.9)
        case .warning:
            return Color.orange.opacity(0.15)
        case .checking:
            return Color.secondary.opacity(0.08)
        }
    }

    private var borderGradient: some ShapeStyle {
        switch buttonState {
        case .idle:
            return Color.secondary.opacity(0.15)
        case .active:
            return Color.blue.opacity(0.3)
        case .error:
            return Color.red.opacity(0.4)
        case .warning:
            return Color.orange.opacity(0.3)
        case .checking:
            return Color.secondary.opacity(0.15)
        }
    }

    private var shadowColor: Color {
        switch buttonState {
        case .idle, .checking:
            return .gray
        case .active:
            return .blue
        case .error:
            return .red
        case .warning:
            return .orange
        }
    }

    private var taskHelpText: String {
        switch buttonState {
        case .idle:
            return "任务中心 - 暂无活跃任务"
        case .active(let count):
            return "任务中心 - \(count) 个活跃任务"
        case .error(let count):
            return "任务中心 - \(count) 个任务需要关注"
        case .warning(let count):
            return "任务中心 - \(count) 个任务待处理"
        case .checking:
            return "任务中心 - 正在同步..."
        }
    }
}

private enum TaskPanelSection: String, CaseIterable {
    case attention = "待处理"
    case active = "执行中"
    case upcoming = "已排期"
    case results = "结果"

    var icon: String {
        switch self {
        case .attention:
            return "exclamationmark.bubble"
        case .active:
            return "arrow.triangle.2.circlepath"
        case .upcoming:
            return "calendar.badge.clock"
        case .results:
            return "checkmark.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .attention:
            return "失败、等待输入或需要你继续推进"
        case .active:
            return "正在执行或刚开始的任务"
        case .upcoming:
            return "未来 24 小时内会自动触发"
        case .results:
            return "最近完成的结果摘要"
        }
    }

    var emptyTitle: String {
        switch self {
        case .attention:
            return "当前没有待处理任务"
        case .active:
            return "当前没有执行中的任务"
        case .upcoming:
            return "当前没有已排期任务"
        case .results:
            return "当前没有最近结果"
        }
    }
}

struct UnifiedTaskPanelView: View {
    let onClose: () -> Void

    @StateObject private var manager = UnifiedTaskManager.shared
    @State private var selectedSection: TaskPanelSection = .attention
    @State private var didInitializeSectionSelection = false
    @State private var showFullManager = false
    @State private var showSmartTaskCreation = false
    @State private var showClearCompletedConfirmation = false

    private var panelSnapshot: TaskCenterPanelSnapshot {
        manager.taskCenterPanelSnapshot()
    }

    private var focusTasks: [UnifiedTask] {
        Array(tasks(for: selectedSection).prefix(selectedSection == .results ? 4 : 6))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summary
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    focusSection
                    footerSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .background(Color(.windowBackgroundColor))
        .sheet(isPresented: $showFullManager) {
            UnifiedTaskManagerView()
                .frame(minWidth: 700, minHeight: 580)
        }
        .sheet(isPresented: $showSmartTaskCreation) {
            SmartTaskCreationView()
        }
        .alert("确认清空", isPresented: $showClearCompletedConfirmation) {
            Button("清空", role: .destructive) {
                manager.removeCompletedTasks()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要清空所有已完成任务吗？此操作不可撤销。")
        }
        .onAppear {
            initializeSelectedSectionIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("任务中心")
                    .font(.system(size: 16, weight: .semibold))

                Text("只保留需要关注的任务，完整检索放到完整管理里")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showSmartTaskCreation = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("新建任务")

            Button {
                openFullManager()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("打开完整任务管理器")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var summary: some View {
        HStack(spacing: 8) {
            ForEach(TaskPanelSection.allCases, id: \.self) { section in
                TaskCenterSectionChip(
                    title: section.rawValue,
                    value: count(for: section),
                    color: color(for: section),
                    icon: section.icon,
                    isSelected: selectedSection == section
                ) {
                    selectedSection = section
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
    }

    private var focusSection: some View {
        TaskCenterSectionCard(
            title: selectedSection.rawValue,
            subtitle: selectedSection.subtitle,
            trailingTitle: "完整管理",
            trailingAction: { openFullManager() }
        ) {
            VStack(spacing: 8) {
                if focusTasks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: selectedSection.icon)
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)

                        Text(selectedSection.emptyTitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    ForEach(focusTasks) { task in
                        TaskCenterRow(
                            task: task,
                            showsDescription: true,
                            detailOverride: detail(for: task, in: selectedSection),
                            trailingText: trailingText(for: task, in: selectedSection),
                            action: action(for: task),
                            onActionTap: { handlePrimaryAction(for: task) },
                            onRowTap: { openFullManager(focusedTaskID: task.id) }
                        )
                    }

                    if hiddenSubtaskCount(for: selectedSection) > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.stack.badge.person.crop")
                                .font(.system(size: 11))
                            Text("另有 \(hiddenSubtaskCount(for: selectedSection)) 个子任务已收起，避免和主任务混在一起。")
                                .font(.system(size: 11))
                            Spacer()
                            Button("查看") {
                                openFullManager()
                            }
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var footerSection: some View {
        HStack(spacing: 10) {
            Text("今日完成 \(panelSnapshot.completedTodayCount)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            if manager.statistics.completed > 0 {
                Button("清空已完成") {
                    showClearCompletedConfirmation = true
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }

            Button("查看全部") {
                openFullManager()
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
        }
    }

    private func tasks(for section: TaskPanelSection) -> [UnifiedTask] {
        switch section {
        case .attention:
            return panelSnapshot.attentionTasks
        case .active:
            return panelSnapshot.activeTasks
        case .upcoming:
            return panelSnapshot.upcomingTasks
        case .results:
            return panelSnapshot.recentResultTasks
        }
    }

    private func initializeSelectedSectionIfNeeded() {
        guard !didInitializeSectionSelection else { return }
        didInitializeSectionSelection = true

        if tasks(for: selectedSection).isEmpty,
           let firstNonEmptySection = TaskPanelSection.allCases.first(where: { !tasks(for: $0).isEmpty }) {
            selectedSection = firstNonEmptySection
        }
    }

    private func count(for section: TaskPanelSection) -> Int {
        tasks(for: section).count
    }

    private func hiddenSubtaskCount(for section: TaskPanelSection) -> Int {
        switch section {
        case .attention:
            return panelSnapshot.hiddenAttentionSubtasks
        case .active:
            return panelSnapshot.hiddenActiveSubtasks
        case .upcoming:
            return panelSnapshot.hiddenUpcomingSubtasks
        case .results:
            return panelSnapshot.hiddenResultSubtasks
        }
    }

    private func color(for section: TaskPanelSection) -> Color {
        switch section {
        case .attention:
            return .orange
        case .active:
            return .blue
        case .upcoming:
            return .indigo
        case .results:
            return .green
        }
    }

    private func action(for task: UnifiedTask) -> TaskCenterAction? {
        switch task.status {
        case .pending:
            if let scheduledTime = task.scheduledTime, scheduledTime > Date() {
                return TaskCenterAction(icon: "play.fill", label: "立即执行", tint: .blue)
            }
            if task.type == .exceptionRecovery {
                return TaskCenterAction(icon: "arrow.clockwise", label: "继续", tint: .orange)
            }
            return TaskCenterAction(icon: "play.fill", label: "开始", tint: .blue)
        case .paused:
            return TaskCenterAction(icon: "play.fill", label: "继续", tint: .blue)
        case .failed:
            return TaskCenterAction(icon: "arrow.clockwise", label: "重试", tint: .orange)
        case .running:
            return TaskCenterAction(icon: "pause.fill", label: "暂停", tint: .orange)
        case .completed:
            return nil
        }
    }

    private func handlePrimaryAction(for task: UnifiedTask) {
        switch task.status {
        case .pending, .paused:
            Task {
                await manager.startTask(id: task.id)
            }
        case .failed:
            Task {
                await manager.retryTask(id: task.id)
            }
        case .running:
            manager.pauseTask(id: task.id)
        case .completed:
            openFullManager(focusedTaskID: task.id)
        }
    }

    private func openFullManager(focusedTaskID: String? = nil) {
        if let focusedTaskID {
            manager.focusTask(id: focusedTaskID)
        } else {
            manager.clearFocusedTask()
        }

        showFullManager = true
    }

    private func attentionDetail(for task: UnifiedTask) -> String {
        if let error = task.errorMessage, !error.isEmpty {
            return error
        }
        if task.type == .exceptionRecovery {
            return "请求处理中断，点击继续恢复"
        }
        return task.description.isEmpty ? task.strategy.displayName : task.description
    }

    private func runningDetail(for task: UnifiedTask) -> String {
        if !task.description.isEmpty {
            return task.description
        }
        if !task.inputContext.isEmpty {
            return String(task.inputContext.prefix(50))
        }
        return task.strategy.displayName
    }

    private func upcomingDetail(for task: UnifiedTask) -> String {
        if !task.description.isEmpty {
            return task.description
        }

        guard let scheduled = task.scheduledTime else {
            return "已排期，等待触发"
        }

        return "计划执行 \(absoluteDateTime(for: scheduled))"
    }

    private func recentResultDetail(for task: UnifiedTask) -> String {
        if let result = task.result, !result.isEmpty {
            return String(result.prefix(80))
        }
        return task.description.isEmpty ? "已完成" : task.description
    }

    private func detail(for task: UnifiedTask, in section: TaskPanelSection) -> String {
        switch section {
        case .attention:
            return attentionDetail(for: task)
        case .active:
            return runningDetail(for: task)
        case .upcoming:
            return upcomingDetail(for: task)
        case .results:
            return recentResultDetail(for: task)
        }
    }

    private func trailingText(for task: UnifiedTask, in section: TaskPanelSection) -> String {
        switch section {
        case .upcoming:
            return relativeTime(for: task.scheduledTime ?? task.updatedAt)
        case .results:
            return relativeTime(for: task.completedAt ?? task.updatedAt)
        case .attention, .active:
            return relativeTime(for: task.updatedAt)
        }
    }

    private func relativeTime(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteDateTime(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

private struct TaskCenterSectionChip: View {
    let title: String
    let value: Int
    let color: Color
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                Text("\(value)")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(isSelected ? .white : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? color : color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct TaskCenterSectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let trailingTitle: String?
    let trailingAction: (() -> Void)?
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String,
        trailingTitle: String? = nil,
        trailingAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailingTitle = trailingTitle
        self.trailingAction = trailingAction
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let trailingTitle, let trailingAction {
                    Button(trailingTitle, action: trailingAction)
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                }
            }

            content
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct TaskCenterAction {
    let icon: String
    let label: String
    let tint: Color
}

private struct TaskCenterRow: View {
    let task: UnifiedTask
    let showsDescription: Bool
    let detailOverride: String?
    let trailingText: String?
    let action: TaskCenterAction?
    let onActionTap: () -> Void
    let onRowTap: () -> Void

    private var detailText: String {
        if let detailOverride, !detailOverride.isEmpty {
            return detailOverride
        }
        if task.status == .failed, let error = task.errorMessage, !error.isEmpty {
            return error
        }
        if task.status == .completed, let result = task.result, !result.isEmpty {
            return String(result.prefix(40))
        }
        if !task.description.isEmpty {
            return task.description
        }
        if !task.inputContext.isEmpty {
            return String(task.inputContext.prefix(40))
        }
        return task.strategy.displayName
    }

    private var timeText: String {
        if let trailingText, !trailingText.isEmpty {
            return trailingText
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: task.updatedAt, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 10) {
            TaskStatusIcon(status: task.status)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    if task.type == .exceptionRecovery {
                        Text("异常恢复")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }

                if showsDescription {
                    Text(detailText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(timeText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            if let action {
                Button {
                    onActionTap()
                } label: {
                    Image(systemName: action.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(action.tint)
                        .frame(width: 24, height: 24)
                        .background(action.tint.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(action.label)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: onRowTap)
    }
}

#Preview {
    UnifiedTaskPanelView(onClose: {})
        .frame(width: 460, height: 560)
}
