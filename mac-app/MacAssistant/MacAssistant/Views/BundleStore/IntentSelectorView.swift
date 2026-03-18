import SwiftUI

struct IntentSelectorView: View {
    let onSelect: (UserIntent) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // 标题
                    VStack(spacing: 8) {
                        Text("你想做什么？")
                            .font(.title)
                            .fontWeight(.bold)
                        
                        Text("选择你的使用场景，我们将推荐最适合的 Bundles")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)
                    
                    // 意图网格
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150))],
                        spacing: 16
                    ) {
                        ForEach(UserIntent.allCases) { intent in
                            IntentCard(
                                intent: intent,
                                onTap: {
                                    onSelect(intent)
                                }
                            )
                        }
                    }
                    .padding()
                    
                    Spacer()
                }
            }
            .navigationTitle("智能推荐")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 500, height: 500)
    }
}

struct IntentCard: View {
    let intent: UserIntent
    let onTap: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                Image(systemName: intent.icon)
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
                
                Text(intent.displayName)
                    .font(.headline)
                
                // 推荐 Bundles 预览
                HStack(spacing: 4) {
                    ForEach(intent.suggestedBundles.prefix(3), id: \.self) { bundleId in
                        Circle()
                            .fill(Color.accentColor.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovered ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 快速配置向导

struct BundleQuickSetupWizard: View {
    let bundle: BundleMetadata
    let onComplete: (AgentConfiguration) -> Void
    let onCancel: () -> Void
    
    @State private var currentStep = 0
    @State private var configuration = AgentConfiguration()
    
    var body: some View {
        NavigationView {
            VStack {
                // 进度指示器
                ProgressView(value: Double(currentStep + 1), total: Double(totalSteps))
                    .padding()
                
                // 步骤内容
                stepsView
                    .padding()
                
                Spacer()
                
                // 导航按钮
                HStack {
                    if currentStep > 0 {
                        Button("上一步") {
                            currentStep -= 1
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Spacer()
                    
                    if currentStep < totalSteps - 1 {
                        Button("下一步") {
                            currentStep += 1
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("完成配置") {
                            onComplete(configuration)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }
            .navigationTitle("配置 \(bundle.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
            }
        }
        .frame(width: 500, height: 400)
    }
    
    @ViewBuilder
    private var stepsView: some View {
        switch currentStep {
        case 0:
            ProviderSelectionStep(
                bundle: bundle,
                configuration: $configuration
            )
        case 1:
            ModelSelectionStep(
                bundle: bundle,
                configuration: $configuration
            )
        case 2:
            if let sandbox = bundle.sandboxConfig, sandbox.required {
                SandboxConfigurationStep(
                    sandbox: sandbox,
                    configuration: $configuration
                )
            } else {
                SkillsSelectionStep(
                    bundle: bundle,
                    configuration: $configuration
                )
            }
        case 3:
            SkillsSelectionStep(
                bundle: bundle,
                configuration: $configuration
            )
        default:
            EmptyView()
        }
    }
    
    private var totalSteps: Int {
        var steps = 3 // Provider, Model, Skills
        if let sandbox = bundle.sandboxConfig, sandbox.required {
            steps += 1
        }
        return steps
    }
}

// MARK: - 配置步骤视图

struct ProviderSelectionStep: View {
    let bundle: BundleMetadata
    @Binding var configuration: AgentConfiguration
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择 Provider")
                .font(.headline)
            
            Text("\(bundle.name) 支持以下 Provider，请选择一个：")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            ForEach(bundle.requiredProviders, id: \.self) { provider in
                ProviderSelectionRow(
                    provider: provider,
                    isSelected: configuration.provider == provider,
                    onSelect: {
                        configuration.provider = provider
                    }
                )
            }
        }
    }
}

struct ProviderSelectionRow: View {
    let provider: ProviderType
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: "cpu")
                    .foregroundColor(provider.color)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                    
                    Text(provider.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding()
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct ModelSelectionStep: View {
    let bundle: BundleMetadata
    @Binding var configuration: AgentConfiguration
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择模型")
                .font(.headline)
            
            Text("选择适合你的模型：")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            // 根据 bundle 类型推荐模型
            let recommendedModels = getRecommendedModels()
            
            ForEach(recommendedModels, id: \.self) { model in
                ModelSelectionRow(
                    model: model,
                    isSelected: configuration.model == model,
                    onSelect: {
                        configuration.model = model
                    }
                )
            }
        }
    }
    
    private func getRecommendedModels() -> [String] {
        switch bundle.type {
        case .claude:
            return ["claude-sonnet-4", "claude-opus-4", "claude-haiku-4"]
        case .codex:
            return ["codex-latest", "codex-002"]
        case .cursor:
            return ["cursor-default", "cursor-fast"]
        case .custom:
            return ["gpt-5.2", "gpt-5.4-mini", "deepseek-chat"]
        }
    }
}

struct ModelSelectionRow: View {
    let model: String
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model)
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                    
                    Text(getModelDescription(model))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding()
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    private func getModelDescription(_ model: String) -> String {
        switch model {
        case "claude-sonnet-4":
            return "平衡性能和成本的最佳选择"
        case "claude-opus-4":
            return "最强大的推理能力，适合复杂任务"
        case "claude-haiku-4":
            return "最快响应，适合简单任务"
        case "codex-latest":
            return "最新的代码生成能力"
        default:
            return "标准模型"
        }
    }
}

struct SandboxConfigurationStep: View {
    let sandbox: BundleMetadata.SandboxConfiguration
    @Binding var configuration: AgentConfiguration
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("配置沙箱")
                .font(.headline)
            
            HStack {
                Image(systemName: "lock.shield")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(sandbox.type.rawValue.uppercased()) Sandbox")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Text(sandbox.required ? "此 Bundle 需要沙箱支持" : "可选配置")
                        .font(.caption)
                        .foregroundColor(sandbox.required ? .orange : .secondary)
                }
            }
            
            if let defaultConfig = sandbox.defaultConfig {
                Text("默认配置：")
                    .font(.subheadline)
                    .padding(.top)
                
                ForEach(Array(defaultConfig.keys), id: \.self) { key in
                    HStack {
                        Text(key)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(defaultConfig[key] ?? "")
                            .fontWeight(.medium)
                    }
                    .padding(.vertical, 2)
                }
            }
            
            Toggle("启用沙箱", isOn: $configuration.sandboxEnabled)
                .padding(.top)
        }
    }
}

struct SkillsSelectionStep: View {
    let bundle: BundleMetadata
    @Binding var configuration: AgentConfiguration
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择技能")
                .font(.headline)
            
            Text("\(bundle.name) 包含以下技能，选择要启用的：")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            ForEach(bundle.skills, id: \.self) { skill in
                Toggle(skill, isOn: Binding(
                    get: { configuration.enabledSkills.contains(skill) },
                    set: { isOn in
                        if isOn {
                            configuration.enabledSkills.append(skill)
                        } else {
                            configuration.enabledSkills.removeAll { $0 == skill }
                        }
                    }
                ))
            }
            
            Toggle("全选", isOn: Binding(
                get: { configuration.enabledSkills.count == bundle.skills.count },
                set: { isOn in
                    if isOn {
                        configuration.enabledSkills = bundle.skills
                    } else {
                        configuration.enabledSkills = []
                    }
                }
            ))
            .padding(.top)
        }
    }
}

// MARK: - 配置模型

struct AgentConfiguration {
    var provider: ProviderType = .openAI
    var model: String = "gpt-5.2"
    var sandboxEnabled: Bool = false
    var enabledSkills: [String] = []
}

// MARK: - Provider 扩展

extension ProviderType {
    var description: String {
        switch self {
        case .openAI:
            return "OpenAI GPT 系列模型"
        case .anthropic:
            return "Anthropic Claude 系列"
        case .deepSeek:
            return "DeepSeek 中文模型"
        case .doubao:
            return "字节跳动豆包"
        case .zhipu:
            return "智谱 AI"
        case .ollama:
            return "本地 Ollama 模型"
        case .kimi:
            return "Moonshot Kimi"
        }
    }
}

// MARK: - 预览

#Preview("Intent Selector") {
    IntentSelectorView { intent in
        print("Selected: \(intent)")
    }
}

#Preview("Quick Setup Wizard") {
    BundleQuickSetupWizard(
        bundle: BundleMetadata.samples[0],
        onComplete: { _ in },
        onCancel: {}
    )
}
