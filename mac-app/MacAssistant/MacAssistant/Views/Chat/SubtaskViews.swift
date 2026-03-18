//
//  SubtaskViews.swift
//  MacAssistant
//
//  子任务列表视图组件
//

import SwiftUI

/// 子任务入口按钮
struct SubtaskEntryButton: View {
    @StateObject private var coordinator = SubtaskCoordinator.shared
    @State private var showSubtaskPanel = false
    
    var body: some View {
        Button(action: { showSubtaskPanel.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12))
                if coordinator.activeSubtasks.count > 0 {
                    Text("\(coordinator.activeSubtasks.count)")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundColor(coordinator.activeSubtasks.count > 0 ? .blue : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(coordinator.activeSubtasks.count > 0 ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .help("子任务列表")
        .popover(isPresented: $showSubtaskPanel, arrowEdge: .top) {
            SubtaskPanelView()
                .frame(width: 320, height: 400)
        }
    }
}

/// 子任务状态筛选
enum SubtaskFilter: String, CaseIterable {
    case pending = "待执行"
    case running = "执行中"
    case completed = "已完成"
}

/// 子任务列表面板
struct SubtaskPanelView: View {
    @StateObject private var coordinator = SubtaskCoordinator.shared
    @State private var showSmartTaskCreation = false
    @State private var selectedFilter: SubtaskFilter = .pending
    
    // 按状态过滤的任务
    private var filteredSubtasks: [Subtask] {
        switch selectedFilter {
        case .pending:
            return coordinator.pendingSubtasks
        case .running:
            return coordinator.runningSubtasks
        case .completed:
            return coordinator.completedSubtasks
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("任务管理")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                
                // 新建任务按钮
                Button(action: { showSmartTaskCreation = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11))
                        Text("新建任务")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue)
                    .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                .help("智能创建新任务")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.05))
            .sheet(isPresented: $showSmartTaskCreation) {
                SmartTaskCreationView()
            }
            
            // 三态标签切换
            HStack(spacing: 0) {
                ForEach(SubtaskFilter.allCases, id: \.self) { filter in
                    FilterTab(
                        title: filter.rawValue,
                        count: countForFilter(filter),
                        isSelected: selectedFilter == filter
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedFilter = filter
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            
            Divider()
            
            // 子任务列表 - 使用LazyVStack优化性能
            if filteredSubtasks.isEmpty {
                EmptyFilterView(filter: selectedFilter)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredSubtasks) { subtask in
                            SubtaskRow(subtask: subtask)
                                .id("subtask-\(subtask.id)")
                                .padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .id("list-\(selectedFilter)-\(filteredSubtasks.count)")
            }
            
            Divider()
            
            // 底部按钮
            HStack {
                Button("清除已完成") {
                    coordinator.clearCompletedSubtasks()
                }
                .disabled(coordinator.completedSubtasks.isEmpty)
                .font(.system(size: 11))
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
    
    // 计算各状态任务数
    private func countForFilter(_ filter: SubtaskFilter) -> Int {
        switch filter {
        case .pending:
            return coordinator.pendingSubtasks.count
        case .running:
            return coordinator.runningSubtasks.count
        case .completed:
            return coordinator.completedSubtasks.count
        }
    }
}

/// 筛选标签
struct FilterTab: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.blue : Color.secondary.opacity(0.5))
                            )
                    }
                }
                .foregroundColor(isSelected ? .primary : .secondary)
                
                // 选中指示器
                Rectangle()
                    .fill(isSelected ? Color.blue : Color.clear)
                    .frame(height: 2)
                    .cornerRadius(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// 按状态筛选的空视图
struct EmptyFilterView: View {
    let filter: SubtaskFilter
    
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: iconName)
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.4))
            
            Text(titleText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            
            Text(detailText)
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var iconName: String {
        switch filter {
        case .pending:
            return "hourglass.circle"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .completed:
            return "checkmark.circle"
        }
    }
    
    private var titleText: String {
        switch filter {
        case .pending:
            return "暂无待执行任务"
        case .running:
            return "暂无执行中任务"
        case .completed:
            return "暂无已完成任务"
        }
    }
    
    private var detailText: String {
        switch filter {
        case .pending:
            return "新建的任务将显示在这里"
        case .running:
            return "正在执行的任务将显示在这里"
        case .completed:
            return "已完成的任务将显示在这里"
        }
    }
}

/// 空子任务视图
struct EmptySubtaskView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("暂无子任务")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            
            Text("复杂请求会自动分解为子任务")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 子任务行
struct SubtaskRow: View, Equatable {
    let subtask: Subtask
    
    static func == (lhs: SubtaskRow, rhs: SubtaskRow) -> Bool {
        lhs.subtask.id == rhs.subtask.id &&
        lhs.subtask.status == rhs.subtask.status &&
        lhs.subtask.result == rhs.subtask.result
    }
    
    var body: some View {
        HStack(spacing: 10) {
            // 状态图标
            statusIcon
            
            VStack(alignment: .leading, spacing: 3) {
                Text(subtask.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                
                Text(subtask.description)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                // 策略标签
                HStack(spacing: 4) {
                    strategyBadge
                    
                    if let executionTime = subtask.executionTime {
                        Text(String(format: "%.1fs", executionTime))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .opacity(subtask.status == .completed ? 0.6 : 1.0)
    }
    
    private var statusIcon: some View {
        let (iconName, color): (String, Color) = {
            switch subtask.status {
            case .pending:
                return ("circle", .secondary)
            case .running:
                return ("arrow.triangle.2.circlepath", .blue)
            case .completed:
                return ("checkmark.circle.fill", .green)
            case .failed:
                return ("xmark.circle.fill", .red)
            case .cancelled:
                return ("minus.circle.fill", .orange)
            }
        }()
        
        return Image(systemName: iconName)
            .font(.system(size: 14))
            .foregroundColor(color)
            .frame(width: 20)
    }
    
    private var strategyBadge: some View {
        let (text, color): (String, Color) = {
            switch subtask.strategy {
            case .useBuiltin:
                return ("本地", .purple)
            case .useSkill:
                return ("Skill", .orange)
            case .useAgent:
                return ("Agent", .blue)
            case .useOpenClaw:
                return ("OpenClaw", .green)
            case .custom:
                return ("通用", .gray)
            }
        }()
        
        return Text(text)
            .font(.system(size: 8, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(3)
    }
}

#Preview {
    SubtaskPanelView()
        .frame(width: 320, height: 400)
}
