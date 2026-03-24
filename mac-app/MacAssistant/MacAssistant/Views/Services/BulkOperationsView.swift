//
//  BulkOperationsView.swift
//  MacAssistant
//
//  批量操作视图 - 批量管理服务
//

import SwiftUI

struct BulkOperationsView: View {
    @StateObject private var bulkManager = BulkOperationManager.shared
    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var unifiedState = UnifiedServiceState.shared
    
    @State private var selectedServices: Set<String> = []
    @State private var showingConfirmation = false
    @State private var pendingOperation: BulkOperationType?
    @State private var showingResults = false
    
    private var allRunning: Bool {
        let selected = serviceManager.services.filter { selectedServices.contains($0.id) }
        guard !selected.isEmpty else { return false }
        return selected.allSatisfy { service in
            unifiedState.runtimeInfos[service.id]?.status == .running
        }
    }
    
    private var allStopped: Bool {
        let selected = serviceManager.services.filter { selectedServices.contains($0.id) }
        guard !selected.isEmpty else { return false }
        return selected.allSatisfy { service in
            let status = unifiedState.runtimeInfos[service.id]?.status ?? .unknown
            return status == .stopped || status == .unknown
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            
            if case .executing = bulkManager.currentState {
                progressSection
            }
            
            serviceList
        }
        .background(Color(.windowBackgroundColor))
        .alert("确认操作", isPresented: $showingConfirmation) {
            Button("取消", role: .cancel) { }
            Button("确认", role: .destructive) {
                executePendingOperation()
            }
        } message: {
            if let op = pendingOperation {
                Text("确定要\(op.displayName)选中的 \(selectedServices.count) 个服务吗？")
            }
        }
        .sheet(isPresented: $showingResults) {
            BulkResultsView()
        }
    }
    
