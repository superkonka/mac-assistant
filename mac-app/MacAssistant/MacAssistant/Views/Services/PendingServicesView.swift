//
//  PendingServicesView.swift
//  MacAssistant
//
//  待确认服务列表 - 用于 Planner 和用户确认
//

import SwiftUI

struct PendingServicesView: View {
    @StateObject private var discoveryManager = ServiceDiscoveryManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if discoveryManager.pendingServices.isEmpty {
                    emptyView
                } else {
                    pendingList
                }
            }
            .navigationTitle("待确认服务")
            .navigationSubtitle("\(discoveryManager.pendingServices.count) 个服务等待确认")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                
                if !discoveryManager.pendingServices.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("全部添加") {
                            discoveryManager.confirmAll()
                        }
                    }
                }
            }
        }
        .frame(width: 600, height: 500)
    }
    
    // MARK: - 空状态
    
    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            
            Text("没有待确认的服务")
                .font(.headline)
            
            Text("服务可以通过以下方式添加：\n1. 对话中提及服务需求\n2. 磁盘扫描发现项目\n3. 手动添加远程仓库")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Spacer()
        }
    }
    
    // MARK: - 待确认列表
    
    private var pendingList: some View {
        List {
            Section {
                ForEach(discoveryManager.pendingServices) { service in
                    PendingServiceCard(service: service)
                }
            } header: {
                Text("来源说明")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } footer: {
                Text("这些服务需要您的确认才会添加到服务列表")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - 待确认服务卡片

struct PendingServiceCard: View {
    let service: PendingService
    @StateObject private var discoveryManager = ServiceDiscoveryManager.shared
    
    private var sourceIcon: String {
        switch service.sourceType {
        case .chatGenerated:
            return "bubble.left.fill"
        case .diskDiscovered:
            return "folder.fill"
        case .remoteCloned:
            return "globe"
        }
    }
    
    private var sourceColor: Color {
        switch service.sourceType {
        case .chatGenerated:
            return .blue
        case .diskDiscovered:
            return .orange
        case .remoteCloned:
            return .purple
        }
    }
    
    private var sourceName: String {
        switch service.sourceType {
        case .chatGenerated:
            return "对话"
        case .diskDiscovered:
            return "本地"
        case .remoteCloned:
            return "远程"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部
            HStack(spacing: 10) {
                // 来源图标
                Image(systemName: sourceIcon)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(sourceColor)
                    .cornerRadius(6)
                
                // 名称和描述
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .font(.system(size: 14, weight: .semibold))
                    
                    Text(service.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                // 来源标签
                Text(sourceName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(sourceColor.opacity(0.15))
                    .foregroundColor(sourceColor)
                    .cornerRadius(4)
            }
            
            // 详细信息
            HStack(spacing: 16) {
                if let tech = service.detectedTech?.first {
                    DetailItem(icon: "hammer.fill", text: tech)
                }
                
                if let port = service.suggestedPort {
                    DetailItem(icon: "number", text: "Port \(port)")
                }
                
                if let path = service.sourcePath {
                    DetailItem(icon: "folder", text: abbreviatedPath(path))
                }
                
                if let url = service.remoteURL {
                    DetailItem(icon: "link", text: abbreviatedURL(url))
                }
            }
            
            // 推荐理由
            Text("推荐理由: \(service.reason)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 4)
            
            // 操作按钮
            HStack(spacing: 8) {
                Spacer()
                
                Button {
                    discoveryManager.rejectService(service)
                } label: {
                    Text("忽略")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button {
                    discoveryManager.confirmService(service)
                } label: {
                    Text("添加")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
    
    private func abbreviatedPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count > 3 {
            return ".../\(components.suffix(3).joined(separator: "/"))"
        }
        return path
    }
    
    private func abbreviatedURL(_ url: String) -> String {
        if let components = URL(string: url) {
            return components.host ?? url
        }
        return url
    }
}

// MARK: - 详情项

struct DetailItem: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.caption)
        }
        .foregroundColor(.secondary)
    }
}

// MARK: - 添加远程服务视图

struct AddRemoteServiceView: View {
    @StateObject private var discoveryManager = ServiceDiscoveryManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var gitURL = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            Form {
                Section("服务信息") {
                    TextField("服务名称", text: $name)
                    TextField("Git 仓库地址", text: $gitURL)
                        .textFieldStyle(.plain)
                }
                
                Section("说明") {
                    Text("系统会自动 clone 仓库到本地，并尝试检测技术栈和启动方式。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("添加远程服务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        addService()
                    }
                    .disabled(name.isEmpty || gitURL.isEmpty || isAdding)
                }
            }
        }
        .frame(width: 400, height: 250)
    }
    
    private func addService() {
        guard !name.isEmpty && !gitURL.isEmpty else { return }
        
        isAdding = true
        errorMessage = nil
        
        Task {
            let deployPath = "\(NSHomeDirectory())/.macassistant/services/\(name)"
            
            let result = await discoveryManager.addRemoteService(
                name: name,
                gitURL: gitURL,
                deployPath: deployPath
            )
            
            await MainActor.run {
                isAdding = false
                
                switch result {
                case .success:
                    dismiss()
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    PendingServicesView()
}
