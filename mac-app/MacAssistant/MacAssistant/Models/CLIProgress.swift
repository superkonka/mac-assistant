//
//  CLIProgress.swift
//  CLI 执行进度和原始输出
//

import Foundation

enum CLIStepType: String, CaseIterable {
    case thinking = "思考"
    case toolCall = "工具"
    case toolResult = "结果"
    case reasoning = "推理"
    case action = "执行"
    case complete = "完成"
    case error = "错误"
    
    var icon: String {
        switch self {
        case .thinking: return "🤔"
        case .toolCall: return "🔧"
        case .toolResult: return "📋"
        case .reasoning: return "🧠"
        case .action: return "⚡️"
        case .complete: return "✅"
        case .error: return "❌"
        }
    }
    
    var color: String {
        switch self {
        case .thinking: return "FFB800"
        case .toolCall: return "007AFF"
        case .toolResult: return "34C759"
        case .reasoning: return "AF52DE"
        case .action: return "FF9500"
        case .complete: return "34C759"
        case .error: return "FF3B30"
        }
    }
}

struct CLIStep: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let type: CLIStepType
    let title: String
    let detail: String?
    
    static func == (lhs: CLIStep, rhs: CLIStep) -> Bool {
        lhs.id == rhs.id
    }
}

class CLIProgressManager: ObservableObject {
    static let shared = CLIProgressManager()
    
    @Published var steps: [CLIStep] = []
    @Published var isActive: Bool = false
    @Published var rawOutput: String = ""
    
    private let maxSteps = 20
    private let maxOutputLength = 10000
    
    private init() {}
    
    func startTask() {
        DispatchQueue.main.async {
            self.steps.removeAll()
            self.rawOutput = ""
            self.isActive = true
        }
    }
    
    func addStep(type: CLIStepType, title: String, detail: String? = nil) {
        DispatchQueue.main.async {
            let step = CLIStep(
                timestamp: Date(),
                type: type,
                title: title,
                detail: detail
            )
            self.steps.append(step)
            if self.steps.count > self.maxSteps {
                self.steps.removeFirst(self.steps.count - self.maxSteps)
            }
        }
    }
    
    func appendRawOutput(_ text: String) {
        DispatchQueue.main.async {
            self.rawOutput += text
            // 限制长度
            if self.rawOutput.count > self.maxOutputLength {
                let startIndex = self.rawOutput.index(self.rawOutput.endIndex, offsetBy: -self.maxOutputLength)
                self.rawOutput = String(self.rawOutput[startIndex...])
            }
        }
    }
    
    func updateLastStepDetail(_ detail: String) {
        DispatchQueue.main.async {
            guard !self.steps.isEmpty else { return }
            let lastIndex = self.steps.count - 1
            let lastStep = self.steps[lastIndex]
            self.steps[lastIndex] = CLIStep(
                timestamp: lastStep.timestamp,
                type: lastStep.type,
                title: lastStep.title,
                detail: detail
            )
        }
    }
    
    func completeTask(success: Bool = true) {
        DispatchQueue.main.async {
            self.isActive = false
        }
    }
    
    func clear() {
        DispatchQueue.main.async {
            self.steps.removeAll()
            self.rawOutput = ""
            self.isActive = false
        }
    }
}
