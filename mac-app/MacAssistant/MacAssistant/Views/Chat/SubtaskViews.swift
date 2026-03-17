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

/// 子任务列表面板
struct SubtaskPanelView: View {
    @StateObject private var coordinator = SubtaskCoordinator.shared
    @State private var showSmartTaskCreation = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("子任务")
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
                .padding(.trailing, 8)
                
                if coordinator.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 8)
                }
                
                Text("\(coordinator.activeSubtasks.count) 进行中")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.05))
            .sheet(isPresented: $showSmartTaskCreation) {
                SmartTaskCreationView()
            }
            
            Divider()
            
            // 子任务列表
            if coordinator.activeSubtasks.isEmpty && coordinator.completedSubtasks.isEmpty {
                EmptySubtaskView()
            } else {
                List {
                    if !coordinator.activeSubtasks.isEmpty {
                        Section("进行中") {
                            ForEach(coordinator.activeSubtasks) { subtask in
                                SubtaskRow(subtask: subtask)
                            }
                        }
                    }
                    
                    if !coordinator.completedSubtasks.isEmpty {
                        Section("已完成") {
                            ForEach(coordinator.completedSubtasks) { subtask in
                                SubtaskRow(subtask: subtask)
                            }
                        }
                    }
                }
                .listStyle(.plain)
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
struct SubtaskRow: View {
    let subtask: Subtask
    
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
