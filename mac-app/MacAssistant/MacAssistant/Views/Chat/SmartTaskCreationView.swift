//
//  SmartTaskCreationView.swift
//  MacAssistant
//
//  智能任务创建对话界面 - 由Planner Agent驱动的任务创建流程
//

import SwiftUI

/// 智能任务创建状态
enum TaskCreationState {
    case input           // 等待用户输入
    case analyzing       // Planner分析中
    case deciding        // 秘书决策中
    case confirming      // 等待用户确认
    case completed       // 完成
}

/// 任务创建决策结果
struct TaskCreationDecision {
    let action: TaskCreationAction
    let targetTask: TaskItem?       // 如果是沿用或追加，指向哪个任务
    let suggestedTitle: String      // 建议的任务标题
    let suggestedDescription: String // 建议的任务描述
    let reasoning: String           // 决策理由
    let confidence: Double          // 置信度
}

enum TaskCreationAction {
    case createNew          // 创建新任务
    case useExisting        // 沿用已有任务
    case appendToExisting   // 追加到已有任务
}

@MainActor
final class SmartTaskCreationViewModel: ObservableObject {
    static let shared = SmartTaskCreationViewModel()
    
    @Published var state: TaskCreationState = .input
    @Published var messages: [TaskCreationMessage] = []
    @Published var inputText: String = ""
    @Published var isProcessing: Bool = false
    @Published var currentDecision: TaskCreationDecision?
    
    private let taskManager = TaskManager.shared
    private let planner = TaskCreationPlanner.shared
    
    private init() {
        // 添加欢迎消息
        addSecretaryMessage("""
        你好！我是你的任务创建助手 🤖
        
        请告诉我你想要做什么，我会帮你：
        • 分析你的需求
        • 检查是否有相关的已有任务
        • 决定是创建新任务、沿用或追加到现有任务
        
        比如："帮我清理磁盘空间"、"继续之前的代码分析"、"我需要分析项目性能"
        """)
    }
    
    func reset() {
        state = .input
        messages = []
        inputText = ""
        isProcessing = false
        currentDecision = nil
        
        addSecretaryMessage("""
        你好！我是你的任务创建助手 🤖
        
        请告诉我你想要做什么？
        """)
    }
    
    func sendUserInput() {
        guard !inputText.isEmpty else { return }
        
        let content = inputText
        inputText = ""
        
        addUserMessage(content)
        
        Task {
            await analyzeAndDecide(userInput: content)
        }
    }
    
    private func analyzeAndDecide(userInput: String) async {
        state = .analyzing
        isProcessing = true
        
        addPlannerMessage("正在分析你的需求...")
        
        // 调用Planner进行决策
        let decision = await planner.decideTaskCreation(for: userInput)
        
        await MainActor.run {
            self.currentDecision = decision
            self.state = .deciding
            self.isProcessing = false
            
            // 移除分析中的消息
            self.messages.removeAll { $0.content == "正在分析你的需求..." }
            
            // 添加秘书的决策结果消息
            let secretaryMessage = formatDecisionMessage(decision)
            addSecretaryMessage(secretaryMessage)
            
            if decision.action == .createNew {
                // 自动创建新任务
                createNewTask(from: decision)
            } else {
                // 需要用户确认
                state = .confirming
            }
        }
    }
    
    private func formatDecisionMessage(_ decision: TaskCreationDecision) -> String {
        var message = "📋 **分析结果**\n\n"
        
        switch decision.action {
        case .createNew:
            message += "💡 **决策**：创建新任务\n\n"
            message += "📝 **建议标题**：\(decision.suggestedTitle)\n"
            message += "📄 **描述**：\(decision.suggestedDescription)\n\n"
            message += "✅ 已为你创建新任务，点击确认开始执行。"
            
        case .useExisting:
            if let existing = decision.targetTask {
                message += "💡 **决策**：沿用已有任务\n\n"
                message += "📝 **匹配任务**：\(existing.title)\n"
                message += "📄 **状态**：\(existing.status.displayName)\n\n"
                message += "🤔 **理由**：\(decision.reasoning)\n\n"
                message += "❓ 是否跳转到该任务？"
            }
            
        case .appendToExisting:
            if let existing = decision.targetTask {
                message += "💡 **决策**：追加到现有任务\n\n"
                message += "📝 **目标任务**：\(existing.title)\n"
                message += "📄 **当前状态**：\(existing.status.displayName)\n\n"
                message += "🤔 **理由**：\(decision.reasoning)\n\n"
                message += "❓ 是否追加到该任务并继续对话？"
            }
        }
        
        return message
    }
    
