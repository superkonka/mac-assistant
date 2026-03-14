//
//  SubtaskCreationView.swift
//  MacAssistant
//
//  子任务创建界面 - 与Planner对话确定子任务内容
//

import SwiftUI

struct SubtaskCreationView: View {
    let onCreate: (String, String) -> Void
    let onCancel: () -> Void
    
    @State private var description: String = ""
    @State private var requirements: String = ""
    @State private var currentStep: CreationStep = .describe
    @State private var isPlanning: Bool = false
    @State private var plannerSuggestion: String? = nil
    
    enum CreationStep {
        case describe      // 描述需求
        case planning      // Planner分析中
        case review        // 确认计划
        case requirements  // 补充要求
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 头部
            header
            
            Divider()
            
            // 步骤指示器
            stepIndicator
                .padding(.vertical, 12)
            
            Divider()
            
            // 内容区
            ScrollView {
                VStack(spacing: 20) {
                    switch currentStep {
                    case .describe:
                        describeStep
                    case .planning:
                        planningStep
                    case .review:
                        reviewStep
                    case .requirements:
                        requirementsStep
                    }
                }
                .padding(24)
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
                Text("新建子任务")
                    .font(.system(size: 16, weight: .semibold))
                
                Text("通过 Planner 协助规划子任务")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: onCancel) {
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
            StepDot(number: 1, title: "描述", isActive: currentStep == .describe, isCompleted: currentStep.rawValue > CreationStep.describe.rawValue)
            
            StepConnector(isCompleted: currentStep.rawValue > CreationStep.describe.rawValue)
            
            StepDot(number: 2, title: "规划", isActive: currentStep == .planning || currentStep == .review, isCompleted: currentStep.rawValue > CreationStep.review.rawValue)
            
            StepConnector(isCompleted: currentStep.rawValue > CreationStep.review.rawValue)
            
            StepDot(number: 3, title: "确认", isActive: currentStep == .requirements, isCompleted: false)
        }
        .padding(.horizontal, 40)
    }
    
    private var describeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("你想让子任务做什么？")
                .font(.system(size: 14, weight: .medium))
            
            Text("描述你的需求，Planner 会帮你拆解成可执行的子任务。")
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextEditor(text: $description)
                .font(.system(size: 13))
                .frame(height: 120)
                .padding(8)
                .background(Color.black.opacity(0.03))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
            
            // 快捷示例
            VStack(alignment: .leading, spacing: 8) {
                Text("快捷示例：")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                FlowLayout(spacing: 8) {
                    ExampleChip(text: "研究这个链接的内容") {
                        description = "研究这个链接的内容，提取关键信息"
                    }
                    ExampleChip(text: "搜索相关文档") {
                        description = "搜索关于 SwiftUI 动画最佳实践的相关文档"
                    }
                    ExampleChip(text: "分析代码问题") {
                        description = "分析这段代码的性能问题并给出优化建议"
                    }
                }
            }
        }
    }
    
    private var planningStep: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.2)
            
            Text("Planner 正在分析...")
                .font(.system(size: 14, weight: .medium))
            
            Text("正在根据你的描述规划最佳执行方案")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
    
    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Planner 建议的执行方案：")
                .font(.system(size: 14, weight: .medium))
            
            if let suggestion = plannerSuggestion {
                Text(suggestion)
                    .font(.system(size: 13))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
            }
            
            Text("你可以直接确认，或补充具体要求。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var requirementsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("补充要求（可选）")
                .font(.system(size: 14, weight: .medium))
            
            Text("对执行的具体要求，如输出格式、重点关注等")
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextEditor(text: $requirements)
                .font(.system(size: 13))
                .frame(height: 100)
                .padding(8)
                .background(Color.black.opacity(0.03))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
            
            // 快捷要求
            FlowLayout(spacing: 8) {
                ExampleChip(text: "用中文回复") { requirements += "用中文回复\n" }
                ExampleChip(text: "列出关键点") { requirements += "列出关键要点\n" }
                ExampleChip(text: "提供代码示例") { requirements += "提供代码示例\n" }
                ExampleChip(text: "详细分析") { requirements += "提供详细分析\n" }
            }
        }
    }
    
    private var footer: some View {
        HStack {
            if currentStep != .describe {
                Button("上一步") {
                    goBack()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            
            Spacer()
            
            Button(action: handlePrimaryAction) {
                Text(primaryButtonTitle)
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canProceed)
        }
    }
    
    // MARK: - 辅助计算属性
    
    private var primaryButtonTitle: String {
        switch currentStep {
        case .describe:
            return "开始规划"
        case .planning:
            return "规划中..."
        case .review:
            return "确认方案"
        case .requirements:
            return "创建子任务"
        }
    }
    
    private var canProceed: Bool {
        switch currentStep {
        case .describe:
            return !description.isEmpty
        case .planning:
            return false
        case .review:
            return true
        case .requirements:
            return true
        }
    }
    
    // MARK: - 方法
    
    private func handlePrimaryAction() {
        switch currentStep {
        case .describe:
            startPlanning()
        case .review:
            currentStep = .requirements
        case .requirements:
            onCreate(description, requirements)
        default:
            break
        }
    }
    
    private func goBack() {
        switch currentStep {
        case .planning, .review:
            currentStep = .describe
        case .requirements:
            currentStep = .review
        default:
            break
        }
    }
    
    private func startPlanning() {
        currentStep = .planning
        isPlanning = true
        
        // 模拟Planner分析（实际应调用Planner服务）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            plannerSuggestion = generatePlannerSuggestion()
            isPlanning = false
            currentStep = .review
        }
    }
    
    private func generatePlannerSuggestion() -> String {
        // 这里应该是实际的Planner调用
        return """
        建议将「\(description)」作为一个独立子任务执行：
        
        1. 使用子任务Agent进行独立处理
        2. 执行结果将异步返回
        3. 不影响当前主会话的对话流程
        """
    }
}

// MARK: - 辅助组件

private struct StepDot: View {
    let number: Int
    let title: String
    let isActive: Bool
    let isCompleted: Bool
    
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 24, height: 24)
                
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(foregroundColor)
                }
            }
            
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(isActive || isCompleted ? .primary : .secondary)
        }
    }
    
    private var backgroundColor: Color {
        if isCompleted {
            return .green
        } else if isActive {
            return .blue
        } else {
            return Color.gray.opacity(0.2)
        }
    }
    
    private var foregroundColor: Color {
        isActive ? .white : .secondary
    }
}

private struct StepConnector: View {
    let isCompleted: Bool
    
    var body: some View {
        Rectangle()
            .fill(isCompleted ? Color.green : Color.gray.opacity(0.3))
            .frame(height: 2)
            .padding(.horizontal, 4)
    }
}

private struct ExampleChip: View {
    let text: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(4)
        }
        .buttonStyle(PlainButtonStyle())
    }
}



// MARK: - 步骤扩展

private extension SubtaskCreationView.CreationStep {
    var rawValue: Int {
        switch self {
        case .describe: return 0
        case .planning: return 1
        case .review: return 2
        case .requirements: return 3
        }
    }
}
