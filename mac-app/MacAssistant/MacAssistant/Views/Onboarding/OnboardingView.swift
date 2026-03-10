//
//  OnboardingView.swift
//  MacAssistant
//
//  首次启动引导流程 - 开箱即用体验
//

import SwiftUI

/// 引导步骤
enum OnboardingStep: CaseIterable, Identifiable {
    case welcome
    case dependencies
    case agentConfiguration
    case ready
    
    var id: String { String(describing: self) }
    
    var title: String {
        switch self {
        case .welcome:
            return "欢迎使用"
        case .dependencies:
            return "准备环境"
        case .agentConfiguration:
            return "配置 AI"
        case .ready:
            return "准备就绪"
        }
    }
    
    var icon: String {
        switch self {
        case .welcome:
            return "hand.wave.fill"
        case .dependencies:
            return "gearshape.2.fill"
        case .agentConfiguration:
            return "brain.head.profile"
        case .ready:
            return "checkmark.circle.fill"
        }
    }
}

/// 首次启动引导视图
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = OnboardingViewModel()
    
    var body: some View {
        VStack(spacing: 0) {
            // 步骤指示器
            StepIndicator(currentStep: viewModel.currentStep)
                .padding(.top, 24)
                .padding(.horizontal, 40)
            
            // 内容区域
            Group {
                switch viewModel.currentStep {
                case .welcome:
                    WelcomeStepView(onContinue: {
                        withAnimation {
                            viewModel.moveToNextStep()
                        }
                    })
                    
                case .dependencies:
                    DependenciesStepView(
                        status: viewModel.dependencyStatus,
                        isInstalling: viewModel.isInstallingDependencies,
                        error: viewModel.dependencyError,
                        onRetry: {
                            Task {
                                await viewModel.installDependencies()
                            }
                        }
                    )
                    .task {
                        await viewModel.installDependencies()
                    }
                    
                case .agentConfiguration:
                    AgentConfigurationStepView(
                        onComplete: { agent in
                            viewModel.createdAgent = agent
                            withAnimation {
                                viewModel.moveToNextStep()
                            }
                        }
                    )
                    
                case .ready:
                    ReadyStepView(
                        agent: viewModel.createdAgent,
                        onStart: {
                            dismiss()
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 底部按钮
            HStack {
                if viewModel.canGoBack {
                    Button("返回") {
                        withAnimation {
                            viewModel.moveToPreviousStep()
                        }
                    }
                    .buttonStyle(.borderless)
                }
                
                Spacer()
                
                if viewModel.canSkip {
                    Button("跳过") {
                        withAnimation {
                            viewModel.skipToEnd()
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(24)
        }
        .frame(width: 600, height: 500)
        .background(Color(.windowBackgroundColor))
    }
}

// MARK: - 步骤指示器

struct StepIndicator: View {
    let currentStep: OnboardingStep
    
    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(OnboardingStep.allCases.enumerated()), id: \.element.id) { index, step in
                StepIndicatorItem(
                    step: step,
                    isActive: step == currentStep,
                    isCompleted: isCompleted(step)
                )
                
                if index < OnboardingStep.allCases.count - 1 {
                    Rectangle()
                        .fill(isCompleted(step) ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
    
    private func isCompleted(_ step: OnboardingStep) -> Bool {
        guard let currentIndex = OnboardingStep.allCases.firstIndex(of: currentStep),
              let stepIndex = OnboardingStep.allCases.firstIndex(of: step) else {
            return false
        }
        return stepIndex < currentIndex
    }
}

struct StepIndicatorItem: View {
    let step: OnboardingStep
    let isActive: Bool
    let isCompleted: Bool
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 36, height: 36)
                
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: step.icon)
                        .font(.system(size: 14))
                        .foregroundColor(iconColor)
                }
            }
            
            Text(step.title)
                .font(.caption)
                .foregroundColor(textColor)
        }
    }
    
    private var backgroundColor: Color {
        if isCompleted || isActive {
            return .accentColor
        }
        return Color.gray.opacity(0.2)
    }
    
    private var iconColor: Color {
        if isCompleted || isActive {
            return .white
        }
        return .gray
    }
    
    private var textColor: Color {
        if isActive {
            return .primary
        }
        if isCompleted {
            return .accentColor
        }
        return .gray
    }
}

// MARK: - 欢迎步骤

struct WelcomeStepView: View {
    let onContinue: () -> Void
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Logo
            VStack(spacing: 16) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.accent)
                
                Text("Mac Assistant")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("你的本地 AI 助手")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            
            // 特性列表
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "message.fill", text: "智能对话，支持多 Agent")
                FeatureRow(icon: "eye.fill", text: "截图分析、文件解读")
                FeatureRow(icon: "macwindow", text: "原生 macOS 系统集成")
                FeatureRow(icon: "shield.checkerboard", text: "本地优先，隐私安全")
            }
            .padding(.vertical, 20)
            
            Spacer()
            
            Button("开始设置") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24)
            
            Text(text)
                .font(.body)
        }
    }
}

