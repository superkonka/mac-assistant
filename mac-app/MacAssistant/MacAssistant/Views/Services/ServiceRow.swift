//
//  ServiceRow.swift
//  MacAssistant
//
//  服务行组件
//

import SwiftUI

struct ServiceRow: View {
    let service: ServiceDefinition
    @StateObject private var manager = ServiceManager.shared
    @StateObject private var unifiedState = UnifiedServiceState.shared
    @StateObject private var healthEngine = HealthMonitorEngine.shared
    
    /// 使用 UnifiedServiceState 获取最新状态
    private var unifiedInfo: UnifiedServiceRuntimeInfo? {
        unifiedState.runtimeInfos[service.id]
    }
    
    /// 兼容原有逻辑，优先使用统一状态
    private var runtimeInfo: ServiceRuntimeInfo? {
        manager.runtimeInfos[service.id]
    }
    
    /// 状态优先级：UnifiedState > ServiceManager > unknown
    private var status: ServiceRuntimeStatus {
        // 优先使用 UnifiedServiceState 的状态（更实时）
        if let unifiedStatus = unifiedInfo?.status,
           let lastUpdated = unifiedInfo?.lastUpdated,
           lastUpdated.timeIntervalSinceNow > -60 { // 1分钟内有效
            return unifiedStatus
        }
        // 回退到原有状态
        return runtimeInfo?.status ?? .unknown
    }
    
    /// AI 是否正在处理此服务的操作
    private var isAIProcessing: Bool {
        manager.hasActiveTask(for: service.id)
    }
    
    /// 访问 URL 显示
    private var accessInfo: String? {
        unifiedInfo?.internalAccessURL ?? unifiedInfo?.externalAccessURL
    }
    
    /// 网络访问信息
    @StateObject private var networkManager = NetworkAccessManager.shared
    
    private var networkInfo: NetworkAccessInfo? {
        networkManager.serviceAccessInfos[service.id]
    }
    
    /// 健康状态
    private var healthStatus: HealthStatus? {
        healthEngine.monitorStatuses[service.id]
    }
    