    // MARK: - Header
    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("批量操作")
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(selectedServices.count)/\(serviceManager.services.count) 已选择")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // 全选/取消全选
                Button(selectedServices.count == serviceManager.services.count ? "取消全选" : "全选") {
                    if selectedServices.count == serviceManager.services.count {
                        selectedServices.removeAll()
                    } else {
                        selectedServices = Set(serviceManager.services.map(\.id))
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            
            // 操作按钮栏
            HStack(spacing: 8) {
                operationButton(
                    type: .start,
                    disabled: selectedServices.isEmpty || allRunning || bulkManager.currentState.isRunning
                )
                
                operationButton(
                    type: .stop,
                    disabled: selectedServices.isEmpty || allStopped || bulkManager.currentState.isRunning
                )
                
                operationButton(
                    type: .restart,
                    disabled: selectedServices.isEmpty || bulkManager.currentState.isRunning
                )
                
                Divider()
                    .frame(height: 24)
                
                operationButton(
                    type: .checkStatus,
                    disabled: selectedServices.isEmpty || bulkManager.currentState.isRunning
                )
                
                Spacer()
                
                // 快速操作
                Menu {
                    Button {
                        Task { await bulkManager.startAll() }
                    } label: {
                        Label("启动全部", systemImage: "play.fill")
                    }
                    
                    Button {
                        Task { await bulkManager.stopAll() }
                    } label: {
                        Label("停止全部", systemImage: "stop.fill")
                    }
                    
                    Button {
                        Task { await bulkManager.restartAll() }
                    } label: {
                        Label("重启全部", systemImage: "arrow.clockwise")
                    }
                    
                    Divider()
                    
                    Button {
                        Task { await bulkManager.checkAllStatus() }
                    } label: {
                        Label("检查全部状态", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.regular)
                
                // 查看结果
                if case .completed = bulkManager.currentState {
                    Button {
                        showingResults = true
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                    .help("查看结果")
                }
            }
        }
        .padding()
    }
    
    // MARK: - Progress Section
    private var progressSection: some View {
        VStack(spacing: 8) {
            if let progress = bulkManager.currentState.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(height: 4)
            }
            
            HStack {
                if let current = bulkManager.currentState.currentService {
                    Text("正在处理: \(current)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    bulkManager.cancel()
                } label: {
                    Text("取消")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(Color.blue.opacity(0.05))
    }
    
    // MARK: - Service List
    private var serviceList: some View {
        List(serviceManager.services, id: \.id) { service in
            BulkServiceRow(
                service: service,
                isSelected: selectedServices.contains(service.id),
                status: unifiedState.runtimeInfos[service.id]?.status ?? .unknown
            )
            .contentShape(Rectangle())
            .onTapGesture {
                toggleSelection(service.id)
            }
        }
        .listStyle(.plain)
    }
    
    // MARK: - Helper Views
    private func operationButton(type: BulkOperationType, disabled: Bool) -> some View {
        Button {
            pendingOperation = type
            if type == .stop || type == .restart {
                showingConfirmation = true
            } else {
                executePendingOperation()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: type.icon)
                    .font(.system(size: 10))
                Text(type.displayName)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(buttonTint(for: type))
        .disabled(disabled)
    }
    
    private func buttonTint(for type: BulkOperationType) -> Color {
        switch type {
        case .start: return .green
        case .stop: return .red
        case .restart: return .orange
        case .checkStatus: return .blue
        default: return .primary
        }
    }
    
    // MARK: - Methods
    private func toggleSelection(_ id: String) {
        if selectedServices.contains(id) {
            selectedServices.remove(id)
        } else {
            selectedServices.insert(id)
        }
    }
    
    private func executePendingOperation() {
        guard let type = pendingOperation else { return }
        
        let config = BulkOperationConfig(
            type: type,
            targetServices: Array(selectedServices),
            parallel: type != .restart,  // 重启需要顺序执行
            stopOnError: false,
            timeout: type == .restart ? 120 : 60,
            delay: type == .restart ? 2 : 0,
            confirmRequired: false,
            rollbackOnFailure: false
        )
        
        Task {
            await bulkManager.execute(config: config)
        }
    }
}

// MARK: - Bulk Service Row
struct BulkServiceRow: View {
    let service: ServiceDefinition
    let isSelected: Bool
    let status: ServiceRuntimeStatus
    
    var body: some View {
        HStack(spacing: 12) {
            // 选择框
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? .blue : .secondary)
            
            // 状态指示器
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
            
            // 服务信息
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.system(size: 13, weight: .medium))
                
                HStack(spacing: 8) {
                    Text(status.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    
                    if let port = service.port {
                        Text(":\(port)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // 分类标签
            if service.category != .other {
                Text(service.category.displayName)
                    .font(.system(size: 9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 6)
        .background(isSelected ? Color.blue.opacity(0.05) : Color.clear)
    }
}

// MARK: - Bulk Results View
struct BulkResultsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var bulkManager = BulkOperationManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("操作结果")
                    .font(.system(size: 16, weight: .semibold))
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(spacing: 0) {
                    if case .completed(let results) = bulkManager.currentState {
                        ForEach(results, id: \.serviceID) { result in
                            ResultRow(result: result)
                        }
                    } else if case .failed(_, let results) = bulkManager.currentState {
                        ForEach(results, id: \.serviceID) { result in
                            ResultRow(result: result)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            
            Divider()
            
            HStack {
                Button {
                    dismiss()
                } label: {
                    Text("关闭")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding()
        }
        .frame(width: 400, height: 500)
    }
}

// MARK: - Result Row
struct ResultRow: View {
    let result: BulkOperationResult
    
    var body: some View {
        HStack(spacing: 12) {
            // 状态图标
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(result.success ? .green : .red)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(serviceName)
                    .font(.system(size: 13))
                
                Text(result.message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Text(String(format: "%.1fs", result.duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
    
    private var serviceName: String {
        ServiceManager.shared.services.first { $0.id == result.serviceID }?.name ?? result.serviceID
    }
}

// MARK: - Preview
struct BulkOperationsView_Previews: PreviewProvider {
    static var previews: some View {
        BulkOperationsView()
            .frame(width: 600, height: 500)
    }
}
