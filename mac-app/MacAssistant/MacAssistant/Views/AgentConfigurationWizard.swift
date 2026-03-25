//
//  AgentConfigurationWizard.swift
//  MacAssistant
//
//  Agent 配置向导 - 步骤化引导用户创建 Agent
//

import SwiftUI

struct AgentConfigurationWizard: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = WizardViewModel()
    
    var gap: CapabilityGap?
    var isInitialSetup: Bool = false
    var onComplete: ((Agent) -> Void)?
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题
            header
            
            Divider()
            
            // 步骤指示器
            stepIndicator
                .padding(.vertical, 16)
            
            Divider()
            
            // 主内容区
            ScrollView {
                VStack(spacing: 20) {
                    currentStepView
                        .padding(24)
                }
            }
            
            Divider()
            
            // 底部按钮
            footer
                .padding(16)
        }
        .frame(width: 520, height: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - 子视图
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(isInitialSetup ? "设置第一个 Agent" : "配置新 Agent")
                    .font(.system(size: 16, weight: .semibold))
                
                if let gap = gap {
                    Text("需要 \(gap.missingCapability.displayName) 能力")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if isInitialSetup {
                    Text("当前还没有可用的 LLM 或 CLI，请先完成一次配置")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
    
    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(ConfigurationStep.allCases.indices, id: \.self) { index in
                let step = ConfigurationStep.allCases[index]
                let isActive = index == viewModel.currentStep.rawValue
                let isCompleted = index < viewModel.currentStep.rawValue
                
                VStack(spacing: 4) {
                    // 步骤圆圈
                    ZStack {
                        Circle()
                            .fill(backgroundColor(for: step))
                            .frame(width: 28, height: 28)
                        
                        if isCompleted {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(isActive ? .white : .secondary)
                        }
                    }
                    
                    // 步骤标题 - 使用固定宽度确保不换行
                    Text(step.shortTitle)
                        .font(.system(size: 10))
                        .foregroundColor(isActive ? .primary : (isCompleted ? .primary : .secondary))
                        .lineLimit(1)
                        .frame(width: 60)
                }
                
                // 连接线
                if index < ConfigurationStep.allCases.count - 1 {
                    Rectangle()
                        .fill(isCompleted ? Color.blue : Color.gray.opacity(0.3))
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                }
            }
        }
        .padding(.horizontal, 16)
    }
    
    @ViewBuilder
    private var currentStepView: some View {
        switch viewModel.currentStep {
        case .selectProvider:
            ProviderSelectionStep(viewModel: viewModel, gap: gap, isInitialSetup: isInitialSetup)
        case .inputAPIKey:
            APIKeyInputStep(viewModel: viewModel)
        case .testConnection:
            TestConnectionStep(viewModel: viewModel)
        case .customizeSettings:
            CustomizeSettingsStep(viewModel: viewModel)
        case .assignRoles:
            RoleAssignmentStep(viewModel: viewModel, isInitialSetup: isInitialSetup)
        case .complete:
            CompletionStep(viewModel: viewModel, onFinish: { agent in
                onComplete?(agent)
                dismiss()
            })
        }
    }
    
    private var footer: some View {
        HStack {
            if viewModel.currentStep != .selectProvider && viewModel.currentStep != .complete {
                Button("上一步") {
                    viewModel.previousStep()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            
            Spacer()
            
            if viewModel.currentStep != .complete {
                Button(viewModel.currentStep == .assignRoles ? "创建 Agent" : "下一步") {
                    viewModel.nextStep()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!viewModel.canProceed)
            }
        }
    }
    
    private func backgroundColor(for step: ConfigurationStep) -> Color {
        let index = step.rawValue
        let currentIndex = viewModel.currentStep.rawValue
        
        if index < currentIndex {
            return .green
        } else if index == currentIndex {
            return .blue
        } else {
            return Color.gray.opacity(0.2)
        }
    }
}

// MARK: - 步骤视图

struct ProviderSelectionStep: View {
    @ObservedObject var viewModel: WizardViewModel
    var gap: CapabilityGap?
    var isInitialSetup: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择 AI 模型提供商")
                .font(.system(size: 14, weight: .medium))

            if isInitialSetup {
                Text("首次使用需要先配置一个可用 Agent，后续才可以开始对话、截图分析或执行 Skills。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if let gap = gap {
                Text("推荐用于 \(gap.missingCapability.displayName) 的提供商:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // 显示推荐 Agent
                ForEach(gap.suggestedAgents, id: \.name) { suggestion in
                    SuggestedAgentCard(
                        suggestion: suggestion,
                        isSelected: viewModel.selectedProvider == suggestion.provider,
                        onSelect: {
                            viewModel.selectProvider(suggestion.provider, model: suggestion.model)
                        }
                    )
                }
                
                Divider()
                    .padding(.vertical, 8)
            }
            
            Text("所有可用提供商:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 12) {
                ForEach(ProviderType.allCases) { provider in
                    ProviderCard(
                        provider: provider,
                        isSelected: viewModel.selectedProvider == provider,
                        onSelect: { viewModel.selectProvider(provider) }
                    )
                }
            }
        }
    }
}

struct APIKeyInputStep: View {
    @ObservedObject var viewModel: WizardViewModel
    @State private var validationResult: AgentStore.ValidationResult?
    @State private var isValidating = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let provider = viewModel.selectedProvider {
                HStack {
                    Image(systemName: provider.icon)
                        .font(.title2)
                        .foregroundColor(.blue)
                    
                    VStack(alignment: .leading) {
                        Text(provider.displayName)
                            .font(.system(size: 16, weight: .medium))
                        Text("模型: \(viewModel.selectedModel ?? provider.availableModels[0])")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let setupHint = provider.setupHint {
                    Text(setupHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.modelLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField(
                        provider.modelPlaceholder,
                        text: Binding(
                            get: { viewModel.selectedModel ?? provider.recommendedModel },
                            set: { viewModel.selectedModel = $0 }
                        )
                    )
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                Divider()
                
                if provider.requiresAPIKey {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("API Key")
                                .font(.system(size: 13, weight: .medium))
                            
                            SecureField(provider.apiKeyPlaceholder, text: $viewModel.apiKey)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            
                            HStack {
                                Text("您的 API Key 将安全存储在本地")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                // 实时验证按钮
                                Button(action: validateKey) {
                                    HStack(spacing: 4) {
                                        if isValidating {
                                            ProgressView()
                                                .scaleEffect(0.6)
                                                .frame(width: 12, height: 12)
                                        } else if let result = validationResult {
                                            Image(systemName: result.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                .foregroundColor(result.isValid ? .green : .red)
                                        }
                                        Text(validationButtonText)
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(viewModel.apiKey.isEmpty || isValidating)
                            }
                            
                            // 验证结果显示
                            if let result = validationResult {
                                Text(result.message)
                                    .font(.caption)
                                    .foregroundColor(result.isValid ? .green : .red)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .background(result.isValid ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }
                        
                        Link("获取 API Key →", destination: apiKeyHelperURL(for: provider))
                            .font(.caption)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "terminal")
                                .foregroundColor(.green)
                            Text("\(provider.displayName) 使用 CLI 自身的认证配置")
                                .foregroundColor(.secondary)
                        }

                        Text("请先确认以下准备项：")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. 已安装 `kimi` 命令")
                            Text("2. 如果首次使用会要求选择 provider、登录或输入 API Key，请先在终端完成 `kimi login`")
                            Text("3. 如需手动修改凭证，可编辑 `~/.kimi/config.toml`")
                            Text("4. 如果终端里已经出现 `logged in successfully`，即使后面还有 shell 警告，也可以先回来点“开始测试”")
                            Text("5. 返回这里点击\"开始测试\"验证 CLI 是否真的能跑通")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)

                        HStack(spacing: 12) {
                            Button("终端执行 kimi login") {
                                launchKimiLogin()
                            }
                            .buttonStyle(SecondaryButtonStyle())

                            Button("打开 ~/.kimi/config.toml") {
                                openKimiConfig()
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }
    
    private var validationButtonText: String {
        if isValidating {
            return "验证中..."
        } else if validationResult != nil {
            return "重新验证"
        } else {
            return "验证 Key"
        }
    }
    
    private func validateKey() {
        guard let provider = viewModel.selectedProvider else { return }
        
        isValidating = true
        validationResult = nil
        
        Task {
            let result = await AgentStore.shared.validateAPIKey(
                provider: provider,
                apiKey: viewModel.apiKey
            )
            
            await MainActor.run {
                self.validationResult = result
                self.isValidating = false
            }
        }
    }

    private func launchKimiLogin() {
        AgentStore.shared.launchKimiLogin()
    }

    private func openKimiConfig() {
        AgentStore.shared.openKimiConfig()
    }
    
    private func apiKeyHelperURL(for provider: ProviderType) -> URL {
        URL(string: provider.apiDocsURL)!
    }
}

struct TestConnectionStep: View {
    @ObservedObject var viewModel: WizardViewModel
    
    var body: some View {
        VStack(spacing: 24) {
            if viewModel.isTesting {
                ProgressView()
                    .scaleEffect(1.5)
                
                Text("正在测试连接...")
                    .foregroundColor(.secondary)
            } else if let error = viewModel.testError {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.red)
                
                Text("连接失败")
                    .font(.headline)
                
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Button("重试") {
                    viewModel.testConnection()
                }
                .buttonStyle(SecondaryButtonStyle())

                if viewModel.selectedProvider == .ollama {
                    HStack(spacing: 12) {
                        Button("终端执行 kimi login") {
                            launchKimiLogin()
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        Button("打开 ~/.kimi/config.toml") {
                            openKimiConfig()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            } else if viewModel.testSuccess {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
                
                Text("连接成功!")
                    .font(.headline)
                
                Text("Agent 可以正常使用 \(viewModel.selectedProvider?.displayName ?? "") 的服务。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Button("开始测试") {
                    viewModel.testConnection()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func launchKimiLogin() {
        AgentStore.shared.launchKimiLogin()
    }

    private func openKimiConfig() {
        AgentStore.shared.openKimiConfig()
    }
}

struct CustomizeSettingsStep: View {
    @ObservedObject var viewModel: WizardViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自定义 Agent 设置")
                .font(.system(size: 14, weight: .medium))
            
            HStack(spacing: 12) {
                TextField("名称", text: $viewModel.agentName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                TextField("Emoji", text: $viewModel.agentEmoji)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 60)
            }
            
            TextField("描述", text: $viewModel.agentDescription)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            if let provider = viewModel.selectedProvider {
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.modelLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField(
                        provider.modelPlaceholder,
                        text: Binding(
                            get: { viewModel.selectedModel ?? provider.recommendedModel },
                            set: { viewModel.selectedModel = $0 }
                        )
                    )
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                    if let setupHint = provider.setupHint {
                        Text(setupHint)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            
            Divider()
            
            // 模型配置信息
            if let provider = viewModel.selectedProvider, 
               let model = viewModel.selectedModel {
                let config = provider.modelConfig(for: model)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("模型规格")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // 显示模型配置卡片
                    HStack(spacing: 16) {
                        // Context Window
                        VStack(alignment: .leading, spacing: 2) {
                            Text("上下文窗口")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(config.formattedContextWindow)
                                .font(.system(size: 14, weight: .medium))
                            Text("输入+输出总计")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        
                        Divider()
                            .frame(height: 30)
                        
                        // Max Output
                        VStack(alignment: .leading, spacing: 2) {
                            Text("最大输出")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(config.formattedMaxOutput)
                                .font(.system(size: 14, weight: .medium))
                            Text("单次回复上限")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(6)
                    
                    // Temperature - 根据模型自动调整
                    let isFixedTemp = model.contains("kimi-k2.5") || model.contains("kimi-k2")
                    
                    if isFixedTemp {
                        HStack {
                            Text("Temperature")
                                .font(.caption)
                            Spacer()
                            Text("1.0 (固定值)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text("此模型只支持 temperature = 1，已自动设置")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    } else {
                        HStack {
                            Text("Temperature")
                                .font(.caption)
                            Slider(value: $viewModel.temperature, in: 0...2, step: 0.1)
                            Text(String(format: "%.1f", viewModel.temperature))
                                .font(.caption)
                                .monospacedDigit()
                                .frame(width: 30)
                        }
                    }
                    
                    // 输出长度限制选择
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("输出长度限制")
                                .font(.caption)
                            Spacer()
                            Text("\(viewModel.maxTokens / 1024)K tokens")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        // 根据模型最大输出限制提供合理选项
                        let maxOutput = config.maxOutputTokens
                        Picker("", selection: $viewModel.maxTokens) {
                            if maxOutput >= 2048 {
                                Text("2K").tag(2048)
                            }
                            if maxOutput >= 4096 {
                                Text("4K").tag(4096)
                            }
                            if maxOutput >= 8192 {
                                Text("8K").tag(8192)
                            }
                            if maxOutput >= 16384 {
                                Text("16K").tag(16384)
                            }
                            if maxOutput >= 32768 {
                                Text("32K").tag(32768)
                            }
                            if maxOutput >= 65536 {
                                Text("64K").tag(65536)
                            }
                            if maxOutput >= 100000 {
                                Text("100K").tag(100000)
                            }
                            if maxOutput >= 128000 {
                                Text("128K").tag(128000)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        
                        // 提示超出模型限制
                        if viewModel.maxTokens > config.maxOutputTokens {
                            Text("⚠️ 选择的输出长度超过模型限制的 \(config.formattedMaxOutput)，将自动调整为模型最大值")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
        }
    }
}

struct RoleAssignmentStep: View {
    @ObservedObject var viewModel: WizardViewModel
    var isInitialSetup: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("分配 Agent 角色")
                .font(.system(size: 14, weight: .medium))

            Text(
                isInitialSetup
                ? "首次配置至少需要一个 Planner 角色的 Agent（同时承担主对话）。子任务、回退角色可以后续补充。"
                : "一个 Agent 可以承担多个角色。Planner 同时负责主对话和意图分析，子任务和回退会分开协作。"
            )
            .font(.caption)
            .foregroundColor(.secondary)

            VStack(spacing: 10) {
                ForEach(AgentRole.allCases) { role in
                    roleToggle(role)
                }
            }

            Text(roleHint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func roleToggle(_ role: AgentRole) -> some View {
        Toggle(
            isOn: Binding(
                get: { viewModel.roleProfile.contains(role) },
                set: { viewModel.setRole(role, enabled: $0) }
            )
        ) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: role.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.blue)
                    Text(role.displayName)
                        .font(.system(size: 13, weight: .semibold))
                }

                Text(role.summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.03))
        )
    }

    private var roleHint: String {
        if viewModel.roleProfile.contains(.manualOnly) {
            return "当前设置为仅手动：它不会参与自动路由，只在手动选择时使用。"
        }

        // Planner 同时承担主会话职责
        if viewModel.roleProfile.contains(.planner) && viewModel.roleProfile.contains(.subtaskWorker) {
            return "当前这个 Agent 既能作为 Planner（主对话 + 意图分析），也能在后台承担独立子任务。"
        }

        if viewModel.roleProfile.contains(.planner) {
            return "当前这个 Agent 作为 Planner，负责主对话和意图分析调度。"
        }

        return "建议给主用 Agent 勾选\"Planner\"（主对话 + 意图分析），给稳定 API Agent 勾选\"子任务 / 回退\"。"
    }
}

struct CompletionStep: View {
    @ObservedObject var viewModel: WizardViewModel
    var onFinish: (Agent) -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
            
            Text("Agent 创建成功!")
                .font(.title2)
                .fontWeight(.semibold)
            
            if let agent = viewModel.createdAgent {
                HStack {
                    Text(agent.emoji)
                        .font(.title)
                    VStack(alignment: .leading) {
                        Text(agent.name)
                            .font(.headline)
                        Text(agent.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)

                FlowLayout(spacing: 6) {
                    ForEach(viewModel.roleProfile.sortedRoles) { role in
                        AgentRoleBadge(role: role)
                    }
                }
            }
            
            Button("开始使用") {
                if let agent = viewModel.createdAgent {
                    onFinish(agent)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 辅助视图

struct ProviderCard: View {
    let provider: ProviderType
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                Image(systemName: provider.icon)
                    .font(.title2)
                    .foregroundColor(isSelected ? .white : .blue)
                
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
            }
            .frame(height: 70)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.blue : Color.gray.opacity(0.1))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct SuggestedAgentCard: View {
    let suggestion: CapabilityGap.SuggestedAgent
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Text(suggestion.emoji)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.system(size: 13, weight: .medium))
                    
                    Text(suggestion.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    Text("\(suggestion.provider.displayName) • \(suggestion.model)")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
            }
            .padding()
            .background(isSelected ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 按钮样式

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(6)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.2))
            .foregroundColor(.primary)
            .cornerRadius(6)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}
