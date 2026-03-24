//
//  ServicePlanner.swift
//  MacAssistant
//
//  Planner 调度器 - 构建 ExecutionContext，指挥 CLI 执行
//

import Foundation

/// Planner 的服务管理调度器
@MainActor
final class ServicePlanner {
    static let shared = ServicePlanner()
    
    private let stateStore = ServiceStateStore.shared
    private var activeTasks: [String: Task<Void, Never>] = [:]
    
    // 对话上下文（实际应从 Conversation 获取）
    private var conversationContext: String = ""
    
    private init() {}
    
    // MARK: - 公共接口
    
    /// 执行服务操作并返回统一结果（用于主会话集成）
    func executeAndReport(
        serviceId: String,
        operation: ServiceOperation,
        userIntent: String? = nil,
        onResult: ((ExecutionResult) -> Void)? = nil
    ) async -> ExecutionResult {
        
        let taskId = "\(serviceId)_\(operation.rawValue)_\(UUID().uuidString.prefix(8))"
        
        // 1. 报告开始
        onResult?(.taskProgress(
            taskId: taskId,
            percent: 0,
            message: "开始\(operation.displayName) \(serviceId)..."
        ))
        
        // 2. 构建执行上下文
        let context = await buildExecutionContext(
            taskId: taskId,
            serviceId: serviceId,
            operation: operation,
            userIntent: userIntent
        )
        
        // 3. 更新状态为进行中
        updateState(serviceId, state: inProgressState(for: operation), adapter: nil, metadata: nil)
        
        // 4. 执行
        let cliResult = await CLIExecutor.execute(context: context) { progressMsg in
            onResult?(.taskProgress(
                taskId: taskId,
                percent: 50,
                message: progressMsg
            ))
        }
        
        // 5. 解析结果，更新状态
        let finalState = parseResultState(operation: operation, success: cliResult.success)
        updateState(
            serviceId,
            state: finalState,
            adapter: context.prerequisites.detectedAdapter,
            metadata: [
                "last_operation": operation.rawValue,
                "execution_time": "\(cliResult.executionTime)"
            ]
        )
        
        // 6. 构建统一结果
        let result = ExecutionResult(
            source: .service,
            success: cliResult.success,
            message: cliResult.friendlyOutput,
            detail: cliResult.stdout,
            metadata: [
                "service_id": serviceId,
                "operation": operation.rawValue,
                "final_state": finalState.rawValue,
                "execution_time": "\(cliResult.executionTime)",
                "attempts": "\(cliResult.attempts)"
            ],
            taskId: taskId,
            serviceId: serviceId
        )
        
        onResult?(result)
        return result
    }
    
    /// 兼容旧接口的执行方法
    func execute(
        serviceId: String,
        operation: ServiceOperation,
        userIntent: String? = nil,
        progress: ((String) -> Void)? = nil
    ) async -> ServicePlanResult {
        
        let result = await executeAndReport(
            serviceId: serviceId,
            operation: operation,
            userIntent: userIntent
        ) { executionResult in
            if executionResult.isProgress {
                progress?(executionResult.message)
            }
        }
        
        return ServicePlanResult(
            taskId: result.taskId ?? "",
            success: result.success,
            finalState: .running, // 简化处理
            message: result.message,
            outputs: result.detail?.components(separatedBy: "\n") ?? []
        )
    }
    
    /// 批量执行（带依赖关系）
    func executeBatch(
        operations: [(serviceId: String, operation: ServiceOperation)],
        userIntent: String? = nil,
        progress: ((String) -> Void)? = nil
    ) async -> [ServicePlanResult] {
        var results: [ServicePlanResult] = []
        
        for (index, op) in operations.enumerated() {
            progress?("[批次 \(index+1)/\(operations.count)] 处理 \(op.serviceId)...")
            
            let result = await execute(
                serviceId: op.serviceId,
                operation: op.operation,
                userIntent: userIntent,
                progress: progress
            )
            
            results.append(result)
            
            // 依赖失败则停止
            if !result.success {
                progress?("[批次] \(op.serviceId) 失败，停止后续操作")
                break
            }
        }
        
        return results
    }
    
    /// 更新对话上下文（用于回填给 CLI）
    func updateConversationContext(_ summary: String) {
        self.conversationContext = summary
    }
    
    /// 检查是否有活跃任务
    func hasActiveTask(for serviceId: String) -> Bool {
        // 检查该服务是否有进行中的任务
        return stateStore.state(for: serviceId)?.isActive == true
    }
    
    // MARK: - 构建执行上下文
    
