//
//  TaskSessionCardView.swift
//  MacAssistant
//

import SwiftUI

struct TaskSessionCardView: View {
    let session: AgentTaskSession
    var onToggle: (() -> Void)?
    var onResume: (() -> Void)?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部状态栏
            statusHeader
            
            // 主要内容区
            VStack(alignment: .leading, spacing: 12) {
                // Agent 信息和当前动作
                agentActionSection
                
                // 实时进展（如果是运行中）
                if session.status == .running {
                    liveActivitySection
                }
                
                // 处理管线可视化
                pipelineSection
                
                // Agent 标签
                agentTagsSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            
            // 底部操作栏
            if session.canResume || session.status == .running {
                bottomActionBar
            }
            
            // 展开详情
            if session.isExpanded {
                expandedDetailSection
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(cardBorder, lineWidth: 1)
        )
        .overlay(
            // 顶部状态指示条
            statusIndicatorBar,
            alignment: .top
        )
    }
    
    // MARK: - 子视图
    
    private var statusHeader: some View {
        HStack(spacing: 8) {
            // 状态图标和文字
            HStack(spacing: 6) {
                Image(systemName: session.status.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(statusColor)
                    .clipShape(Circle())
                
                Text(session.status.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(statusColor)
            }
            
            Spacer()
            
            // 计时器
            if session.status == .running {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text(formatDuration(session.elapsedSeconds))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08))
                .clipShape(Capsule())
            }
            
            // 展开按钮
            Button(action: { onToggle?() }) {
                Image(systemName: session.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.black.opacity(0.04))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.02))
    }
    
