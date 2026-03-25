//
//  MCPServiceManagementView.swift
//  MacAssistant
//
//  MCP 业务服务管理界面
//

import SwiftUI

struct MCPServiceManagementView: View {
    @StateObject private var manager = MCPServiceManager.shared
    @State private var showingAddSheet = false
    @State private var selectedService: MCPServiceConfig?
    @State private var showingDeleteConfirm = false
    @State private var serviceToDelete: MCPServiceConfig?
    @State private var searchText = ""
    
    var filteredServices: [MCPServiceConfig] {
        if searchText.isEmpty { return manager.services }
        return manager.services.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部概览
                MCPOverviewHeader(
                    totalServices: manager.services.count,
                    connectedCount: manager.serviceStatuses.values.filter { $0.isConnected }.count,
                    availableTools: manager.getAllAvailableTools().count
                )
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                // 工具栏
                HStack(spacing: 16) {
                    // 搜索
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("搜索服务...", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(8)
                    .frame(width: 200)
                    
                    Spacer()
                    
                    // 连接所有
                    Button {
                        Task {
                            await manager.connectAllEnabled()
                        }
                    } label: {
                        Label("连接全部", systemImage: "link.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(manager.isConnecting)
                    
                    // 添加按钮
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("添加服务", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                Divider()
                
                // 服务列表
                if filteredServices.isEmpty {
                    EmptyMCPServiceView {
                        showingAddSheet = true
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 320, maximum: 380), spacing: 16)
                        ], spacing: 16) {
                            ForEach(filteredServices) { service in
                                MCPServiceCard(
                                    service: service,
                                    status: manager.serviceStatuses[service.id] ?? .unknown,
                                    onConnect: {
                                        Task { await manager.connectService(id: service.id) }
                                    },
                                    onDisconnect: {
                                        manager.disconnectService(id: service.id)
                                    },
                                    onEdit: {
                                        selectedService = service
                                    },
                                    onDelete: {
                                        serviceToDelete = service
                                        showingDeleteConfirm = true
                                    }
                                )
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("业务服务")
            .navigationSubtitle("MCP 服务管理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        // 关闭视图
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                MCPServiceAddView { config in
                    manager.addService(config)
                    showingAddSheet = false
                }
            }
            .sheet(item: $selectedService) { service in
                MCPServiceEditView(service: service) { updated in
                    manager.updateService(updated)
                    selectedService = nil
                }
            }
            .alert("确认删除", isPresented: $showingDeleteConfirm, presenting: serviceToDelete) { service in
                Button("删除", role: .destructive) {
                    manager.removeService(id: service.id)
                }
                Button("取消", role: .cancel) {}
            } message: { service in
                Text("确定要删除 MCP 服务 「\(service.name)」吗？")
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

// MARK: - 概览头部

struct MCPOverviewHeader: View {
    let totalServices: Int
    let connectedCount: Int
    let availableTools: Int
    
    var body: some View {
        HStack(spacing: 24) {
            StatCard(
                icon: "cube.box",
                title: "服务总数",
                value: "\(totalServices)",
                subtitle: "",
                color: .blue
            )
            
            StatCard(
                icon: "link.circle.fill",
                title: "已连接",
                value: "\(connectedCount)",
                subtitle: "\(totalServices - connectedCount) 未连接",
                color: .green
            )
            
            StatCard(
                icon: "wrench.and.screwdriver",
                title: "可用工具",
                value: "\(availableTools)",
                subtitle: "",
                color: .purple
            )
            
            Spacer()
        }
    }
}

// MARK: - 服务卡片

struct MCPServiceCard: View {
    let service: MCPServiceConfig
    let status: MCPServiceStatus
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    @State private var showingTools = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 头部
            HStack(spacing: 12) {
                Text(service.emoji)
                    .font(.system(size: 32))
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(service.name)
                            .font(.system(size: 15, weight: .semibold))
                        
                        if !service.isEnabled {
                            Text("已禁用")
                                .font(.system(size: 9))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.2))
                                .foregroundColor(.secondary)
                                .cornerRadius(4)
                        }
                    }
                    
                    Text(service.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                // 状态指示
                StatusBadge(status: status)
            }
            
            Divider()
            
            // 连接信息
            HStack(spacing: 12) {
                InfoItem(icon: service.transportType.icon, text: service.transportType.displayName)
                InfoItem(icon: "link", text: shortenEndpoint(service.endpoint))
            }
            
            // 工具列表（如果已连接）
            if case .connected(let tools) = status, !tools.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("可用工具 (\(tools.count))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button {
                            showingTools.toggle()
                        } label: {
                            Image(systemName: showingTools ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if showingTools {
                        FlowLayout(spacing: 6) {
                            ForEach(tools.prefix(6)) { tool in
                                ToolBadge(name: tool.name)
                            }
                            if tools.count > 6 {
                                Text("+\(tools.count - 6)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            
            Divider()
            
            // 操作按钮
            HStack(spacing: 8) {
                // 连接/断开按钮
                if status.isConnected {
                    Button {
                        onDisconnect()
                    } label: {
                        Label("断开", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                } else {
                    Button {
                        onConnect()
                    } label: {
                        Label("连接", systemImage: "link")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!service.isEnabled)
                }
                
                Spacer()
                
                // 编辑/删除
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
    
    private func shortenEndpoint(_ endpoint: String) -> String {
        if endpoint.count > 40 {
            return String(endpoint.prefix(20)) + "..." + String(endpoint.suffix(15))
        }
        return endpoint
    }
}

struct StatusBadge: View {
    let status: MCPServiceStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.system(size: 10))
            Text(status.displayText)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.15))
        .foregroundColor(statusColor)
        .cornerRadius(6)
    }
    
    private var statusColor: Color {
        switch status {
        case .unknown: return .gray
        case .connecting: return .orange
        case .connected: return .green
        case .disconnected: return .gray
        case .error: return .red
        }
    }
}

struct InfoItem: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(text)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct ToolBadge: View {
    let name: String
    
    var body: some View {
        Text(name)
            .font(.system(size: 10))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.purple.opacity(0.1))
            .foregroundColor(.purple)
            .cornerRadius(4)
    }
}

// MARK: - 空状态视图

struct EmptyMCPServiceView: View {
    let onAdd: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "cube.box")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("暂无 MCP 服务")
                .font(.headline)
            
            Text("MCP 服务可以让你的 Agent 连接各种外部工具和 API\n例如 GitHub、Slack、数据库等")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                onAdd()
            } label: {
                Label("添加第一个服务", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            
            Spacer()
        }
        .padding()
    }
}

// MARK: - 添加服务视图

struct MCPServiceAddView: View {
    let onAdd: (MCPServiceConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedPreset: MCPServiceConfig?
    @State private var customConfig = MCPServiceConfig(
        name: "",
        endpoint: "",
        authType: .none
    )
    @State private var usePreset = true
    
    var body: some View {
        NavigationView {
            Form {
                Section("添加方式") {
                    Picker("方式", selection: $usePreset) {
                        Text("使用预设").tag(true)
                        Text("自定义配置").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                
                if usePreset {
                    Section("选择预设服务") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(MCPServiceConfig.presets, id: \.name) { preset in
                                    PresetCard(
                                        preset: preset,
                                        isSelected: selectedPreset?.name == preset.name
                                    ) {
                                        selectedPreset = preset
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        .frame(height: 120)
                    }
                    
                    if let preset = selectedPreset {
                        Section("预设详情") {
                            HStack {
                                Text(preset.emoji)
                                    .font(.title)
                                VStack(alignment: .leading) {
                                    Text(preset.name)
                                        .font(.headline)
                                    Text(preset.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Text("端点: \(preset.endpoint)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Section("基本配置") {
                        TextField("服务名称", text: $customConfig.name)
                        TextField("描述", text: $customConfig.description)
                        TextField("Emoji", text: $customConfig.emoji)
                    }
                    
                    Section("连接配置") {
                        Picker("传输类型", selection: $customConfig.transportType) {
                            ForEach(MCPTransportType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        
                        TextField("端点 (URL 或命令)", text: $customConfig.endpoint)
                        
                        if customConfig.transportType == .stdio {
                            TextField("工作目录 (可选)", text: Binding(
                                get: { customConfig.workingDirectory ?? "" },
                                set: { customConfig.workingDirectory = $0.isEmpty ? nil : $0 }
                            ))
                        }
                    }
                    
                    Section("认证") {
                        Picker("认证类型", selection: $customConfig.authType) {
                            ForEach(MCPAuthType.allCases, id: \.self) { auth in
                                Text(auth.displayName).tag(auth)
                            }
                        }
                        
                        if customConfig.authType != .none {
                            SecureField("API Key / Token", text: Binding(
                                get: { customConfig.apiKey ?? "" },
                                set: { customConfig.apiKey = $0.isEmpty ? nil : $0 }
                            ))
                        }
                    }
                }
            }
            .navigationTitle("添加 MCP 服务")
            .navigationSubtitle("扩展 Agent 能力")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        if usePreset, let preset = selectedPreset {
                            onAdd(preset)
                        } else {
                            onAdd(customConfig)
                        }
                    }
                    .disabled(usePreset ? selectedPreset == nil : customConfig.name.isEmpty || customConfig.endpoint.isEmpty)
                }
            }
        }
        .frame(width: 500, height: 500)
    }
}

struct PresetCard: View {
    let preset: MCPServiceConfig
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            Text(preset.emoji)
                .font(.system(size: 32))
            Text(preset.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .frame(width: 80, height: 80)
        .background(isSelected ? Color.blue.opacity(0.15) : Color.gray.opacity(0.1))
        .foregroundColor(isSelected ? .blue : .primary)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
        .onTapGesture {
            onTap()
        }
    }
}

// MARK: - 编辑服务视图

struct MCPServiceEditView: View {
    let service: MCPServiceConfig
    let onSave: (MCPServiceConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var config: MCPServiceConfig
    
    init(service: MCPServiceConfig, onSave: @escaping (MCPServiceConfig) -> Void) {
        self.service = service
        self.onSave = onSave
        _config = State(initialValue: service)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("基本配置") {
                    TextField("服务名称", text: $config.name)
                    TextField("描述", text: $config.description)
                    TextField("Emoji", text: $config.emoji)
                    
                    Toggle("启用服务", isOn: $config.isEnabled)
                }
                
                Section("连接配置") {
                    Picker("传输类型", selection: $config.transportType) {
                        ForEach(MCPTransportType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    
                    TextField("端点", text: $config.endpoint)
                    
                    if config.transportType == .stdio {
                        TextField("工作目录 (可选)", text: Binding(
                            get: { config.workingDirectory ?? "" },
                            set: { config.workingDirectory = $0.isEmpty ? nil : $0 }
                        ))
                    }
                    
                    HStack {
                        Text("超时")
                        Spacer()
                        TextField("秒", value: $config.timeout, format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                    }
                }
                
                Section("认证") {
                    Picker("认证类型", selection: $config.authType) {
                        ForEach(MCPAuthType.allCases, id: \.self) { auth in
                            Text(auth.displayName).tag(auth)
                        }
                    }
                    
                    if config.authType != .none {
                        SecureField("API Key / Token", text: Binding(
                            get: { config.apiKey ?? "" },
                            set: { config.apiKey = $0.isEmpty ? nil : $0 }
                        ))
                    }
                }
                
                Section("使用统计") {
                    LabeledContent("创建时间") {
                        Text(config.createdAt, style: .date)
                    }
                    
                    if let lastUsed = config.lastUsedAt {
                        LabeledContent("最后使用") {
                            Text(lastUsed, style: .relative)
                        }
                    }
                    
                    LabeledContent("调用次数") {
                        Text("\(config.useCount)")
                    }
                }
            }
            .navigationTitle("编辑服务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(config)
                    }
                }
            }
        }
        .frame(width: 500, height: 500)
    }
}

// MARK: - 预览
#Preview {
    MCPServiceManagementView()
}