    private func buildExecutionContext(
        taskId: String,
        serviceId: String,
        operation: ServiceOperation,
        userIntent: String?
    ) async -> ExecutionContext {
        
        // 1. 获取服务当前状态
        let currentState = stateStore.state(for: serviceId)
        
        // 2. 检测前提条件
        let prerequisites = await detectPrerequisites(serviceId: serviceId)
        
        // 3. 构建上下文
        let context = ExecutionContext.builder(
            taskId: taskId,
            operation: operation.rawValue,
            serviceId: serviceId
        )
        .withConversation(
            conversationContext,
            intent: userIntent ?? "管理 \(serviceId) 服务"
        )
        .withPrerequisites(prerequisites)
        .withEnvironment([
            "SERVICE_ID": serviceId,
            "SERVICE_NAME": currentState?.name ?? serviceId,
            "PLANNER_TASK_ID": taskId
        ])
        .withTimeout(60)
        .withPreferences(UserPreferences(
            verboseOutput: false,
            autoConfirm: false,
            preferredAdapter: currentState?.adapter,
            notificationEnabled: true
        ))
        .build()
        
        return context
    }
    
    // MARK: - 前提条件检测
    
    private func detectPrerequisites(serviceId: String) async -> Prerequisites {
        var isInstalled = false
        var isRunning = false
        var port: Int? = nil
        var adapter: String? = nil
        
        // 检测安装状态
        let brewCheck = await CLIExecutor.execute(
            context: .builder(taskId: "check", operation: "status", serviceId: serviceId)
                .withTimeout(5)
                .build()
        )
        
        if brewCheck.stdout.contains("started") || brewCheck.stdout.contains("running") {
            isInstalled = true
            isRunning = true
            adapter = "homebrew"
        } else if brewCheck.stdout.contains("stopped") {
            isInstalled = true
            isRunning = false
            adapter = "homebrew"
        }
        
        // 检测端口（从配置或常见端口）
        port = detectCommonPort(for: serviceId)
        if let p = port {
            let portCheck = await CLIExecutor.execute(
                context: .builder(taskId: "port_check", operation: "status", serviceId: serviceId)
                    .withTimeout(5)
                    .build()
            )
            // 如果端口被占用且服务未运行，说明有冲突
            if !portCheck.stdout.isEmpty && !isRunning {
                // 端口被占用
            }
        }
        
        // 如果没有检测到适配器，选择最佳
        if adapter == nil {
            adapter = detectBestAdapter()
        }
        
        return Prerequisites(
            isInstalled: isInstalled,
            isRunning: isRunning,
            portAvailable: port,
            diskSpaceMB: nil,
            detectedAdapter: adapter
        )
    }
    
    // MARK: - 状态更新
    
    private func updateState(
        _ serviceId: String,
        state: ServiceRuntimeState,
        adapter: String? = nil,
        metadata: [String: String]? = nil
    ) {
        let existingSnapshot = stateStore.state(for: serviceId)
        
        let snapshot = ServiceStateSnapshot(
            id: serviceId,
            name: existingSnapshot?.name ?? serviceId,
            state: state,
            adapter: adapter ?? existingSnapshot?.adapter,
            pid: existingSnapshot?.pid,
            port: existingSnapshot?.port,
            lastError: existingSnapshot?.lastError,
            lastOperation: existingSnapshot?.lastOperation,
            lastUpdated: Date(),
            metadata: metadata ?? [:]
        )
        
        stateStore.updateState(snapshot)
    }
    
    private func inProgressState(for operation: ServiceOperation) -> ServiceRuntimeState {
        switch operation {
        case .start: return .starting
        case .stop: return .stopping
        case .restart: return .stopping
        case .check: return .checking
        }
    }
    
    private func parseResultState(operation: ServiceOperation, success: Bool) -> ServiceRuntimeState {
        guard success else { return .error }
        
        switch operation {
        case .start, .restart:
            return .running
        case .stop:
            return .stopped
        case .check:
            return .running
        }
    }
    
    private func detectCommonPort(for serviceId: String) -> Int? {
        let ports: [String: Int] = [
            "postgresql": 5432,
            "redis": 6379,
            "mysql": 3306,
            "mongodb": 27017,
            "nginx": 80,
            "rabbitmq": 5672
        ]
        return ports[serviceId]
    }
    
    private func detectBestAdapter() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ||
           FileManager.default.fileExists(atPath: "/usr/local/bin/brew") {
            return "homebrew"
        }
        return "native"
    }
}

// MARK: - ServiceOperation 扩展

extension ServiceOperation {
    var displayName: String {
        switch self {
        case .start: return "启动"
        case .stop: return "停止"
        case .restart: return "重启"
        case .check: return "检查"
        }
    }
}

struct ServicePlanResult {
    let taskId: String
    let success: Bool
    let finalState: ServiceRuntimeState
    let message: String
    let outputs: [String]
}
