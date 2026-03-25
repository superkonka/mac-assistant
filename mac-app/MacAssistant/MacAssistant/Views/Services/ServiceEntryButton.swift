//
//  ServiceEntryButton.swift
//  MacAssistant
//
//  服务入口按钮 - 优化版状态管理
//

import SwiftUI

struct ServiceEntryButton: View {
    @StateObject private var manager = ServiceManager.shared
    @State private var showPanel = false
    @State private var isHovered = false
    
    private var runningCount: Int {
        manager.services.filter { $0.state == .running }.count
    }
    
    private var errorCount: Int {
        manager.services.filter { $0.state == .error }.count
    }
    
    private var buttonState: ToolbarButtonState {
        if manager.isOperating {
            return .checking
        }
        if errorCount > 0 {
            return .error(count: errorCount)
        }
        if runningCount > 0 {
            return .active(count: runningCount)
        }
        return .idle
    }
    
    var body: some View {
        Button(action: { showPanel = true }) {
            HStack(spacing: 5) {
                // 图标带微动画
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.pulse, options: .repeating, value: buttonState.isChecking)
                
                Text("服务")
                    .font(.system(size: 11, weight: .semibold))
                
                // 智能徽章
                if case let .active(count) = buttonState, count > 0 {
                    BadgeView(
                        count: count,
                        style: .subtle,
                        color: .green
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
                        borderColor.opacity(0.25),
                        lineWidth: 1
                    )
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(serviceHelpText)
        .popover(isPresented: $showPanel, arrowEdge: .bottom) {
            ServiceManagerView()
                .frame(width: 500, height: 450)
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    // MARK: - 视觉属性
    
    private var iconName: String {
        switch buttonState {
        case .checking:
            return "server.rack"
        case .idle:
            return "server.rack"
        case .active:
            return "server.rack.fill"
        case .error:
            return "exclamationmark.triangle"
        case .warning:
            return "server.rack"
        }
    }
    
    private var foregroundColor: Color {
        switch buttonState {
        case .idle, .checking:
            return .primary
        case .active:
            return .green
        case .error:
            return .red
        case .warning:
            return .orange
        }
    }
    
    private var backgroundColor: Color {
        switch buttonState {
        case .idle:
            return Color.secondary.opacity(0.1)
        case .checking:
            return Color.secondary.opacity(0.08)
        case .active:
            return Color.green.opacity(0.12)
        case .error:
            return Color.red.opacity(0.1)
        case .warning:
            return Color.orange.opacity(0.12)
        }
    }
    
    private var borderColor: Color {
        switch buttonState {
        case .idle, .checking:
            return .secondary
        case .active:
            return .green
        case .error:
            return .red
        case .warning:
            return .orange
        }
    }
    
    private var shadowColor: Color {
        switch buttonState {
        case .idle, .checking:
            return .gray
        case .active:
            return .green
        case .error:
            return .red
        case .warning:
            return .orange
        }
    }
    
    private var serviceHelpText: String {
        switch buttonState {
        case .idle:
            return "服务管理 - 所有服务已停止"
        case .checking:
            return "服务管理 - 正在检查状态..."
        case .active(let count):
            return "服务管理 - \(count) 个服务运行中"
        case .error(let count):
            return "服务管理 - \(count) 个服务异常"
        case .warning:
            return "服务管理"
        }
    }
}

#Preview {
    HStack(spacing: 12) {
        ServiceEntryButton()
    }
    .padding()
}
