//
//  ServiceEntryButton.swift
//  MacAssistant
//
//  服务入口 - 快速管理服务状态
//

import SwiftUI

struct ServiceEntryButton: View {
    @StateObject private var manager = ServiceManager.shared
    @StateObject private var unifiedState = UnifiedServiceState.shared
    @State private var showPanel = false
    
    /// 计算运行中数量（使用统一状态）
    private var runningCount: Int {
        manager.services.filter { service in
            let unifiedStatus = unifiedState.runtimeInfos[service.id]?.status
            let managerStatus = manager.runtimeInfos[service.id]?.status
            return (unifiedStatus ?? managerStatus) == .running
        }.count
    }
    
    /// 计算异常数量（使用统一状态）
    private var errorCount: Int {
        manager.services.filter { service in
            let unifiedStatus = unifiedState.runtimeInfos[service.id]?.status
            let managerStatus = manager.runtimeInfos[service.id]?.status
            return (unifiedStatus ?? managerStatus) == .error
        }.count
    }
    
    private var statusColor: Color {
        if errorCount > 0 {
            return .red
        } else if runningCount > 0 {
            return .green
        } else {
            return .secondary
        }
    }
    
    private var badgeText: String? {
        if errorCount > 0 {
            return "\(errorCount)"
        } else if runningCount > 0 {
            return "\(runningCount)"
        }
        return nil
    }
    
    var body: some View {
        Button {
            showPanel.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "server.rack")
                    .font(.system(size: 13, weight: .semibold))
                
                Text("服务")
                    .font(.system(size: 12, weight: .semibold))
                
                if let badge = badgeText {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(statusColor.opacity(0.2))
                        )
                        .foregroundColor(statusColor)
                }
            }
            .foregroundColor(badgeText != nil ? statusColor : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(badgeText != nil ? statusColor.opacity(0.1) : Color.secondary.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(badgeText != nil ? statusColor.opacity(0.3) : Color.secondary.opacity(0.16), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("服务管理 - 管理 MCP 服务、桌面应用等")
        .accessibilityLabel("服务管理")
        .popover(isPresented: $showPanel, arrowEdge: .top) {
            ServicePanelView(onClose: { showPanel = false })
                .frame(width: 520, height: 600)
        }
    }
}

// MARK: - 服务面板
struct ServicePanelView: View {
    let onClose: () -> Void
    
    @StateObject private var manager = ServiceManager.shared
    @StateObject private var unifiedState = UnifiedServiceState.shared
    @State private var selectedCategory: ServiceDefinition.ServiceCategory?
    @State private var searchText = ""
    @State private var refreshing = false
    
    /// 使用统一状态的统计
    private var runningCount: Int {
        manager.services.filter { service in
            let unifiedStatus = unifiedState.runtimeInfos[service.id]?.status
            let managerStatus = manager.runtimeInfos[service.id]?.status
            return (unifiedStatus ?? managerStatus) == .running
        }.count
    }
    
    private var errorCount: Int {
        manager.services.filter { service in
            let unifiedStatus = unifiedState.runtimeInfos[service.id]?.status
            let managerStatus = manager.runtimeInfos[service.id]?.status
            return (unifiedStatus ?? managerStatus) == .error
        }.count
    }
    
    private var filteredServices: [ServiceDefinition] {
        var result = manager.services(in: selectedCategory)
        
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        
        // 按状态排序：运行中在前
        return result.sorted { a, b in
            let statusA = manager.runtimeInfos[a.id]?.status ?? .unknown
            let statusB = manager.runtimeInfos[b.id]?.status ?? .unknown
            if statusA == .running && statusB != .running { return true }
            if statusA != .running && statusB == .running { return false }
            return a.name < b.name
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summary
            Divider()
            categoryTabs
            Divider()
            serviceList
        }
        .background(Color(.windowBackgroundColor))
    }
    
    // MARK: Header
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("服务管理")
                    .font(.system(size: 16, weight: .semibold))
                Text("管理 MCP 服务、桌面应用等")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索服务...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: 160)
            
            Button {
                Task {
                    refreshing = true
                    await manager.checkAllServicesStatus()
                    refreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .rotationEffect(.degrees(refreshing ? 360 : 0))
                    .animation(refreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: refreshing)
            }
            .buttonStyle(.borderless)
            .help("刷新状态")
            
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding()
    }
    
    // MARK: Summary
    private var summary: some View {
        HStack(spacing: 16) {
            SummaryChip(
                title: "运行中",
                value: runningCount,
                color: .green,
                icon: "checkmark.circle.fill"
            )
            SummaryChip(
                title: "已停止",
                value: manager.services.count - runningCount - errorCount,
                color: .gray,
                icon: "xmark.circle"
            )
            SummaryChip(
                title: "异常",
                value: errorCount,
                color: .red,
                icon: "exclamationmark.triangle.fill"
            )
            SummaryChip(
                title: "总计",
                value: manager.services.count,
                color: .blue,
                icon: "server.rack"
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
    }
    
    // MARK: Category Tabs
    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ServiceCategoryTab(
                    title: "全部",
                    icon: "square.grid.2x2",
                    isSelected: selectedCategory == nil,
                    count: manager.services.count
                ) {
                    selectedCategory = nil
                }
                
                ForEach(ServiceDefinition.ServiceCategory.allCases, id: \.self) { category in
                    ServiceCategoryTab(
                        title: category.displayName,
                        icon: category.icon,
                        isSelected: selectedCategory == category,
                        count: manager.services(in: category).count
                    ) {
                        selectedCategory = category
                    }
                }
                
                // 服务发现入口
                ServiceDiscoveryTab(
                    isSelected: false,
                    pendingCount: ServiceDiscoveryManager.shared.pendingConfirmations.count,
                    onSelect: {
                        NotificationCenter.default.post(
                            name: .showServiceDiscovery,
                            object: nil
                        )
                    }
                )
                
                // 健康监控入口
                HealthMonitorTab(
                    isSelected: false,
                    onSelect: {
                        // 打开健康监控面板
                        NotificationCenter.default.post(
                            name: .showHealthMonitor,
                            object: nil
                        )
                    }
                )
                
                // 批量操作入口
                BulkOperationsTab(
                    isSelected: false,
                    onSelect: {
                        NotificationCenter.default.post(
                            name: .showBulkOperations,
                            object: nil
                        )
                    }
                )
                
                // 桌面应用入口
                DesktopAppTab(
                    isSelected: false,
                    onSelect: {
                        NotificationCenter.default.post(
                            name: .showDesktopAppManager,
                            object: nil
                        )
                    }
                )
                
                // AI浏览器入口
                BrowserAgentTab(
                    isSelected: false,
                    onSelect: {
                        NotificationCenter.default.post(
                            name: .showBrowserAgent,
                            object: nil
                        )
                    }
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
    
    // MARK: Service List
    private var serviceList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if filteredServices.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredServices) { service in
                        ServiceRow(service: service)
                    }
                }
            }
            .padding(14)
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(searchText.isEmpty ? "暂无服务配置" : "未找到匹配的服务")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

// MARK: - 辅助组件
struct SummaryChip: View {
    let title: String
    let value: Int
    let color: Color
    let icon: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
            
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)")
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct ServiceCategoryTab: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let count: Int
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.3) : Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.blue : Color.clear)
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 健康监控 Tab
struct HealthMonitorTab: View {
    let isSelected: Bool
    let onSelect: () -> Void
    
