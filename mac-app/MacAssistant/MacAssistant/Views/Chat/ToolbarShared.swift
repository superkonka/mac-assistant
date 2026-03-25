//
//  ToolbarShared.swift
//  MacAssistant
//
//  工具栏共享组件
//

import SwiftUI

// MARK: - 工具栏按钮状态

enum ToolbarButtonState {
    case idle
    case checking          // 正在检查/加载
    case active(count: Int) // 有活跃项（带数量）
    case warning(count: Int) // 有警告（带数量）
    case error(count: Int)   // 有错误（带数量）
    
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
    
    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}

// MARK: - 脉冲动画点

struct PulsingDot: View {
    let color: Color
    @State private var isPulsing = false
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .opacity(isPulsing ? 0.4 : 1)
            .scaleEffect(isPulsing ? 1.3 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear {
                isPulsing = true
            }
    }
}

// MARK: - 徽章视图

struct BadgeView: View {
    enum Style {
        case subtle      // subtle, blend with background
        case highlighted // prominent, for important counts
        case urgent      // high contrast, for errors
    }
    
    let count: Int
    let style: Style
    let color: Color
    
    var body: some View {
        Text("\(min(count, 99))")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(color.opacity(0.3), lineWidth: 0.5)
            )
    }
    
    private var foregroundColor: Color {
        switch style {
        case .subtle:
            return color
        case .highlighted, .urgent:
            return .white
        }
    }
    
    private var backgroundColor: Color {
        switch style {
        case .subtle:
            return color.opacity(0.15)
        case .highlighted:
            return color
        case .urgent:
            return color.opacity(0.9)
        }
    }
}

// MARK: - 工具栏分隔线

struct ToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 8)
    }
}

// MARK: - 工具栏图标按钮（优化版）

struct ToolbarIconButton: View {
    let systemImage: String
    let helpText: String
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.7))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(isHovered ? 0.15 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                )
                .scaleEffect(isHovered ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
