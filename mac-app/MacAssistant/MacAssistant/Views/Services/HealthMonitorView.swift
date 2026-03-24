//
//  HealthMonitorView.swift
//  MacAssistant
//
//  健康监控面板 - 展示服务健康状态和事件
//

import SwiftUI

struct HealthMonitorView: View {
    @StateObject private var engine = HealthMonitorEngine.shared
    @StateObject private var unifiedState = UnifiedServiceState.shared
    @StateObject private var serviceManager = ServiceManager.shared
    @State private var selectedService: ServiceDefinition?
    @State private var showingSettings = false
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summaryCards
            Divider()
            serviceList
        }
        .background(Color(.windowBackgroundColor))
    }
    
    // MARK: - Header
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("健康监控")
                    .font(.system(size: 16, weight: .semibold))
                Text("实时监控服务健康状态")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // 全局状态指示
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("设置")
        }
        .padding()
        .sheet(isPresented: $showingSettings) {
            NavigationView {
                HealthMonitorSettingsView()
            }
            .frame(width: 500, height: 600)
        }
    }
    
    // MARK: - Summary Cards
    private var summaryCards: some View {
        HStack(spacing: 12) {
            SummaryCard(
                title: "健康",
                value: healthyCount,
                color: .green,
                icon: "checkmark.circle.fill"
            )
            
            SummaryCard(
                title: "监控中",
                value: engine.monitorCount,
                color: .blue,
                icon: "eye.fill"
            )
            
            SummaryCard(
                title: "异常",
                value: unhealthyCount,
                color: unhealthyCount > 0 ? .red : .gray,
                icon: "exclamationmark.triangle.fill"
            )
            
            SummaryCard(
                title: "事件",
                value: engine.recentEvents.count,
                color: .purple,
                icon: "clock.arrow.circlepath"
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    
    // MARK: - Service List
    private var serviceList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(serviceManager.services) { service in
                    ServiceHealthRow(
                        service: service,
                        healthStatus: engine.status(for: service.id),
                        lastCheck: engine.lastCheckResults[service.id],
                        isMonitoring: engine.isMonitoring(serviceID: service.id)
                    )
                    .onTapGesture {
                        selectedService = service
                    }
                }
            }
            .padding(14)
        }
    }
    
    // MARK: - Computed Properties
    private var statusColor: Color {
        if !engine.isEnabled {
            return .gray
        }
        if unhealthyCount > 0 {
            return .red
        }
        if healthyCount > 0 {
            return .green
        }
        return .orange
    }
    
    private var statusText: String {
        if !engine.isEnabled {
            return "未启用"
        }
        if unhealthyCount > 0 {
            return "\(unhealthyCount) 个服务异常"
        }
        if healthyCount > 0 {
            return "运行正常"
        }
        return "初始化中"
    }
    
    private var healthyCount: Int {
        engine.monitorStatuses.values.filter { $0 == .healthy }.count
    }
    
    private var unhealthyCount: Int {
        engine.monitorStatuses.values.filter {
            if case .unhealthy = $0 { return true }
            return false
        }.count
    }
}

// MARK: - Summary Card
struct SummaryCard: View {
    let title: String
    let value: Int
    let color: Color
    let icon: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
            
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)")
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Service Health Row
struct ServiceHealthRow: View {
    let service: ServiceDefinition
    let healthStatus: HealthStatus
    let lastCheck: HealthCheckResult?
    let isMonitoring: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // 健康状态图标
            statusIcon
            
            // 服务信息
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(service.name)
                        .font(.system(size: 13, weight: .semibold))
                    
                    if isMonitoring {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.blue)
                    }
                }
                
                HStack(spacing: 8) {
                    // 状态标签
                    StatusBadge(status: runtimeStatus)
                    
                    // 响应时间
                    if let responseTime = lastCheck?.responseTimeMs {
                        Label("\(responseTime)ms", systemImage: "stopwatch")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    
                    // 端口
                    if let port = service.port {
                        Label("端口 \(port)", systemImage: "network")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // 操作按钮
            HStack(spacing: 4) {
                if case .unhealthy = healthStatus {
                    Button {
                        // 触发 AI 诊断
                        HealthMonitorEngine.shared.triggerAIDiagnosis(serviceID: service.id)
                    } label: {
                        Image(systemName: "stethoscope")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("AI 诊断")
                }
                
                Button {
                    // 立即检查
                    Task {
                        _ = await HealthMonitorEngine.shared.checkNow(serviceID: service.id)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("立即检查")
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor.opacity(0.3), lineWidth: 1)
        )
    }
    
    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(statusBackgroundColor.opacity(0.15))
                .frame(width: 32, height: 32)
            
            Image(systemName: statusIconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(statusForegroundColor)
        }
    }
    
    private var runtimeStatus: ServiceRuntimeStatus {
        switch healthStatus {
        case .healthy:
            return .running
        case .unhealthy:
            return .error
        case .recovering:
            return .starting
        case .flapping:
            return .error
        case .unknown:
            return .unknown
        }
    }
    
    private var statusIconName: String {
        switch healthStatus {
        case .healthy:
            return "checkmark.circle.fill"
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
    
    private var statusBackgroundColor: Color {
        switch healthStatus {
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
    
    private var statusForegroundColor: Color {
        statusBackgroundColor
    }
    
    private var borderColor: Color {
        switch healthStatus {
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
}

// MARK: - Health Badge
struct HealthBadge: View {
    let status: HealthStatus
    
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: statusIcon)
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
    
    private var statusIcon: String {
        switch status {
        case .healthy:
            return "checkmark.circle.fill"
        case .unhealthy:
            return "xmark.circle"
        case .recovering:
            return "arrow.clockwise"
        case .flapping:
            return "waveform.path.ecg"
        case .unknown:
            return "questionmark.circle"
        }
    }
    
    private var color: Color {
        switch status {
        case .healthy:
            return .green
        case .unhealthy:
            return .red
        case .recovering:
            return .orange
        case .flapping:
            return .purple
        case .unknown:
            return .gray
        }
    }
}

// MARK: - Preview
struct HealthMonitorView_Previews: PreviewProvider {
    static var previews: some View {
        HealthMonitorView()
            .frame(width: 400, height: 500)
    }
}
