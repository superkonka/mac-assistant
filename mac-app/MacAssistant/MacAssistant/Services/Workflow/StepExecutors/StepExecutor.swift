//
//  StepExecutor.swift
//  MacAssistant
//
//  Step Executor 协议定义
//

import Foundation

// MARK: - Step Execution Context

/// 步骤执行上下文
struct WorkflowContext {
    let runID: String
    let definitionID: String
    let stepID: String
    let binding: WorkflowBinding?
    var variables: [String: String]  // 变量表
    let previousOutputs: [String: String]  // 前置步骤输出
    
    init(
        runID: String,
        definitionID: String,
        stepID: String,
        binding: WorkflowBinding? = nil,
        variables: [String: String] = [:],
        previousOutputs: [String: String] = [:]
    ) {
        self.runID = runID
        self.definitionID = definitionID
        self.stepID = stepID
        self.binding = binding
        self.variables = variables
        self.previousOutputs = previousOutputs
    }
    
    mutating func setVariable(_ value: String, for key: String) {
        variables[key] = value
    }
    
    func variable(_ key: String) -> String? {
        variables[key] ?? previousOutputs[key]
    }
}

// MARK: - Step Execution Result

/// 步骤执行结果
enum StepExecutionResult {
    case success(output: [String: String])           // 成功，带输出
    case failure(error: StepExecutionError)          // 失败
    case waiting(reason: String)                     // 等待（如审批）
    case needsApproval(approval: PendingApproval)    // 需要人工审批
    case skipped(reason: String)                     // 已跳过
    case jump(toStepID: String)                      // 跳转到指定步骤
}

/// 步骤执行错误
struct StepExecutionError: Error {
    let code: String
    let message: String
    let isRetryable: Bool
    let details: [String: String]?
    
    init(
        code: String,
        message: String,
        isRetryable: Bool = true,
        details: [String: String]? = nil
    ) {
        self.code = code
        self.message = message
        self.isRetryable = isRetryable
        self.details = details
    }
    
    static let notFound = StepExecutionError(
        code: "NOT_FOUND",
        message: "找不到执行目标",
        isRetryable: false
    )
    
    static let timeout = StepExecutionError(
        code: "TIMEOUT",
        message: "执行超时",
        isRetryable: true
    )
    
    static let cancelled = StepExecutionError(
        code: "CANCELLED",
        message: "用户取消",
        isRetryable: false
    )
}

// MARK: - Step Executor Protocol

/// Step Executor 协议
@MainActor
protocol StepExecutor {
    /// 支持的步骤类型
    var supportedKinds: [WorkflowStepKind] { get }

    /// 支持的绑定类型
    var supportedBindingKinds: [WorkflowBindingKind] { get }
    
    /// 执行步骤
    /// - Parameters:
    ///   - step: 要执行的步骤定义
    ///   - context: 执行上下文
    /// - Returns: 执行结果
    func execute(_ step: WorkflowStepDef, context: WorkflowContext) async -> StepExecutionResult
    
    /// 取消执行
    func cancel(runID: String)
    
    /// 检查执行器是否可用
    func isAvailable() async -> Bool
}

@MainActor
extension StepExecutor {
    var supportedBindingKinds: [WorkflowBindingKind] { [] }
}

// MARK: - Step Executor Registry

/// Step Executor 注册表
@MainActor
final class StepExecutorRegistry {
    static let shared = StepExecutorRegistry()
    
    private var executors: [String: StepExecutor] = [:]
    
    private init() {}
    
    /// 注册执行器
    func register(_ executor: StepExecutor, forID id: String) {
        executors[id] = executor
        LogInfo("[StepExecutorRegistry] 注册执行器: \(id), 支持类型: \(executor.supportedKinds)")
    }
    
    /// 获取执行器
    func executor(forID id: String) -> StepExecutor? {
        executors[id]
    }
    
    /// 查找支持指定步骤类型的执行器
    func executor(for kind: WorkflowStepKind) -> StepExecutor? {
        executors.values.first { $0.supportedKinds.contains(kind) }
    }

    /// 查找支持指定绑定类型的执行器
    func executor(for bindingKind: WorkflowBindingKind) -> StepExecutor? {
        executors.values.first { $0.supportedBindingKinds.contains(bindingKind) }
    }

    /// 根据步骤和绑定选择执行器
    func executor(for step: WorkflowStepDef, binding: WorkflowBinding?) -> StepExecutor? {
        if step.kind == .approval {
            return executor(forID: "approval") ?? executor(for: step.kind)
        }

        if step.kind == .notification {
            return executor(forID: "notification") ?? executor(for: step.kind)
        }

        if let binding, let executor = executor(for: binding.kind) {
            return executor
        }

        if step.kind == .action {
            // 没有显式 binding 时，优先走浏览器执行器，避免多个 .action 执行器随机命中
            return executor(forID: "browser") ?? executor(for: step.kind)
        }

        return executor(for: step.kind)
    }
    
    /// 列出所有执行器
    func allExecutors() -> [String: StepExecutor] {
        executors
    }
    
    /// 检查是否有执行器支持指定类型
    func hasExecutor(for kind: WorkflowStepKind) -> Bool {
        executors.values.contains { $0.supportedKinds.contains(kind) }
    }
}
