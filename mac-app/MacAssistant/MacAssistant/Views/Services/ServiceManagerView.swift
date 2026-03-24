//
//  ServiceManagerView.swift
//  MacAssistant
//
//  服务管理主界面
//

import SwiftUI

struct ServiceManagerView: View {
    @StateObject private var serviceManager = ServiceManager.shared
    @State private var searchText = ""
    @State private var selectedCategory: ServiceCategory? = nil
    @State private var showingAddService = false
    
    var filteredServices: [ServiceStateSnapshot] {
        serviceManager.services.filter { service in
            let matchesSearch = searchText.isEmpty || 
                service.name.localizedCaseInsensitiveContains(searchText) ||
                service.id.localizedCaseInsensitiveContains(searchText)
            
            return matchesSearch
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("服务管理")
                    .font(.system(size: 16, weight: .semibold))
                
                Spacer()
                
                Button(action: refreshAll) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("刷新所有服务状态")
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            // 搜索栏
            searchBar
            
            // 操作日志区域（可滚动显示多条）
            if !serviceManager.operationLogs.isEmpty {
                logPreview
            }
            
            // 服务列表
            serviceList
        }
        .frame(width: 500, height: 400)
        .onAppear {
            // 注册常用服务
            serviceManager.registerCommonServices()
            // 初始检查
            Task {
                await serviceManager.checkAllServices()
            }
        }
    }
    
    // MARK: - 子视图
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            
            TextField("搜索服务...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
    
    private var logPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 日志标题
            HStack {
                Image(systemName: "terminal")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
                
                Text("操作日志")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if serviceManager.isOperating {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            
            // 日志内容（滚动显示最近5条）
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(serviceManager.operationLogs.suffix(5).reversed(), id: \.self) { log in
                        Text(log)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 80)
        }
        .background(Color.blue.opacity(0.05))
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
    
    private var serviceList: some View {
        List {
            if filteredServices.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary.opacity(0.5))
                            Text("暂无服务")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            Text("点击下方按钮添加常用服务")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        .padding(.vertical, 40)
                        Spacer()
                    }
                }
            } else {
                Section {
                    ForEach(filteredServices) { service in
                        ServiceRowView(
                            service: service,
                            isOperating: serviceManager.isOperating && service.isActive
                        ) { operation in
                            Task {
                                await performOperation(operation, for: service.id)
                            }
                        }
                    }
                }
            }
            
            // 添加服务按钮
            Section {
                Button(action: { serviceManager.registerCommonServices() }) {
                    HStack {
                        Spacer()
                        Image(systemName: "plus.circle")
                            .font(.system(size: 14))
                        Text("添加常用服务")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
    
    // MARK: - 操作
    
    private func performOperation(_ operation: ServiceOperation, for serviceId: String) async {
        switch operation {
        case .start:
            await serviceManager.startService(serviceId)
        case .stop:
            await serviceManager.stopService(serviceId)
        case .restart:
            await serviceManager.restartService(serviceId)
        case .check:
            await serviceManager.checkService(serviceId)
        default:
            break
        }
    }
    
    private func refreshAll() {
        Task {
            await serviceManager.checkAllServices()
        }
    }
}

// MARK: - 服务行视图

struct ServiceRowView: View {
    let service: ServiceStateSnapshot
    let isOperating: Bool
    let onOperation: (ServiceOperation) -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // 状态指示器
            StatusIndicator(state: service.state)
            
            // 服务信息
            VStack(alignment: .leading, spacing: 4) {
                Text(service.name)
                    .font(.system(size: 14, weight: .medium))
                
                HStack(spacing: 8) {
                    Text(service.state.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(stateColor)
                    
                    if let adapter = service.adapter {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(adapter)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    if let port = service.port {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(":\(port)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // 操作按钮
            HStack(spacing: 8) {
                if isOperating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    switch service.state {
                    case .running:
                        Button(action: { onOperation(.stop) }) {
                            Image(systemName: "stop.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("停止")
                        
                        Button(action: { onOperation(.restart) }) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("重启")
                        
                    case .stopped, .error, .notInstalled:
                        Button(action: { onOperation(.start) }) {
                            Image(systemName: "play.fill")
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)
                        .help("启动")
                        
                    default:
                        EmptyView()
                    }
                    
                    Button(action: { onOperation(.check) }) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("刷新状态")
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
    
    private var stateColor: Color {
        switch service.state {
        case .running:
            return .green
        case .stopped, .notInstalled:
            return .secondary
        case .error:
            return .red
        case .starting, .stopping, .installing, .checking:
            return .orange
        default:
            return .secondary
        }
    }
}

// MARK: - 状态指示器

struct StatusIndicator: View {
    let state: ServiceRuntimeState
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.3), lineWidth: 2)
                    .frame(width: 14, height: 14)
            )
    }
    
    private var color: Color {
        switch state {
        case .running:
            return .green
        case .stopped, .notInstalled:
            return .gray
        case .error:
            return .red
        case .starting, .stopping, .installing, .checking:
            return .orange
        default:
            return .gray
        }
    }
}

// MARK: - 服务类别

enum ServiceCategory: String, CaseIterable {
    case all = "全部"
    case database = "数据库"
    case cache = "缓存"
    case web = "Web 服务"
    case other = "其他"
}

#Preview {
    ServiceManagerView()
        .frame(width: 600, height: 500)
}
