//
//  ServiceDiscoveryView.swift
//  MacAssistant
//
//  服务发现视图 - 展示和管理发现的服务
//

import SwiftUI

struct ServiceDiscoveryView: View {
    @StateObject private var discoveryManager = ServiceDiscoveryManager.shared
    @State private var selectedService: DiscoveredService?
    @State private var showingConfirmationSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            
            if discoveryManager.isScanning {
                scanningProgress
                Divider()
            }
            
            if hasPendingServices {
                pendingSection
                Divider()
            }
            
            discoveredServicesList
        }
        .background(Color(.windowBackgroundColor))
        .sheet(item: $selectedService) { service in
            ServiceConfirmationSheet(service: service)
        }
    }
    
    // MARK: - Header
    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("服务发现")
                    .font(.system(size: 16, weight: .semibold))
                Text("发现并管理本地运行的服务")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // 快速扫描按钮
            Button {
                Task {
                    await discoveryManager.quickScan()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                    Text("快速扫描")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(discoveryManager.isScanning)
            
            // 完整扫描按钮
            Button {
                Task {
                    await discoveryManager.scanPorts(config: .default)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                    Text("完整扫描")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(discoveryManager.isScanning)
        }
        .padding()
    }
    
    // MARK: - Scanning Progress
    private var scanningProgress: some View {
        VStack(spacing: 8) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("正在扫描端口...")
                    .font(.system(size: 12))
                Spacer()
                Text("\(discoveryManager.scanProgress.completed) / \(discoveryManager.scanProgress.total)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            ProgressBar(
                value: Double(discoveryManager.scanProgress.completed),
                total: Double(discoveryManager.scanProgress.total)
            )
            .frame(height: 4)
            
            Button("停止扫描") {
                discoveryManager.stopScan()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundColor(.red)
        }
        .padding()
        .background(Color.blue.opacity(0.05))
    }
    
    // MARK: - Pending Section
    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                Text("待确认的服务 (\(discoveryManager.pendingConfirmations.count))")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundColor(.orange)
            
            ForEach(discoveryManager.pendingConfirmations.prefix(3)) { service in
                PendingServiceRow(service: service) {
                    selectedService = service
                }
            }
            
            if discoveryManager.pendingConfirmations.count > 3 {
                Text("还有 \(discoveryManager.pendingConfirmations.count - 3) 个待确认...")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.05))
    }
    
    // MARK: - Discovered Services List
    private var discoveredServicesList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(discoveryManager.groupedServices()) { group in
                    ServiceGroupSection(group: group) { service in
                        selectedService = service
                    }
                }
            }
            .padding(14)
        }
    }
    
    // MARK: - Computed Properties
    private var hasPendingServices: Bool {
        !discoveryManager.pendingConfirmations.isEmpty
    }
}

// MARK: - Progress Bar
struct ProgressBar: View {
    let value: Double
    let total: Double
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: geometry.size.width * progress, height: geometry.size.height)
            }
            .cornerRadius(2)
        }
    }
    
    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }
}

// MARK: - Pending Service Row
struct PendingServiceRow: View {
    let service: DiscoveredService
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: service.serviceType.icon)
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .font(.system(size: 12, weight: .medium))
                    Text("端口 \(service.port)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Text("待确认")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
            }
            .padding(8)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Service Group Section
struct ServiceGroupSection: View {
    let group: DiscoveredServiceGroup
    let onServiceTap: (DiscoveredService) -> Void
    
    @State private var isExpanded = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 分组标题
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: group.type.icon)
                        .font(.system(size: 14))
                        .foregroundColor(.blue)
                    
                    Text(group.type.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    
                    Text("\(group.services.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(10)
                    
                    if group.pendingCount > 0 {
                        Text("\(group.pendingCount) 待确认")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(10)
                    }
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            
            // 服务列表
            if isExpanded {
                LazyVStack(spacing: 6) {
                    ForEach(group.services.sorted { $0.discoveredAt > $1.discoveredAt }) { service in
                        DiscoveredServiceRow(service: service) {
                            onServiceTap(service)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Discovered Service Row
struct DiscoveredServiceRow: View {
    let service: DiscoveredService
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // 状态指示
                statusIndicator
                
                // 服务信息
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(service.name)
                            .font(.system(size: 12, weight: .medium))
                        
                        if let processName = service.processName {
                            Text(processName)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                    
                    HStack(spacing: 8) {
                        Label("端口 \(service.port)", systemImage: "network")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        
                        if let pid = service.pid {
                            Label("PID \(pid)", systemImage: "number")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        
                        // 发现时间
                        Text(timeAgo(service.discoveredAt))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                // 确认状态
                statusBadge
            }
            .padding(8)
            .background(rowBackground)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var statusIndicator: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.15))
                .frame(width: 28, height: 28)
            
            Image(systemName: service.serviceType.icon)
                .font(.system(size: 12))
                .foregroundColor(statusColor)
        }
    }
    
    private var statusBadge: some View {
        Text(service.confirmedStatus.displayName)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.1))
            .cornerRadius(4)
    }
    
    private var rowBackground: Color {
        switch service.confirmedStatus {
        case .pending:
            return Color.orange.opacity(0.05)
        case .confirmed, .autoManaged:
            return Color.green.opacity(0.05)
        case .ignored:
            return Color.gray.opacity(0.05)
        }
    }
    
    private var borderColor: Color {
        switch service.confirmedStatus {
        case .pending:
            return .orange
        case .confirmed, .autoManaged:
            return .green
        case .ignored:
            return .gray
        }
    }
    
    private var statusColor: Color {
        switch service.confirmedStatus {
        case .pending:
            return .orange
        case .confirmed, .autoManaged:
            return .green
        case .ignored:
            return .gray
        }
    }
    
    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Service Confirmation Sheet
struct ServiceConfirmationSheet: View {
    let service: DiscoveredService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discoveryManager = ServiceDiscoveryManager.shared
    
    var body: some View {
        VStack(spacing: 16) {
            // 图标
            Image(systemName: service.serviceType.icon)
                .font(.system(size: 48))
                .foregroundColor(.blue)
            
            // 标题
            Text("发现新服务")
                .font(.system(size: 18, weight: .semibold))
            
            // 服务信息
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(label: "名称", value: service.name)
                InfoRow(label: "类型", value: service.serviceType.displayName)
                InfoRow(label: "端口", value: String(service.port))
                if let pid = service.pid {
                    InfoRow(label: "进程 ID", value: String(pid))
                }
                if let processName = service.processName {
                    InfoRow(label: "进程名", value: processName)
                }
                InfoRow(label: "发现方式", value: service.discoveryMethod.displayName)
            }
            .padding()
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
            
            // 操作说明
            Text("是否将此服务添加到服务管理中？")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            
            // 按钮
            HStack(spacing: 12) {
                Button("忽略") {
                    discoveryManager.ignoreService(service)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button("稍后处理") {
                    discoveryManager.postponeService(service)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button("添加到管理") {
                    discoveryManager.confirmService(service, addToManagement: true)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

// MARK: - Info Row
struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium))
            Spacer()
        }
    }
}

// MARK: - Preview
struct ServiceDiscoveryView_Previews: PreviewProvider {
    static var previews: some View {
        ServiceDiscoveryView()
            .frame(width: 500, height: 600)
    }
}
