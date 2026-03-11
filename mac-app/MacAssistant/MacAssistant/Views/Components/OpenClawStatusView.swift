//
//  OpenClawStatusView.swift
//  MacAssistant
//
//  OpenClaw 状态面板 - 用户可见状态、修复、重装入口
//

import SwiftUI
import AppKit

/// OpenClaw 运行状态（用户可见）
enum OpenClawRuntimeStatus: Equatable {
    case unknown           // 未知/检查中
    case healthy           // 正常运行
    case degraded          // 性能下降但可用
    case unhealthy         // 不可用
    case repairing         // 正在修复
    case reinstalling      // 正在重装
    case needsReinstall    // 需要重装
    
    var icon: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .healthy: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.circle.fill"
        case .unhealthy: return "xmark.circle.fill"
        case .repairing: return "arrow.triangle.2.circlepath"
        case .reinstalling: return "arrow.down.circle.fill"
        case .needsReinstall: return "exclamationmark.triangle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .unknown: return .gray
        case .healthy: return .green
        case .degraded: return .orange
        case .unhealthy: return .red
        case .repairing: return .blue
        case .reinstalling: return .purple
        case .needsReinstall: return .red
        }
    }
    
    var title: String {
        switch self {
        case .unknown: return "检查中..."
        case .healthy: return "运行正常"
        case .degraded: return "响应较慢"
        case .unhealthy: return "连接失败"
        case .repairing: return "正在修复..."
        case .reinstalling: return "正在重装..."
        case .needsReinstall: return "需要重装"
        }
    }
    
    var description: String {
        switch self {
        case .unknown:
            return "正在检查 OpenClaw 运行状态"
        case .healthy:
            return "OpenClaw 运行正常，可以处理请求"
        case .degraded:
            return "OpenClaw 响应较慢，可能影响体验"
        case .unhealthy:
            return "无法连接到 OpenClaw，正在使用备用模式"
        case .repairing:
            return "正在尝试修复 OpenClaw..."
        case .reinstalling:
            return "正在重新安装 OpenClaw，请稍候..."
        case .needsReinstall:
            return "OpenClaw 损坏，需要重新安装"
        }
    }
}

/// OpenClaw 状态面板
struct OpenClawStatusView: View {
    @StateObject private var viewModel = OpenClawStatusViewModel()
    @State private var isExpanded = false
    @State private var showMonitorPanel = false
    @State private var showReinstallConfirm = false
    
    // 最小化模式（显示在状态栏）
    var compactMode: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 状态栏按钮
            statusButton
            
            // 展开详情
            if isExpanded {
                expandedDetails
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .background(backgroundView)
        .sheet(isPresented: $showMonitorPanel) {
            OpenClawMonitorPanel(viewModel: viewModel)
        }
        .alert("重新安装 OpenClaw", isPresented: $showReinstallConfirm) {
            Button("取消", role: .cancel) { }
            Button("确认重装", role: .destructive) {
                viewModel.reinstallOpenClaw()
            }
        } message: {
            Text("这将删除现有的 OpenClaw 并从 App Bundle 重新安装。你的对话历史不会丢失。")
        }
        .onAppear {
            viewModel.startMonitoring()
        }
        .onDisappear {
            viewModel.stopMonitoring()
        }
    }
    
    // MARK: - 子视图
    