    private func createNewTask(from decision: TaskCreationDecision) {
        let newTask = TaskItem(
            title: decision.suggestedTitle,
            description: decision.suggestedDescription,
            status: .pending,
            strategy: .custom,
            inputContext: messages.first { $0.role == .user }?.content ?? "",
            messages: [
                TaskMessage(
                    id: UUID(),
                    role: .system,
                    content: "任务通过智能创建流程创建。决策理由：\(decision.reasoning)",
                    timestamp: Date(),
                    agentID: nil,
                    agentName: "任务秘书"
                )
            ]
        )
        
        taskManager.addTask(newTask)
        
        // 添加系统确认消息
        addSystemMessage("✅ 已创建新任务：\(decision.suggestedTitle)")
        state = .completed
        
        // 通知外部任务已创建
        NotificationCenter.default.post(
            name: NSNotification.Name("SmartTaskCreated"),
            object: newTask.id
        )
    }
    
    func confirmUseExisting() {
        guard let decision = currentDecision, let targetTask = decision.targetTask else { return }
        
        addSystemMessage("✅ 已跳转到现有任务：\(targetTask.title)")
        state = .completed
        
        NotificationCenter.default.post(
            name: NSNotification.Name("SmartTaskUseExisting"),
            object: targetTask.id
        )
    }
    
    func confirmAppendToExisting() {
        guard let decision = currentDecision, let targetTask = decision.targetTask else { return }
        
        // 将当前对话追加为任务消息
        if let userInput = messages.first(where: { $0.role == .user })?.content {
            taskManager.addUserMessage(to: targetTask.id, content: userInput)
        }
        
        addSystemMessage("✅ 已追加到任务：\(targetTask.title)")
        state = .completed
        
        NotificationCenter.default.post(
            name: NSNotification.Name("SmartTaskAppendToExisting"),
            object: targetTask.id
        )
    }
    
    func createNewTaskInstead() {
        guard let decision = currentDecision else { return }
        
        // 强制创建新任务
        var newDecision = decision
        newDecision = TaskCreationDecision(
            action: .createNew,
            targetTask: nil,
            suggestedTitle: decision.suggestedTitle,
            suggestedDescription: decision.suggestedDescription,
            reasoning: "用户选择创建新任务：\(decision.reasoning)",
            confidence: decision.confidence
        )
        
        createNewTask(from: newDecision)
    }
    
    // MARK: - 消息管理
    
    private func addUserMessage(_ content: String) {
        let message = TaskCreationMessage(
            id: UUID(),
            role: .user,
            content: content,
            timestamp: Date()
        )
        messages.append(message)
    }
    
    private func addSecretaryMessage(_ content: String) {
        let message = TaskCreationMessage(
            id: UUID(),
            role: .secretary,
            content: content,
            timestamp: Date()
        )
        messages.append(message)
    }
    
    private func addPlannerMessage(_ content: String) {
        let message = TaskCreationMessage(
            id: UUID(),
            role: .planner,
            content: content,
            timestamp: Date()
        )
        messages.append(message)
    }
    
    private func addSystemMessage(_ content: String) {
        let message = TaskCreationMessage(
            id: UUID(),
            role: .system,
            content: content,
            timestamp: Date()
        )
        messages.append(message)
    }
}

/// 任务创建消息
struct TaskCreationMessage: Identifiable {
    let id: UUID
    let role: TaskCreationRole
    let content: String
    let timestamp: Date
}