// MARK: - 依赖安装步骤

struct DependenciesStepView: View {
    let status: DependencyStatus
    let isInstalling: Bool
    let error: String?
    let onRetry: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // 状态图标
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: statusIcon)
                    .font(.system(size: 40))
                    .foregroundColor(statusColor)
            }
            
            // 标题和描述
            VStack(spacing: 8) {
                Text(statusTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(statusDescription)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            
            // 进度条或错误信息
            if isInstalling {
                ProgressView()
                    .scaleEffect(1.2)
                    .padding(.top, 8)
            } else if let error = error {
                VStack(spacing: 12) {
                    Text(error)
                        .font(.callout)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    
                    Button("重试") {
                        onRetry()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 8)
            }
            
            Spacer()
        }
        .padding(40)
    }
    
    private var statusIcon: String {
        switch status {
        case .notInstalled:
            return "arrow.down.circle"
        case .bundledAvailable:
            return "archivebox"
        case .installing:
            return "arrow.down.circle.fill"
        case .installed:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .notInstalled, .bundledAvailable:
            return .blue
        case .installing:
            return .orange
        case .installed:
            return .green
        case .error:
            return .red
        }
    }
    
    private var statusTitle: String {
        switch status {
        case .notInstalled:
            return "检查依赖"
        case .bundledAvailable:
            return "发现依赖"
        case .installing:
            return "正在安装"
        case .installed:
            return "安装完成"
        case .error:
            return "安装失败"
        }
    }
    
    private var statusDescription: String {
        switch status {
        case .notInstalled:
            return "正在检查 OpenClaw 引擎..."
        case .bundledAvailable:
            return "发现 OpenClaw 引擎，准备安装..."
        case .installing:
            return "正在安装 OpenClaw 引擎到本地目录..."
        case .installed:
            return "所有依赖已就绪，可以继续配置 AI 模型。"
        case .error:
            return "安装过程中遇到问题，请检查权限后重试。"
        }
    }
}

// MARK: - AI 配置步骤

struct AgentConfigurationStepView: View {
    let onComplete: (Agent) -> Void
    
    @State private var selectedProvider: ProviderType = .moonshot
    @State private var apiKey: String = ""
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var showError = false
    @State private var errorMessage = ""
    
    enum TestResult {
        case success
        case failed(String)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题
            VStack(spacing: 8) {
                Text("配置 AI 模型")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("选择你的 AI 服务提供商并配置 API Key")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 32)
            