    @StateObject private var engine = HealthMonitorEngine.shared
    
    private var unhealthyCount: Int {
        engine.monitorStatuses.values.filter {
            if case .unhealthy = $0 { return true }
            return false
        }.count
    }
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 11))
                Text("健康")
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                
                if engine.isEnabled {
                    Circle()
                        .fill(unhealthyCount > 0 ? Color.red : Color.green)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.purple : Color.clear)
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 服务发现 Tab
struct ServiceDiscoveryTab: View {
    let isSelected: Bool
    let pendingCount: Int
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 11))
                Text("发现")
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                
                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.orange : Color.clear)
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 批量操作 Tab
struct BulkOperationsTab: View {
    let isSelected: Bool
    let onSelect: () -> Void
    
    @StateObject private var bulkManager = BulkOperationManager.shared
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Image(systemName: "checklist")
                    .font(.system(size: 11))
                Text("批量")
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                
                if bulkManager.currentState.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.green : Color.clear)
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 桌面应用 Tab
struct DesktopAppTab: View {
    let isSelected: Bool
    let onSelect: () -> Void
    
    @StateObject private var launcher = DesktopAppLauncher.shared
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Image(systemName: "macwindow")
                    .font(.system(size: 11))
                Text("应用")
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                
                let runningCount = launcher.installedApps.filter { launcher.isRunning($0) }.count
                if runningCount > 0 {
                    Text("\(runningCount)")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.pink : Color.clear)
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AI浏览器 Tab
struct BrowserAgentTab: View {
    let isSelected: Bool
    let onSelect: () -> Void
    
    @StateObject private var agent = SimpleBrowserAgent.shared
    @StateObject private var sessionStore = BrowserSessionStore.shared
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 11))
                Text("浏览器")
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                
                if agent.isRunning {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }

                if !sessionStore.sessions.isEmpty {
                    Text("\(sessionStore.sessions.count)")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.indigo.opacity(0.16))
                        .foregroundColor(.indigo)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.indigo : Color.clear)
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AI 浏览器入口按钮（工具栏）
struct BrowserAgentEntryButton: View {
    let action: () -> Void
    
    @StateObject private var agent = SimpleBrowserAgent.shared
    @StateObject private var sessionStore = BrowserSessionStore.shared
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .semibold))
                
                Text("浏览器")
                    .font(.system(size: 12, weight: .semibold))
                
                // 运行状态指示器
                if agent.isRunning {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }

                if let activeSession = sessionStore.activeSession {
                    Text(activeSession.status == .blockedByAuth ? "待登录" : "协同中")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.14))
                        .foregroundColor(.indigo)
                        .clipShape(Capsule())
                }
            }
            .foregroundColor(agent.isRunning ? .indigo : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(agent.isRunning ? Color.indigo.opacity(0.1) : Color.secondary.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(agent.isRunning ? Color.indigo.opacity(0.3) : Color.secondary.opacity(0.16), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("AI 浏览器代理 - 打开网页后由主会话继续协同")
        .accessibilityLabel("AI浏览器")
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let showHealthMonitor = Notification.Name("showHealthMonitor")
    static let showServiceDiscovery = Notification.Name("showServiceDiscovery")
    static let showBulkOperations = Notification.Name("showBulkOperations")
    static let showDesktopAppManager = Notification.Name("showDesktopAppManager")
    static let showBrowserAgent = Notification.Name("showBrowserAgent")
}