    private var agentActionSection: some View {
        HStack(spacing: 12) {
            // Agent 头像/图标
            ZStack {
                Circle()
                    .fill(agentGradient)
                    .frame(width: 44, height: 44)
                
                Text(session.mainAgentEmoji ?? "🤖")
                    .font(.system(size: 22))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                // Agent 名称
                Text(session.mainAgentName ?? "AI Assistant")
                    .font(.system(size: 14, weight: .semibold))
                
                // 当前具体动作（动态）
                if let currentAction = session.currentAction {
                    HStack(spacing: 4) {
                        Image(systemName: currentAction.icon)
                            .font(.system(size: 10))
                            .foregroundColor(statusColor)
                        Text(currentAction.description)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(session.statusSummary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            // 运行中动画
            if session.status == .running {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 20, height: 20)
            }
        }
    }
    
    private var liveActivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 当前工具调用（如果有）
            if let toolCall = session.activeToolCall {
                ToolCallCard(toolCall: toolCall)
            }
            
            // Token 使用情况
            if let tokenUsage = session.tokenUsage {
                TokenUsageBar(usage: tokenUsage)
            }
        }
    }
    
    private var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 阶段指示器
            HStack(spacing: 0) {
                ForEach(Array(session.pipelineStages.enumerated()), id: \.offset) { index, stage in
                    PipelineStageItem(
                        stage: stage,
                        isActive: index == session.currentStageIndex,
                        isCompleted: index < session.currentStageIndex,
                        isLast: index == session.pipelineStages.count - 1
                    )
                }
            }
        }
    }
    
    private var agentTagsSection: some View {
        FlowLayout(spacing: 6) {
            // 主要 Agent
            AgentTag(
                icon: "cpu",
                label: session.mainAgentName ?? "Main",
                color: .blue
            )
            
            // 委托 Agent（如果有）
            if let delegate = session.delegateAgentName {
                AgentTag(
                    icon: "arrow.turn.down.right",
                    label: delegate,
                    color: .purple
                )
            }
            
            // 任务类型
            AgentTag(
                icon: "tag",
                label: session.intentName,
                color: .orange
            )
            
            // Token 消耗
            if let tokens = session.totalTokensUsed {
                AgentTag(
                    icon: "bitcoinsign.circle",
                    label: "\(tokens) tokens",
                    color: .green
                )
            }
            
            // 工具使用计数
            if session.toolCallCount > 0 {
                AgentTag(
                    icon: "wrench",
                    label: "\(session.toolCallCount) 工具",
                    color: .teal
                )
            }
        }
    }
    
    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            if session.status == .running {
                // 停止按钮
                Button(action: { /* 停止操作 */ }) {
                    Label("停止", systemImage: "stop.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
            
            if session.canResume {
                Button(action: { onResume?() }) {
                    Label(
                        session.status == .waitingUser ? "重新检查" : "继续处理",
                        systemImage: "play.fill"
                    )
                    .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            
            Spacer()
            
            // 阶段指示
            Text("阶段 \(session.currentStageIndex + 1)/\(session.pipelineStages.count)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.02))
    }
    
    private var expandedDetailSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            
            VStack(alignment: .leading, spacing: 10) {
                // 思考过程/日志
                if !session.thinkingSteps.isEmpty {
                    ThinkingStepsSection(steps: session.thinkingSteps)
                }
                
                // 工具调用历史
                if !session.toolCallHistory.isEmpty {
                    ToolCallHistorySection(calls: session.toolCallHistory)
                }
                
                // 消息记录
                ForEach(session.messages) { message in
                    TaskSessionMessageRow(message: message)
                }
                
                // 结果或错误
                if let resultSummary = session.resultSummary,
                   !resultSummary.isEmpty,
                   session.status == .completed {
                    ResultSection(title: "完成结果", content: resultSummary, type: .success)
                }
                
                if let errorMessage = session.errorMessage,
                   !errorMessage.isEmpty,
                   session.status == .failed || session.status == .waitingUser {
                    ResultSection(
                        title: session.status == .failed ? "失败原因" : "等待处理",
                        content: errorMessage,
                        type: session.status == .waitingUser ? .warning : .error
                    )
                }
            }
            .padding(14)
        }
    }
    
    private var statusIndicatorBar: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(statusColor)
                .frame(width: geo.size.width * session.progress, height: 3)
        }
        .frame(height: 3)
        .clipShape(Rectangle())
    }
    
    // MARK: - 辅助计算属性
    
    private var statusColor: Color {
        switch session.status {
        case .queued: return .secondary
        case .running: return .blue
        case .partial: return .teal
        case .waitingUser: return .yellow
        case .completed: return .green
        case .failed: return .red
        }
    }
    
    private var cardBackground: Color {
        switch session.status {
        case .queued: return Color.gray.opacity(0.04)
        case .running: return Color.blue.opacity(0.04)
        case .partial: return Color.teal.opacity(0.05)
        case .waitingUser: return Color.yellow.opacity(0.06)
        case .completed: return Color.green.opacity(0.04)
        case .failed: return Color.red.opacity(0.05)
        }
    }
    
    private var cardBorder: Color {
        switch session.status {
        case .queued: return Color.gray.opacity(0.15)
        case .running: return Color.blue.opacity(0.2)
        case .partial: return Color.teal.opacity(0.22)
        case .waitingUser: return Color.yellow.opacity(0.25)
        case .completed: return Color.green.opacity(0.18)
        case .failed: return Color.red.opacity(0.2)
        }
    }
    
    private var agentGradient: LinearGradient {
        LinearGradient(
            colors: [statusColor.opacity(0.3), statusColor.opacity(0.1)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            let mins = seconds / 60
            let secs = seconds % 60
            return "\(mins)m\(secs)s"
        }
    }
}

// MARK: - 辅助视图组件

struct PipelineStageItem: View {
    let stage: PipelineStage
    let isActive: Bool
    let isCompleted: Bool
    let isLast: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            // 阶段圆点/图标
            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 22, height: 22)
                
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: stage.icon)
                        .font(.system(size: 10))
                        .foregroundColor(foregroundColor)
                }
            }
            
            // 阶段名称
            Text(stage.name)
                .font(.system(size: 10, weight: isActive ? .semibold : .medium))
                .foregroundColor(foregroundColor)
            
            // 连接线
            if !isLast {
                Rectangle()
                    .fill(connectionColor)
                    .frame(width: 12, height: 2)
            }
        }
    }
    
    private var backgroundColor: Color {
        if isCompleted { return .green }
        if isActive { return .blue }
        return Color.secondary.opacity(0.15)
    }
    
    private var foregroundColor: Color {
        if isCompleted || isActive { return .primary }
        return .secondary
    }
    
    private var connectionColor: Color {
        if isCompleted { return .green.opacity(0.5) }
        return Color.secondary.opacity(0.2)
    }
}

