//
//  RuntimeDoctorView.swift
//  MacAssistant
//
//  运行时健康状态视图（原生运行时 + 兼容层）
//

import SwiftUI

// MARK: - 运行时状态入口（优化版）

struct RuntimeStatusEntry: View {
    @ObservedObject var doctor: RuntimeDoctor
    let action: () -> Void
    
    @State private var isHovered = false
    @State private var rotationAngle: Double = 0
    
    private var buttonState: ToolbarButtonState {
        if doctor.isRefreshing {
            return .checking
        }
        switch doctor.snapshot.status {
        case .healthy:
            return .idle
        case .fallback, .needsAttention:
            return .warning(count: 0)
        case .missingRuntime:
            return .error(count: 1)
        case .checking:
            return .checking
        }
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                // 动态图标
                ZStack {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(foregroundColor)
                        .rotationEffect(.degrees(buttonState.isChecking ? rotationAngle : 0))
                        .animation(
                            buttonState.isChecking 
                                ? .linear(duration: 2).repeatForever(autoreverses: false)
                                : .default,
                            value: rotationAngle
                        )
                        .onAppear {
                            if buttonState.isChecking {
                                rotationAngle = 360
                            }
                        }
                        .onChange(of: buttonState.isChecking) { isChecking in
                            rotationAngle = isChecking ? 360 : 0
                        }
                }
                .frame(width: 16, height: 16)
                
                Text(labelText)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                
                // 微状态指示器
                if buttonState.isChecking {
                    PulsingDot(color: foregroundColor)
                }
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
                    .shadow(
                        color: shadowColor.opacity(isHovered ? 0.15 : 0.08),
                        radius: isHovered ? 3 : 2,
                        x: 0,
                        y: isHovered ? 1 : 0.5
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        borderColor.opacity(0.25),
                        lineWidth: 1
                    )
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(doctor.snapshot.summary)
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    // MARK: - 视觉属性计算
    
    private var iconName: String {
        switch buttonState {
        case .checking:
            return "arrow.clockwise"
        case .idle:
            return "checkmark.shield"
        case .active:
            return "checkmark.shield"
        case .warning:
            return "exclamationmark.shield"
        case .error:
            return "xmark.shield"
        }
    }
    
    private var labelText: String {
        switch buttonState {
        case .checking:
            return "检查中"
        case .idle:
            return "就绪"
        case .warning:
            return "注意"
        case .error:
            return "异常"
        case .active:
            return "运行中"
        }
    }
    
    private var foregroundColor: Color {
        switch buttonState {
        case .checking:
            return .secondary
        case .idle:
            return .green
        case .active:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
    
    private var backgroundColor: Color {
        switch buttonState {
        case .checking:
            return Color.secondary.opacity(0.08)
        case .idle:
            return Color.green.opacity(0.1)
        case .active:
            return Color.blue.opacity(0.1)
        case .warning:
            return Color.orange.opacity(0.1)
        case .error:
            return Color.red.opacity(0.1)
        }
    }
    
    private var borderColor: Color {
        switch buttonState {
        case .checking:
            return .secondary
        case .idle:
            return .green
        case .active:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
    
    private var shadowColor: Color {
        switch buttonState {
        case .checking:
            return .gray
        case .idle:
            return .green
        case .active:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

// MARK: - 运行时医生面板视图

struct RuntimeDoctorPanelView: View {
    @ObservedObject var doctor: RuntimeDoctor

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    
                    if !doctor.snapshot.availableProviders.isEmpty {
                        providersSection
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 460, height: 400)
        .background(Color(NSColor.controlBackgroundColor))
        .task {
            doctor.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: doctor.snapshot.status.iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("运行时状态")
                    .font(.system(size: 17, weight: .semibold))
                Text(doctor.snapshot.status.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(statusColor)
            }

            Spacer()

            Button {
                doctor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("重新检查运行时状态")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(doctor.snapshot.summary)
                .font(.system(size: 14, weight: .semibold))

            Text(doctor.snapshot.detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text("建议：\(doctor.snapshot.recommendation)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)

            HStack(spacing: 10) {
                statusTag(title: doctor.snapshot.runtimeType, icon: "cpu")
            }

            if let lastCheckedAt = doctor.snapshot.lastCheckedAt {
                Text("最后检查：\(lastCheckedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(statusColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(statusColor.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("可用提供商")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            
            // 简化为垂直列表
            VStack(alignment: .leading, spacing: 6) {
                ForEach(doctor.snapshot.availableProviders.prefix(5), id: \.self) { provider in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text(provider)
                            .font(.system(size: 11))
                    }
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statusTag(title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.55))
        .clipShape(Capsule(style: .continuous))
    }

    private var statusColor: Color {
        switch doctor.snapshot.status {
        case .checking:
            return .secondary
        case .healthy:
            return .green
        case .fallback:
            return .orange
        case .needsAttention:
            return .orange
        case .missingRuntime:
            return .red
        }
    }
}

// MARK: - 兼容旧名称

@available(*, deprecated, renamed: "RuntimeStatusEntry")
typealias OpenClawStatusEntry = RuntimeStatusEntry

@available(*, deprecated, renamed: "RuntimeDoctorPanelView")
typealias OpenClawDoctorPanelView = RuntimeDoctorPanelView