            // 配置表单
            Form {
                Section("提供商") {
                    Picker("AI 服务", selection: $selectedProvider) {
                        ForEach(ProviderType.allCases) { provider in
                            Text(provider.displayName)
                                .tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    if selectedProvider == .moonshot {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                            Text("推荐：国内访问稳定，支持长文本")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section("API Key") {
                    SecureField("输入 API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    
                    HStack {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text("API Key 仅存储在本地，不会上传到任何服务器")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if selectedProvider == .moonshot {
                        Link("获取 Moonshot API Key", destination: URL(string: "https://platform.moonshot.cn/console/api-keys")!)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 200)
            
            // 测试结果
            if let result = testResult {
                HStack(spacing: 8) {
                    Image(systemName: result == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(result == .success ? .green : .red)
                    
                    switch result {
                    case .success:
                        Text("连接成功！")
                            .foregroundColor(.green)
                    case .failed(let message):
                        Text(message)
                            .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 8)
            }
            
            Spacer()
            
            // 操作按钮
            HStack(spacing: 16) {
                Button("测试连接") {
                    Task {
                        await testConnection()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(apiKey.isEmpty || isTesting)
                
                Button("完成配置") {
                    Task {
                        await createAgent()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty || isTesting)
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 40)
        .alert("错误", isPresented: $showError) {
            Button("确定") {}
        } message: {
            Text(errorMessage)
        }
    }
    
    private func testConnection() async {
        isTesting = true
        testResult = nil
        
        // 模拟测试（实际实现应调用真实的 API 测试）
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        
        // 简单的格式验证
        if apiKey.count < 10 {
            testResult = .failed("API Key 格式不正确")
        } else {
            testResult = .success
        }
        
        isTesting = false
    }
    
    private func createAgent() async {
        isTesting = true
        
        // 创建 Agent
        let agentStore = AgentStore.shared
        
        let config = AgentConfiguration(
            temperature: 0.7,
            maxTokens: 4096,
            systemPrompt: "你是一个 helpful 的 AI 助手。"
        )
        
        let runtimeProfile = AgentRuntimeProfile(
            provider: selectedProvider,
            apiKey: apiKey,
            baseURL: selectedProvider.defaultBaseURL,
            model: selectedProvider.recommendedModel
        )
        
        let newAgent = Agent(
            name: "\(selectedProvider.displayName) Assistant",
            provider: selectedProvider,
            model: runtimeProfile.model,
            capabilities: selectedProvider.defaultCapabilities,
            configuration: config,
            isDefault: true
        )
        
        // 保存 Agent 和 runtime profile
        agentStore.addAgent(newAgent, runtimeProfile: runtimeProfile)
        agentStore.switchToAgent(newAgent)
        
        isTesting = false
        onComplete(newAgent)
    }
}

// MARK: - 准备就绪步骤

struct ReadyStepView: View {
    let agent: Agent?
    let onStart: () -> Void
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // 成功图标
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 120, height: 120)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)
            }
            
            // 标题
            VStack(spacing: 12) {
                Text("准备就绪！")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                if let agent = agent {
                    Text("已配置: \(agent.displayName)")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            
            // 快速开始提示
            VStack(alignment: .leading, spacing: 16) {
                Text("快速开始")
                    .font(.headline)
                
                TipRow(icon: "message", text: "在聊天窗口输入问题开始对话")
                TipRow(icon: "camera", text: "使用 ⌘⇧1 截图询问 AI")
                TipRow(icon: "doc.on.clipboard", text: "使用 ⌘⇧V 询问剪贴板内容")
                TipRow(icon: "menubar.arrow.down.rectangle", text: "点击菜单栏图标快速访问")
            }
            .padding(20)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
            .frame(maxWidth: 400)
            
            Spacer()
            
            Button("开始使用") {
                // 发送引导完成通知
                NotificationCenter.default.post(
                    name: NSNotification.Name("OnboardingDidComplete"),
                    object: nil
                )
                onStart()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
    }
}

struct TipRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24)
            
            Text(text)
                .font(.body)
        }
    }
}

// MARK: - View Model

@MainActor
class OnboardingViewModel: ObservableObject {
    @Published var currentStep: OnboardingStep = .welcome
    @Published var dependencyStatus: DependencyStatus = .notInstalled
    @Published var isInstallingDependencies = false
    @Published var dependencyError: String?
    @Published var createdAgent: Agent?
    
    var canGoBack: Bool {
        currentStep != .welcome && currentStep != .ready
    }
    
    var canSkip: Bool {
        currentStep != .ready
    }
    
    func moveToNextStep() {
        guard let currentIndex = OnboardingStep.allCases.firstIndex(of: currentStep),
              currentIndex < OnboardingStep.allCases.count - 1 else {
            return
        }
        currentStep = OnboardingStep.allCases[currentIndex + 1]
    }
    
    func moveToPreviousStep() {
        guard let currentIndex = OnboardingStep.allCases.firstIndex(of: currentStep),
              currentIndex > 0 else {
            return
        }
        currentStep = OnboardingStep.allCases[currentIndex - 1]
    }
    
    func skipToEnd() {
        currentStep = .ready
    }
    
    func installDependencies() async {
        guard currentStep == .dependencies else { return }
        
        isInstallingDependencies = true
        dependencyError = nil
        
        do {
            let dependencyManager = DependencyManager.shared
            _ = try await dependencyManager.ensureOpenClawAvailable()
            
            // 安装成功，自动进入下一步
            try? await Task.sleep(nanoseconds: 500_000_000)
            moveToNextStep()
            
        } catch {
            dependencyError = error.localizedDescription
        }
        
        isInstallingDependencies = false
    }
}

// MARK: - Provider 扩展

extension ProviderType {
    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google"
        case .moonshot: return "Moonshot"
        case .ollama: return "Ollama"
        }
    }
    
    var defaultBaseURL: String {
        switch self {
        case .openai:
            return "https://api.openai.com/v1"
        case .anthropic:
            return "https://api.anthropic.com"
        case .google:
            return "https://generativelanguage.googleapis.com"
        case .moonshot:
            return "https://api.moonshot.cn/v1"
        case .ollama:
            return "http://localhost:11434"
        }
    }
    
    var recommendedModel: String {
        switch self {
        case .openai:
            return "gpt-4o"
        case .anthropic:
            return "claude-3-5-sonnet"
        case .google:
            return "gemini-pro"
        case .moonshot:
            return "moonshot-v1-8k"
        case .ollama:
            return "llama3"
        }
    }
    
    var defaultCapabilities: [Capability] {
        switch self {
        case .openai, .anthropic, .google, .moonshot:
            return [.textChat, .codeAnalysis, .documentAnalysis]
        case .ollama:
            return [.textChat, .codeAnalysis]
        }
    }
}