    private var statusButton: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: viewModel.status.icon)
                    .font(.system(size: compactMode ? 12 : 14))
                    .foregroundColor(viewModel.status.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: viewModel.status == .repairing)
                
                if !compactMode {
                    Text("OpenClaw")
                        .font(.system(size: 12, weight: .medium))
                    
                    Text(viewModel.status.title)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, compactMode ? 6 : 10)
            .padding(.vertical, compactMode ? 4 : 6)
            .background(viewModel.status.color.opacity(0.1))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(viewModel.status.color.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .help(viewModel.status.description)
    }
    
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 状态详情
            statusDetailSection
            
            Divider()
            
            // 操作按钮
            actionButtonsSection
            
            Divider()
            
            // 快捷入口
            quickLinksSection
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        .padding(.top, 4)
    }
    
    private var statusDetailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: viewModel.status.icon)
                    .foregroundColor(viewModel.status.color)
                    .font(.title3)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.status.title)
                        .font(.system(size: 13, weight: .semibold))
                    
                    Text(viewModel.status.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            // 技术详情
            if viewModel.showTechnicalDetails {
                technicalDetails
            }
        }
    }
    
    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailRow(label: "版本", value: viewModel.versionInfo)
            DetailRow(label: "响应时间", value: viewModel.responseTimeText)
            DetailRow(label: "最后检查", value: viewModel.lastCheckTimeText)
            DetailRow(label: "错误次数", value: "\(viewModel.errorCount)")
            
            if let errorMessage = viewModel.lastErrorMessage {
                Text("错误: \(errorMessage)")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(4)
    }
    
    private var actionButtonsSection: some View {
        VStack(spacing: 8) {
            // 主要操作
            HStack(spacing: 8) {
                if viewModel.status == .unhealthy || viewModel.status == .degraded {
                    ActionButton(
                        title: "尝试修复",
                        icon: "wrench.and.screwdriver",
                        color: .blue,
                        isLoading: viewModel.isRepairing
                    ) {
                        viewModel.attemptRepair()
                    }
                }
                
                if viewModel.status == .needsReinstall || viewModel.status == .unhealthy {
                    ActionButton(
                        title: "重装",
                        icon: "arrow.down.circle",
                        color: .orange,
                        isLoading: viewModel.isReinstalling
                    ) {
                        showReinstallConfirm = true
                    }
                }
            }
            
            // 次要操作
            HStack(spacing: 8) {
                Button(action: { viewModel.checkHealth() }) {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(viewModel.isChecking)
                
                Button(action: { showMonitorPanel = true }) {
                    Label("监控面板", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11))
                }
                .buttonStyle(BorderedButtonStyle())
            }
        }
    }
    
    private var quickLinksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("快捷操作")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                QuickLinkButton(title: "查看日志", icon: "doc.text") {
                    viewModel.openLogFile()
                }
                
                QuickLinkButton(title: "配置目录", icon: "folder") {
                    viewModel.openConfigDirectory()
                }
                
                QuickLinkButton(title: "重启 Gateway", icon: "arrow.clockwise") {
                    viewModel.restartGateway()
                }
            }
        }
    }
    
    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.clear)
    }
}

// MARK: - 辅助组件

private struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.primary)
            
            Spacer()
        }
    }
}

private struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    var isLoading: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color)
            .cornerRadius(6)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isLoading)
    }
}

private struct QuickLinkButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 9))
            }
            .foregroundColor(.secondary)
            .frame(width: 50)
            .padding(.vertical, 6)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(4)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 监控面板

struct OpenClawMonitorPanel: View {
    @ObservedObject var viewModel: OpenClawStatusViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                // 当前状态卡片
                statusCard
                
                // 性能指标
                performanceSection
                
                // 自愈历史
                healingHistorySection
                
                // 配置信息
                configurationSection
            }
            .listStyle(.sidebar)
            .navigationTitle("OpenClaw 监控面板")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { viewModel.checkHealth() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isChecking)
                }
            }
        }
        .frame(width: 600, height: 500)
    }
    
    private var statusCard: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: viewModel.status.icon)
                    .font(.system(size: 48))
                    .foregroundColor(viewModel.status.color)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.status.title)
                        .font(.title2.bold())
                    
                    Text(viewModel.status.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if let uptime = viewModel.uptimeText {
                        Text("运行时间: \(uptime)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                }
                
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }
    
    private var performanceSection: some View {
        Section("性能指标") {
            MetricRow(title: "平均响应时间", value: viewModel.responseTimeText, icon: "speedometer")
            MetricRow(title: "成功率", value: viewModel.successRateText, icon: "checkmark.seal")
            MetricRow(title: "总请求数", value: "\(viewModel.totalRequests)", icon: "number")
            MetricRow(title: "错误次数", value: "\(viewModel.errorCount)", icon: "exclamationmark.triangle")
        }
    }
    
    private var healingHistorySection: some View {
        Section("自愈历史") {
            if viewModel.healingHistory.isEmpty {
                Text("暂无自愈记录")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(viewModel.healingHistory.prefix(10)) { record in
                    HealingHistoryRow(record: record)
                }
            }
        }
    }
    
    private var configurationSection: some View {
        Section("配置") {
            ConfigRow(title: "安装路径", value: viewModel.installPath)
            ConfigRow(title: "配置文件", value: viewModel.configPath)
            ConfigRow(title: "日志文件", value: viewModel.logPath)
            ConfigRow(title: "Gateway 端口", value: "\(viewModel.gatewayPort)")
        }
    }
}

private struct MetricRow: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline)
            
            Spacer()
            
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct HealingHistoryRow: View {
    let record: HealingRecord
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(record.success ? .green : .red)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(record.action)
                    .font(.subheadline)
                
                Text(record.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private struct ConfigRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
            
            Spacer()
            
            Text(value)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 250, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 数据模型

struct HealingRecord: Identifiable {
    let id = UUID()
    let timestamp: Date
    let action: String
    let success: Bool
    let message: String?
}

// MARK: - 预览

#Preview {
    VStack {
        OpenClawStatusView(compactMode: false)
        Divider()
        OpenClawStatusView(compactMode: true)
    }
    .padding()
    .frame(width: 400)
}