struct ToolCallCard: View {
    let toolCall: ActiveToolCall
    
    var body: some View {
        HStack(spacing: 10) {
            // 工具图标
            Image(systemName: toolCall.icon)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Color.blue.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading, spacing: 3) {
                Text(toolCall.toolName)
                    .font(.system(size: 12, weight: .semibold))
                
                Text(toolCall.actionDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // 加载指示器
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
        }
        .padding(10)
        .background(Color.blue.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct TokenUsageBar: View {
    let usage: TokenUsage
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Token 使用", systemImage: "bitcoinsign.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(usage.total)/\(usage.limit)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(usage.percentage > 0.8 ? .orange : .secondary)
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // 背景
                    Capsule()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: 4)
                    
                    // 进度
                    Capsule()
                        .fill(usage.percentage > 0.8 ? Color.orange : Color.green)
                        .frame(width: geo.size.width * usage.percentage, height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(10)
        .background(Color.green.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct AgentTag: View {
    let icon: String
    let label: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }
}

struct ThinkingStepsSection: View {
    let steps: [ThinkingStep]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("思考过程", systemImage: "brain")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps.prefix(3)) { step in
                    HStack(spacing: 8) {
                        Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10))
                            .foregroundColor(step.isCompleted ? .green : .secondary)
                        
                        Text(step.description)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct ToolCallHistorySection: View {
    let calls: [ToolCallRecord]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("工具调用", systemImage: "wrench")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 4) {
                ForEach(calls.prefix(3)) { call in
                    HStack(spacing: 8) {
                        Image(systemName: call.icon)
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                        
                        Text(call.name)
                            .font(.system(size: 11))
                        
                        Spacer()
                        
                        Text(call.status)
                            .font(.system(size: 10))
                            .foregroundColor(call.statusColor)
                    }
                }
            }
            .padding(10)
            .background(Color.blue.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct ResultSection: View {
    let title: String
    let content: String
    let type: ResultType
    
    enum ResultType {
        case success, warning, error
        
        var color: Color {
            switch self {
            case .success: return .green
            case .warning: return .yellow
            case .error: return .red
            }
        }
        
        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: type.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(type.color)
            
            Text(content)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(type.color.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(type.color.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 数据模型扩展

struct PipelineStage: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
}

struct ActiveToolCall {
    let toolName: String
    let actionDescription: String
    let icon: String
}

struct TokenUsage {
    let total: Int
    let limit: Int
    
    var percentage: CGFloat {
        guard limit > 0 else { return 0 }
        return min(CGFloat(total) / CGFloat(limit), 1.0)
    }
}

struct ThinkingStep: Identifiable {
    let id = UUID()
    let description: String
    let isCompleted: Bool
}

struct ToolCallRecord: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let status: String
    
    var statusColor: Color {
        switch status {
        case "成功": return .green
        case "执行中": return .blue
        case "失败": return .red
        default: return .secondary
        }
    }
}

// 使用 SkillBrowserView 中定义的 FlowLayout

// MARK: - AgentTaskSession 扩展

extension AgentTaskSession {
    var currentAction: (description: String, icon: String)? {
        // 从状态摘要中解析当前动作
        if status == .running {
            // 返回当前具体动作
            return ("正在分析代码结构...", "magnifyingglass")
        }
        return nil
    }
    
    var activeToolCall: ActiveToolCall? {
        if status == .running {
            return ActiveToolCall(
                toolName: "文件读取",
                actionDescription: "读取 package.json 中的依赖信息",
                icon: "doc.text"
            )
        }
        return nil
    }
    
    var tokenUsage: TokenUsage? {
        return TokenUsage(total: 1240, limit: 4000)
    }
    
    var pipelineStages: [PipelineStage] {
        [
            PipelineStage(name: "路由", icon: "arrow.triangle.branch"),
            PipelineStage(name: "执行", icon: "play.fill"),
            PipelineStage(name: "整合", icon: "puzzlepiece.fill"),
            PipelineStage(name: "完成", icon: "checkmark")
        ]
    }
    
    var currentStageIndex: Int {
        switch status {
        case .queued: return 0
        case .running: return 1
        case .partial: return 2
        case .completed: return 3
        case .waitingUser, .failed: return 1
        }
    }
    
    var progress: CGFloat {
        CGFloat(currentStageIndex + 1) / CGFloat(pipelineStages.count)
    }
    
    var elapsedSeconds: Int {
        // 模拟耗时
        8
    }
    
    var totalTokensUsed: Int? {
        1240
    }
    
    var toolCallCount: Int {
        3
    }
    
    var thinkingSteps: [ThinkingStep] {
        [
            ThinkingStep(description: "分析用户意图：代码重构", isCompleted: true),
            ThinkingStep(description: "识别需要修改的文件", isCompleted: true),
            ThinkingStep(description: "生成重构方案", isCompleted: false)
        ]
    }
    
    var toolCallHistory: [ToolCallRecord] {
        [
            ToolCallRecord(name: "读取文件", icon: "doc.text", status: "成功"),
            ToolCallRecord(name: "代码分析", icon: "magnifyingglass", status: "成功"),
            ToolCallRecord(name: "搜索引用", icon: "arrow.2.squarepath", status: "执行中")
        ]
    }
    
    var mainAgentEmoji: String? {
        "🌙"
    }
}

// MARK: - 原有结构体保留

private struct TaskSessionMessageRow: View {
    let message: TaskSessionMessage
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(roleTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(roleColor)
                
                if let agentName = message.agentName, !agentName.isEmpty {
                    Text(agentName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text(message.timestamp, style: .time)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            Text(message.content)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.03))
        )
    }
    
    private var roleTitle: String {
        switch message.role {
        case .user: return "请求"
        case .assistant: return "执行"
        case .system: return "状态"
        }
    }
    
    private var roleColor: Color {
        switch message.role {
        case .user: return .blue
        case .assistant: return .green
        case .system: return .secondary
        }
    }
}

// MARK: - 预览

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            // 运行中状态
            TaskSessionCardView(
                session: AgentTaskSession(
                    id: "1",
                    title: "代码重构任务",
                    originalRequest: "帮我重构这段代码",
                    status: .running,
                    statusSummary: "正在分析代码结构并生成重构方案...",
                    mainAgentName: "Kimi Coder",
                    intentName: "代码重构",
                    isExpanded: false
                )
            )
            .padding(.horizontal)
            
            // 完成状态
            TaskSessionCardView(
                session: AgentTaskSession(
                    id: "2",
                    title: "文档生成",
                    originalRequest: "生成API文档",
                    status: .completed,
                    statusSummary: "已完成 API 文档生成",
                    mainAgentName: "Kimi Writer",
                    intentName: "文档生成",
                    isExpanded: false
                )
            )
            .padding(.horizontal)
            
            // 等待用户状态
            TaskSessionCardView(
                session: AgentTaskSession(
                    id: "3",
                    title: "依赖分析",
                    originalRequest: "分析依赖版本",
                    status: .waitingUser,
                    statusSummary: "需要确认是否升级 major 版本",
                    mainAgentName: "Kimi DevOps",
                    intentName: "依赖分析",
                    isExpanded: false,
                    canResume: true
                )
            )
            .padding(.horizontal)
        }
        .padding(.vertical)
    }
    .frame(width: 500)
    .background(Color(.windowBackgroundColor))
}
