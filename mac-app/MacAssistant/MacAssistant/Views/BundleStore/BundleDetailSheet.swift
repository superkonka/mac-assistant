import SwiftUI

struct BundleDetailSheet: View {
    let bundle: BundleMetadata
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingQuickSetup = false
    @State private var isInstalling = false
    @State private var isInstalled = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 头部信息
                    headerSection
                    
                    Divider()
                    
                    // 能力标签
                    capabilitiesSection
                    
                    // 依赖信息
                    if !bundle.dependencies.isEmpty {
                        dependenciesSection
                    }
                    
                    // Provider 要求
                    if !bundle.requiredProviders.isEmpty {
                        providersSection
                    }
                    
                    // 统计信息
                    statsSection
                }
                .padding()
            }
            .navigationTitle(bundle.name)
            .navigationSubtitle("v\(bundle.version)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // 底部操作栏
                bottomActionBar
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
            }
        }
        .frame(minWidth: 500, minHeight: 600)
    }
    
    // MARK: - 头部区域
    
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 20) {
            // 大图标
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(bundleTypeGradient)
                    .frame(width: 100, height: 100)
                
                Image(systemName: bundle.type.icon)
                    .font(.system(size: 48))
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(bundle.name)
                        .font(.title)
                        .fontWeight(.bold)
                    
                    if bundle.isOfficial {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                    }
                }
                
                Text(bundle.type.displayName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text(bundle.description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack(spacing: 12) {
                    Label(bundle.author, systemImage: "person")
                    
                    if let rating = bundle.rating {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", rating))
                        }
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - 能力区域
    
    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("能力")
                .font(.headline)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                ForEach(bundle.capabilities, id: \.self) { capability in
                    VStack(spacing: 8) {
                        Image(systemName: capability.icon)
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        
                        Text(capability.displayName)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 100, height: 80)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(12)
                }
            }
        }
    }
    
    // MARK: - 依赖区域
    
    private var dependenciesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("依赖")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                ForEach(bundle.dependencies, id: \.name) { dep in
                    HStack {
                        Image(systemName: dep.optional ? "circle" : "circle.fill")
                            .foregroundColor(dep.optional ? .secondary : .accentColor)
                            .font(.caption)
                        
                        Text(dep.name)
                        Text(dep.versionRange)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if dep.optional {
                            Text("可选")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)
                        }
                        
                        Spacer()
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
    
    // MARK: - Provider 区域
    
    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("需要的 Provider")
                .font(.headline)
            
            HStack(spacing: 12) {
                ForEach(bundle.requiredProviders, id: \.self) { provider in
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                        Text(provider.displayName)
                    }
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundColor(.accentColor)
                    .cornerRadius(16)
                }
            }
        }
    }
    
    // MARK: - 统计区域
    
    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("统计")
                .font(.headline)
            
            HStack(spacing: 24) {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                    
                    Text(formatCount(bundle.installCount))
                        .font(.headline)
                    
                    Text("安装")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let rating = bundle.rating {
                    VStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                        
                        Text(String(format: "%.1f", rating))
                            .font(.headline)
                        
                        Text("评分")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
    
    // MARK: - 底部操作栏
    
    @ViewBuilder
    private var bottomActionBar: some View {
        HStack(spacing: 16) {
            if isInstalling {
                ProgressView("安装中...")
            } else if isInstalled {
                Label("已安装", systemImage: "checkmark")
                    .foregroundColor(.green)
            } else {
                Button("安装") {
                    isInstalling = true
                    // 模拟安装
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isInstalling = false
                        isInstalled = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            
            Spacer()
        }
    }
    
    // MARK: - 辅助方法
    
    private var bundleTypeGradient: LinearGradient {
        switch bundle.type {
        case .codex:
            return LinearGradient(colors: [.green, .green.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .claude:
            return LinearGradient(colors: [.orange, .orange.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .cursor:
            return LinearGradient(colors: [.purple, .purple.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .custom:
            return LinearGradient(colors: [.gray, .gray.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
    
    private func formatCount(_ count: Int) -> String {
        if count >= 10000 {
            return String(format: "%.1fw", Double(count) / 10000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        } else {
            return "\(count)"
        }
    }
}

// MARK: - 预览

#Preview("Bundle Detail") {
    BundleDetailSheet(
        bundle: BundleMetadata.samples[0]
    )
}
