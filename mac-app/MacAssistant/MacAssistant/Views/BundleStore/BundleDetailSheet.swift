import SwiftUI

struct BundleDetailSheet: View {
    let bundle: BundleMetadata
    @ObservedObject var viewModel: BundleStoreViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingQuickSetup = false
    @State private var setupResult: Result<AgentConfigurationSuggestion, Error>?
    
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
                    
                    // 沙箱配置
                    if let sandbox = bundle.sandboxConfig {
                        sandboxSection(sandbox)
                    }
                    
                    // Skills
                    if !bundle.skills.isEmpty {
                        skillsSection
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
        .sheet(isPresented: $showingQuickSetup) {
            QuickSetupSheet(
                bundle: bundle,
                result: $setupResult,
                onConfirm: { suggestion in
                    // 使用建议配置创建 Agent
                    dismiss()
                },
                onCancel: {
                    showingQuickSetup = false
                }
            )
        }
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
                            .help("官方 Bundle")
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
                    
                    Label("\(formatCount(bundle.installCount)) 次安装", systemImage: "arrow.down.circle")
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
            
            FlowLayout(spacing: 8) {
                ForEach(bundle.capabilities, id: \.self) { capability in
                    CapabilityCard(capability: capability)
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
                        
                        // 检查是否已安装
                        if isDependencyInstalled(dep.name) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.orange)
                        }
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
                    ProviderBadge(provider: provider)
                }
            }
        }
    }
    
    // MARK: - 沙箱区域
    
    private func sandboxSection(_ config: BundleMetadata.SandboxConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("沙箱配置")
                .font(.headline)
            
            HStack(spacing: 16) {
                HStack {
                    Image(systemName: "lock.shield")
                    Text(config.type.rawValue.uppercased())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.1))
                .foregroundColor(.accentColor)
                .cornerRadius(6)
                
                if config.required {
                    Label("必需", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                } else {
                    Label("可选", systemImage: "checkmark.circle")
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            if let defaultConfig = config.defaultConfig {
                VStack(alignment: .leading, spacing: 4) {
                    Text("默认配置:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ForEach(Array(defaultConfig.keys), id: \.self) { key in
                        HStack {
                            Text(key)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(defaultConfig[key] ?? "")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                }
                .padding(.leading)
            }
        }
    }
    
    // MARK: - Skills 区域
    
    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("包含的技能")
                .font(.headline)
            
            FlowLayout(spacing: 8) {
                ForEach(bundle.skills, id: \.self) { skill in
                    Label(skill, systemImage: "sparkles")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
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
                StatItem(
                    icon: "arrow.down.circle",
                    value: formatCount(bundle.installCount),
                    label: "安装"
                )
                
                if let rating = bundle.rating {
                    StatItem(
                        icon: "star.fill",
                        value: String(format: "%.1f", rating),
                        label: "评分"
                    )
                }
                
                StatItem(
                    icon: "clock",
                    value: bundle.lastUpdated, style: .date,
                    label: "更新"
                )
            }
        }
    }
    
    // MARK: - 底部操作栏
    
    @ViewBuilder
    private var bottomActionBar: some View {
        let status = viewModel.installStatus(for: bundle)
        
        HStack(spacing: 16) {
            // 安装状态
            switch status {
            case .notInstalled:
                HStack(spacing: 12) {
                    Button("安装") {
                        Task {
                            await viewModel.installBundle(bundle)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    
                    Button("快速配置") {
                        showingQuickSetup = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                
            case .installing(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    Text("安装中...")
                        .font(.caption)
                    ProgressView(value: progress)
                }
                
            case .installed:
                HStack(spacing: 12) {
                    Button("已安装") {}
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(true)
                    
                    Button("配置 Agent") {
                        showingQuickSetup = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                
            case .updating:
                ProgressView("更新中...")
                
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
                
            default:
                EmptyView()
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
    
    private func isDependencyInstalled(_ name: String) -> Bool {
        // TODO: 检查依赖是否已安装
        false
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

// MARK: - 辅助视图

struct CapabilityCard: View {
    let capability: BundleCapability
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: capability.icon)
                .font(.title2)
                .foregroundColor(.accentColor)
            
            Text(capability.displayName)
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .frame(width: 80, height: 80)
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(12)
    }
}

struct ProviderBadge: View {
    let provider: ProviderType
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
            Text(provider.displayName)
        }
        .font(.caption)
        .fontWeight(.medium)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(provider.color.opacity(0.1))
        .foregroundColor(provider.color)
        .cornerRadius(16)
    }
}

struct StatItem: View {
    let icon: String
    let value: String
    var style: Style = .text
    let label: String
    
    enum Style {
        case text
        case date
    }
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
            
            Text(value)
                .font(.headline)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 60)
    }
}

// MARK: - 快速配置 Sheet

struct QuickSetupSheet: View {
    let bundle: BundleMetadata
    @Binding var result: Result<AgentConfigurationSuggestion, Error>?
    let onConfirm: (AgentConfigurationSuggestion) -> Void
    let onCancel: () -> Void
    
    @State private var isLoading = false
    @State private var suggestion: AgentConfigurationSuggestion?
    
    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("正在生成配置建议...")
                            .foregroundColor(.secondary)
                    }
                } else if let suggestion = suggestion {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("\(bundle.name) 配置建议")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            ConfigRow(label: "Agent 名称", value: suggestion.name)
                            ConfigRow(label: "Provider", value: suggestion.provider.displayName)
                            ConfigRow(label: "模型", value: suggestion.model)
                            ConfigRow(label: "沙箱", value: suggestion.sandboxEnabled ? "已启用" : "未启用")
                            
                            if !suggestion.skills.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("技能:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(suggestion.skills.joined(separator: ", "))
                                }
                            }
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        
                        Spacer()
                        
                        HStack {
                            Button("取消", action: onCancel)
                                .buttonStyle(.bordered)
                            
                            Spacer()
                            
                            Button("创建 Agent") {
                                onConfirm(suggestion)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                } else if let error = result?.failure {
                    ErrorView(
                        message: error.localizedDescription,
                        retryAction: loadSuggestion
                    )
                }
            }
            .navigationTitle("快速配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
            }
        }
        .frame(width: 400, height: 400)
        .task {
            await loadSuggestion()
        }
    }
    
    private func loadSuggestion() async {
        isLoading = true
        
        // 模拟加载配置建议
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        suggestion = AgentConfigurationSuggestion(
            name: "\(bundle.name) Agent",
            provider: bundle.requiredProviders.first ?? .openAI,
            model: bundle.type == .claude ? "claude-sonnet-4" : "gpt-5.2",
            capabilities: bundle.capabilities,
            sandboxEnabled: bundle.sandboxConfig?.required ?? false,
            skills: bundle.skills
        )
        
        isLoading = false
    }
}

struct ConfigRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - 预览

#Preview("Bundle Detail") {
    BundleDetailSheet(
        bundle: BundleMetadata.samples[0],
        viewModel: .preview
    )
}

#Preview("Quick Setup") {
    QuickSetupSheet(
        bundle: BundleMetadata.samples[0],
        result: .constant(nil),
        onConfirm: { _ in },
        onCancel: {}
    )
}