enum TaskCreationRole {
    case user
    case secretary    // 秘书角色 - 呈现决策结果
    case planner      // Planner角色 - 分析中
    case system
}

// MARK: - 视图

struct SmartTaskCreationView: View {
    @StateObject private var viewModel = SmartTaskCreationViewModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showCreatedTask: TaskItem?
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            headerView
            
            Divider()
            
            // 消息列表
            messageList
            
            Divider()
            
            // 输入区域或确认按钮
            if viewModel.state == .confirming {
                confirmationButtons
            } else {
                inputArea
            }
        }
        .frame(width: 500, height: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SmartTaskCreated"))) { notification in
            if let taskID = notification.object as? String,
               let task = TaskManager.shared.getTask(taskID) {
                showCreatedTask = task
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SmartTaskUseExisting"))) { notification in
            if let taskID = notification.object as? String,
               let task = TaskManager.shared.getTask(taskID) {
                dismiss()
                // 打开现有任务
                TaskManager.shared.selectedTask = task
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SmartTaskAppendToExisting"))) { notification in
            if let taskID = notification.object as? String,
               let task = TaskManager.shared.getTask(taskID) {
                dismiss()
                // 打开追加后的任务
                TaskManager.shared.selectedTask = task
            }
        }
        .sheet(item: $showCreatedTask) { task in
            TaskAgentChatView(task: task)
        }
    }
    
    private var headerView: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            VStack(spacing: 2) {
                Text("创建新任务")
                    .font(.system(size: 14, weight: .semibold))
                
                Text("由 Planner Agent 驱动")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: { viewModel.reset() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("重新开始")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.05))
    }
    
    private var messageList: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.messages) { message in
                        TaskCreationMessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .onChange(of: viewModel.messages.count) { _ in
                    if let last = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
    
    private var inputArea: some View {
        HStack(spacing: 12) {
            TextField("描述你想要做什么...", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(viewModel.isProcessing || viewModel.state == .completed)
            
            Button(action: { viewModel.sendUserInput() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(canSend ? .blue : .secondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.05))
    }
    
    private var confirmationButtons: some View {
        VStack(spacing: 12) {
            if let decision = viewModel.currentDecision {
                switch decision.action {
                case .useExisting:
                    HStack(spacing: 12) {
                        Button("跳转至该任务") {
                            viewModel.confirmUseExisting()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        
                        Button("创建新任务") {
                            viewModel.createNewTaskInstead()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                    
                case .appendToExisting:
                    HStack(spacing: 12) {
                        Button("追加并继续") {
                            viewModel.confirmAppendToExisting()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        
                        Button("创建新任务") {
                            viewModel.createNewTaskInstead()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                    
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.05))
    }
    
    private var canSend: Bool {
        !viewModel.isProcessing && 
        !viewModel.inputText.isEmpty && 
        viewModel.state != .completed
    }
}

// MARK: - 消息气泡

struct TaskCreationMessageBubble: View {
    let message: TaskCreationMessage
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // 角色标签
                Text(roleLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(roleColor)
                
                // 消息内容 - 支持Markdown
                Text(message.content)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(backgroundColor)
                    .foregroundColor(foregroundColor)
                    .cornerRadius(12)
                    .textSelection(.enabled)
                
                // 时间
                Text(formatTime(message.timestamp))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            
            if message.role != .user {
                Spacer()
            }
        }
    }
    
    private var roleLabel: String {
        switch message.role {
        case .user: return "你"
        case .secretary: return "任务秘书"
        case .planner: return "Planner Agent"
        case .system: return "系统"
        }
    }
    
    private var roleColor: Color {
        switch message.role {
        case .user: return .blue
        case .secretary: return .purple
        case .planner: return .orange
        case .system: return .green
        }
    }
    
    private var backgroundColor: Color {
        switch message.role {
        case .user: return .blue.opacity(0.15)
        case .secretary: return .purple.opacity(0.12)
        case .planner: return .orange.opacity(0.12)
        case .system: return .green.opacity(0.12)
        }
    }
    
    private var foregroundColor: Color {
        .primary
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

#Preview {
    SmartTaskCreationView()
}
