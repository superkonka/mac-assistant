import SwiftUI

struct IntentSelectorView: View {
    let onSelect: (UserIntent) -> Void
    @Environment(\.dismiss) private var dismiss
    
    let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("你想做什么？")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("选择使用场景，我们将推荐最适合的 Bundles")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 意图网格
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(UserIntent.allCases) { intent in
                        IntentCard(intent: intent, onTap: { onSelect(intent) })
                    }
                }
                .padding()
            }
            
            Divider()
            
            // 底部按钮
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 600, height: 450)
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
                    .foregroundColor(.primary)
                
                HStack(spacing: 4) {
                    ForEach(intent.suggestedBundles.prefix(3), id: \.self) { _ in
                        Circle()
                            .fill(Color.accentColor.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .frame(height: 130)
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
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - BundleQuickSetupWizard

struct BundleQuickSetupWizard: View {
    let bundle: BundleMetadata
    let onComplete: (AgentConfiguration) -> Void
    let onCancel: () -> Void
    
    @State private var currentStep = 0
    @State private var configuration = AgentConfiguration()
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("配置 \(bundle.name)")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 进度
            ProgressView(value: Double(currentStep + 1), total: Double(totalSteps))
                .padding()
            
            // 内容
            stepsView
                .padding()
            
            Spacer()
            
            Divider()
            
            // 导航按钮
            HStack {
                // 取消按钮（随时可用）
                Button("取消") { onCancel() }
                    .keyboardShortcut(.escape)
                
                Spacer()
                
                if currentStep > 0 {
                    Button("上一步") { currentStep -= 1 }
                }
                
                if currentStep < totalSteps - 1 {
                    Button("下一步") { currentStep += 1 }
                        .keyboardShortcut(.return)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("完成配置") { onComplete(configuration) }
                        .keyboardShortcut(.return)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 500, height: 450)
    }
    
    @ViewBuilder
    private var stepsView: some View {
        switch currentStep {
        case 0:
            BundleProviderSelectionStep(bundle: bundle, configuration: $configuration)
        case 1:
            ModelSelectionStep(bundle: bundle, configuration: $configuration)
        case 2:
            if let sandbox = bundle.sandboxConfig, sandbox.required {
                SandboxConfigurationStep(sandbox: sandbox, configuration: $configuration)
            } else {
                SkillsSelectionStep(bundle: bundle, configuration: $configuration)
            }
        case 3:
            SkillsSelectionStep(bundle: bundle, configuration: $configuration)
        default:
            EmptyView()
        }
    }
    
    private var totalSteps: Int {
        var steps = 3
        if let sandbox = bundle.sandboxConfig, sandbox.required { steps += 1 }
        return steps
    }
}

// MARK: - 配置步骤视图

struct BundleProviderSelectionStep: View {
    let bundle: BundleMetadata
    @Binding var configuration: AgentConfiguration
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择 Provider").font(.headline)
            Text("\(bundle.name) 支持以下 Provider：")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            ForEach(bundle.requiredProviders, id: \.self) { provider in
                ProviderSelectionRow(
                    provider: provider,
                    isSelected: configuration.provider == provider,
                    onSelect: { configuration.provider = provider }
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
                Image(systemName: "cpu").foregroundColor(provider.color)
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
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
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
            Text("选择模型").font(.headline)
            Text("选择适合你的模型：").font(.subheadline).foregroundColor(.secondary)
            
            ForEach(getRecommendedModels(), id: \.self) { model in
                ModelSelectionRow(
                    model: model,
                    isSelected: configuration.model == model,
                    onSelect: { configuration.model = model }
                )
            }
        }
    }
    
    private func getRecommendedModels() -> [String] {
        switch bundle.type {
        case .claude: return ["claude-sonnet-4", "claude-opus-4", "claude-haiku-4"]
        case .codex: return ["gpt-5.2", "gpt-5.1", "gpt-4.1"]
        case .cursor: return ["cursor-fast", "cursor-slow"]
        case .custom: return ["gpt-5.2", "claude-sonnet-4"]
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
                Image(systemName: "cpu").foregroundColor(.secondary)
                Text(model).font(.subheadline).fontWeight(isSelected ? .semibold : .regular)
                Spacer()
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor) }
            }
            .padding()
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct SandboxConfigurationStep: View {
    let sandbox: BundleMetadata.SandboxConfiguration
    @Binding var configuration: AgentConfiguration
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("沙箱配置").font(.headline)
            Text("此 Bundle 需要沙箱环境：").font(.subheadline).foregroundColor(.secondary)
            
            HStack {
                Image(systemName: "lock.shield").font(.largeTitle).foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text(sandbox.type.rawValue).font(.headline)
                }
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            Toggle("启用沙箱", isOn: $configuration.sandboxEnabled)
        }
    }
}

struct SkillsSelectionStep: View {
    let bundle: BundleMetadata
    @Binding var configuration: AgentConfiguration
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择技能").font(.headline)
            Text("为此 Bundle 启用以下技能：").font(.subheadline).foregroundColor(.secondary)
            
            ForEach(bundle.skills, id: \.self) { skill in
                SkillToggleRow(skill: skill, isEnabled: configuration.enabledSkills.contains(skill)) { isOn in
                    if isOn {
                        configuration.enabledSkills.append(skill)
                    } else {
                        configuration.enabledSkills.removeAll { $0 == skill }
                    }
                }
            }
        }
    }
}

struct SkillToggleRow: View {
    let skill: String
    let isEnabled: Bool
    let onToggle: (Bool) -> Void
    
    var body: some View {
        Toggle(isOn: Binding(get: { isEnabled }, set: onToggle)) {
            HStack {
                Image(systemName: "puzzlepiece.extension")
                Text(skill)
            }
        }
        .toggleStyle(.switch)
    }
}

// MARK: - AgentConfiguration

struct AgentConfiguration {
    var provider: ProviderType = .openai
    var model: String = "gpt-5.2"
    var sandboxEnabled: Bool = false
    var enabledSkills: [String] = []
}

// MARK: - ProviderType Extension

extension ProviderType {
    var description: String {
        switch self {
        case .openai: return "OpenAI GPT 系列模型"
        case .anthropic: return "Anthropic Claude 系列"
        case .deepseek: return "DeepSeek 中文模型"
        case .doubao: return "字节跳动豆包"
        case .zhipu: return "智谱 AI"
        case .ollama: return "本地 Ollama 模型"
        case .moonshot: return "Moonshot Kimi"
        case .google: return "Google Gemini"
        case .minimax: return "MiniMax 中文模型"
        }
    }
}

// MARK: - Preview

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