    /// 是否正在被健康监控
    private var isMonitored: Bool {
        healthEngine.isMonitoring(serviceID: service.id)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // 状态图标
            statusIcon
            
            // 信息
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(service.name)
                        .font(.system(size: 13, weight: .semibold))
                    
                    if service.type == .stdio {
                        Label("STDIO", systemImage: "terminal")
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.1))
                            .foregroundColor(.purple)
                            .clipShape(Capsule())
                    }
                    
                    // AI 处理中指示器
                    if isAIProcessing {
                        HStack(spacing: 2) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.6)
                            Text("AI 处理中...")
                                .font(.system(size: 9))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .clipShape(Capsule())
                    }
                }
                
                HStack(spacing: 8) {
                    StatusBadge(status: status)
                    
                    // 健康状态指示（如果启用了健康监控）
                    if isMonitored, let health = healthStatus {
                        HealthMiniBadge(status: health)
                    }
                    
                    if let port = service.port {
                        Label("端口 \(port)", systemImage: "network")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    
                    // 显示访问 URL
                    if let accessURL = unifiedInfo?.internalAccessURL {
                        Label("本机", systemImage: "internaldrive")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help(accessURL)
                    }
                    
                    if let externalURL = unifiedInfo?.externalAccessURL {
                        Label("局域网", systemImage: "network")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help(externalURL)
                    }
                    
                    if let uptime = runtimeInfo?.uptime {
                        Label(formatUptime(uptime), systemImage: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                
                if let description = service.description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                if let error = runtimeInfo?.errorMessage, status == .error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // 操作按钮
            HStack(spacing: 6) {
                // 日志按钮 - 暂时始终显示，实际可用性在点击时检查
                Button {
                    NotificationCenter.default.post(
                        name: .showServiceLogs,
                        object: service
                    )
                } label: {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("查看日志")
                
                // 访问按钮（仅在运行中且有访问信息时显示）
                if status == .running, let info = networkInfo {
                    AccessButtons(networkInfo: info) {
                        // 重新检查访问性
                        Task {
                            await networkManager.checkServiceAccess(serviceID: service.id)
                        }
                    }
                }
                
                if status == .running {
                    Button {
                        manager.stopService(service)
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("停止")
                    .disabled(isAIProcessing)
                    
                    Button {
                        manager.restartService(service)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("重启")
                    .disabled(isAIProcessing)
                } else {
                    Button {
                        manager.startService(service)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("启动")
                    .disabled(isAIProcessing || service.startCommand == nil)
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
        .opacity(isAIProcessing ? 0.8 : 1.0)
    }
    
    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.15))
                .frame(width: 32, height: 32)
            
            Image(systemName: status.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(statusColor)
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .running: return .green
        case .stopped: return .gray
        case .error: return .red
        case .starting, .stopping: return .orange
        case .unknown: return .gray
        }
    }
    
    private func formatUptime(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = Int(interval) % 3600 / 60
        if hours > 0 {
            return "运行 \(hours)h \(minutes)m"
        } else {
            return "运行 \(minutes)m"
        }
    }
}

struct StatusBadge: View {
    let status: ServiceRuntimeStatus
    
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.symbolName)
                .font(.system(size: 8))
            Text(status.displayName)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .foregroundColor(color)
        .clipShape(Capsule())
    }
    
    private var color: Color {
        switch status {
        case .running: return .green
        case .stopped: return .gray
        case .error: return .red
        case .starting, .stopping: return .orange
        case .unknown: return .gray
        }
    }
}

// MARK: - 健康状态迷你标签
struct HealthMiniBadge: View {
    let status: HealthStatus
    
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: iconName)
                .font(.system(size: 7))
            Text(status.displayName)
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(backgroundColor.opacity(0.12))
        .foregroundColor(foregroundColor)
        .clipShape(Capsule())
    }
    
    private var iconName: String {
        switch status {
        case .healthy:
            return "heart.fill"
        case .unhealthy:
            return "exclamationmark.triangle.fill"
        case .recovering:
            return "arrow.clockwise"
        case .flapping:
            return "waveform.path.ecg"
        case .unknown:
            return "questionmark.circle"
        }
    }
    
    private var backgroundColor: Color {
        switch status {
        case .healthy:
            return .green
        case .unhealthy:
            return .red
        case .recovering:
            return .yellow
        case .flapping:
            return .purple
        case .unknown:
            return .gray
        }
    }
    
    private var foregroundColor: Color {
        backgroundColor
    }
}

// MARK: - 访问按钮
struct AccessButtons: View {
    let networkInfo: NetworkAccessInfo
    let onRecheck: () -> Void
    
    @State private var showingMenu = false
    
    var body: some View {
        Menu {
            // 内部访问
            Button {
                copyToClipboard(networkInfo.internalAccess.url)
            } label: {
                Label("复制本机地址", systemImage: "internaldrive")
            }
            
            Divider()
            
            // 外部访问
            if let external = networkInfo.externalAccess {
                if external.isAccessible {
                    Button {
                        copyToClipboard(external.url)
                    } label: {
                        Label("复制局域网地址", systemImage: "network")
                    }
                } else if !external.accessibilityIssues.isEmpty {
                    Section("外部访问问题") {
                        ForEach(external.accessibilityIssues.indices, id: \.self) { index in
                            let issue = external.accessibilityIssues[index]
                            Text(issue.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Button {
                        Task {
                            await fixExternalAccess()
                        }
                    } label: {
                        Label("尝试修复", systemImage: "wrench.and.screwdriver")
                    }
                }
            }
            
            Divider()
            
            Button {
                onRecheck()
            } label: {
                Label("重新检查", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "link")
                    .font(.system(size: 10))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
        .help("访问地址")
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func fixExternalAccess() async {
        let result = await NetworkAccessManager.shared.fixExternalAccess(for: networkInfo.serviceID)
        
        // 这里可以添加通知或反馈
        LogInfo("[AccessButtons] 修复外部访问: \(result.message)")
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let showServiceLogs = Notification.Name("showServiceLogs")
}
