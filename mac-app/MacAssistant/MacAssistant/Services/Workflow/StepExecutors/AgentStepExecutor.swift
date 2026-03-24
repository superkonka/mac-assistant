//
//  AgentStepExecutor.swift
//  MacAssistant
//
//  Agent 调用步骤执行器
//

import Foundation

@MainActor
final class AgentStepExecutor: StepExecutor {
    static let shared = AgentStepExecutor()
    
    let supportedKinds: [WorkflowStepKind] = [.action]
    let supportedBindingKinds: [WorkflowBindingKind] = [.agent]
    
    private let orchestrator = AgentOrchestrator.shared
    private var activeRuns: Set<String> = []
    
    private init() {}
    
    func isAvailable() async -> Bool {
        return orchestrator.currentAgent != nil
    }
    
    func cancel(runID: String) {
        activeRuns.remove(runID)
        LogInfo("[AgentStepExecutor] 取消执行: \(runID)")
    }
    
    func execute(_ step: WorkflowStepDef, context: WorkflowContext) async -> StepExecutionResult {
        guard !activeRuns.contains(context.runID) else {
            return .failure(error: .cancelled)
        }
        
        activeRuns.insert(context.runID)
        defer { activeRuns.remove(context.runID) }
        
        LogInfo("[AgentStepExecutor] 执行步骤: \(step.name), Run: \(context.runID)")
        
        // 构建提示
        let prompt = buildAgentPrompt(step: step, context: context)
        
        do {
            // 调用 Agent
            let result = try await callAgent(prompt: prompt)
            return .success(output: ["response": result])
        } catch {
            return .failure(error: StepExecutionError(
                code: "AGENT_CALL_FAILED",
                message: error.localizedDescription,
                isRetryable: true
            ))
        }
    }
    
    private func buildAgentPrompt(step: WorkflowStepDef, context: WorkflowContext) -> String {
        var components: [String] = []
        
        components.append("任务: \(step.name)")

        if let targetAgent = context.binding?.targetID {
            components.append("目标 Agent: \(targetAgent)")
        }
        
        if !step.description.isEmpty {
            components.append("描述: \(step.description)")
        }
        
        if !context.variables.isEmpty {
            components.append("上下文:")
            for (key, value) in context.variables {
                components.append("  - \(key): \(value)")
            }
        }
        
        return components.joined(separator: "\n")
    }
    
    private func callAgent(prompt: String) async throws -> String {
        LogInfo("[AgentStepExecutor] 调用 Agent: \(prompt.prefix(100))...")
        
        // 这里应该调用 AgentOrchestrator 发送消息给 Agent
        // 简化实现，返回模拟结果
        
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        return "Agent 处理完成: \(prompt.prefix(50))..."
    }
}
