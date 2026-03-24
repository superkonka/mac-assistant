//
//  ServiceStepExecutor.swift
//  MacAssistant
//
//  MCP Service 步骤执行器
//

import Foundation

@MainActor
final class ServiceStepExecutor: StepExecutor {
    static let shared = ServiceStepExecutor()
    
    let supportedKinds: [WorkflowStepKind] = [.action]
    let supportedBindingKinds: [WorkflowBindingKind] = [.service]
    
    private var activeRuns: Set<String> = []
    
    private init() {}
    
    func isAvailable() async -> Bool {
        // 检查是否有可用的 MCP 服务
        return !ServiceManager.shared.services.isEmpty
    }
    
    func cancel(runID: String) {
        activeRuns.remove(runID)
        LogInfo("[ServiceStepExecutor] 取消执行: \(runID)")
    }
    
    func execute(_ step: WorkflowStepDef, context: WorkflowContext) async -> StepExecutionResult {
        guard !activeRuns.contains(context.runID) else {
            return .failure(error: .cancelled)
        }
        
        activeRuns.insert(context.runID)
        defer { activeRuns.remove(context.runID) }
        
        LogInfo("[ServiceStepExecutor] 执行步骤: \(step.name), Run: \(context.runID)")
        
        guard let serviceID = context.binding?.targetID ?? step.bindingID else {
            return .failure(error: StepExecutionError(
                code: "NO_BINDING",
                message: "步骤没有绑定 Service",
                isRetryable: false
            ))
        }
        
        // 获取服务（简化实现，实际应该从 ServiceManager 获取）
        let service = ServiceMetadata(id: serviceID, name: serviceID, description: "", capabilities: [])
        // TODO: 从 ServiceManager 获取实际的服务
        
        // 构建输入
        let input = buildServiceInput(step: step, context: context)
        
        do {
            // 调用服务
            let result = try await callService(service, input: input)
            return .success(output: result)
        } catch {
            return .failure(error: StepExecutionError(
                code: "SERVICE_CALL_FAILED",
                message: error.localizedDescription,
                isRetryable: true
            ))
        }
    }
    
    private func buildServiceInput(step: WorkflowStepDef, context: WorkflowContext) -> [String: Any] {
        var input: [String: Any] = [:]
        
        // 添加上下文变量
        for (key, value) in context.variables {
            input[key] = value
        }
        
        // 添加步骤参数
        input["stepName"] = step.name
        input["stepDescription"] = step.description
        
        return input
    }
    
    private func callService(_ service: ServiceMetadata, input: [String: Any]) async throws -> [String: String] {
        LogInfo("[ServiceStepExecutor] 调用 Service: \(service.name)")
        
        // 这里应该调用实际的 MCP 服务
        // 简化实现，返回模拟结果
        
        // 模拟异步调用
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        return [
            "service": service.name,
            "status": "completed",
            "result": "Service \(service.name) 执行完成"
        ]
    }
}

// MARK: - ServiceMetadata 定义

struct ServiceMetadata {
    let id: String
    let name: String
    let description: String
    let capabilities: [String]
}
