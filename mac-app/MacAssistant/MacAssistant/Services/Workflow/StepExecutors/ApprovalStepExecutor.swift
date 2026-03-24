//
//  ApprovalStepExecutor.swift
//  MacAssistant
//
//  审批步骤执行器 - 暂停 workflow 等待用户确认
//

import Foundation

@MainActor
final class ApprovalStepExecutor: StepExecutor {
    static let shared = ApprovalStepExecutor()
    
    let supportedKinds: [WorkflowStepKind] = [.approval]
    
    private var pendingApprovals: [String: PendingApproval] = [:]
    
    private init() {}
    
    func isAvailable() async -> Bool {
        return true
    }
    
    func cancel(runID: String) {
        pendingApprovals.removeValue(forKey: runID)
        LogInfo("[ApprovalStepExecutor] 取消审批: \(runID)")
    }
    
    func execute(_ step: WorkflowStepDef, context: WorkflowContext) async -> StepExecutionResult {
        LogInfo("[ApprovalStepExecutor] 请求审批: \(step.name), Run: \(context.runID)")
        
        // 创建审批请求
        let approval = PendingApproval(
            stepID: step.id,
            stepName: step.name,
            description: buildApprovalDescription(step: step, context: context),
            requestedAt: Date(),
            expiresAt: Date().addingTimeInterval(step.timeout ?? 3600),
            autoApproveOnTimeout: false
        )
        
        pendingApprovals[context.runID] = approval
        
        // 返回等待审批状态
        return .needsApproval(approval: approval)
    }
    
    /// 处理用户审批响应
    func handleApprovalResponse(runID: String, approved: Bool, response: String? = nil) -> StepExecutionResult {
        guard let approval = pendingApprovals[runID] else {
            return .failure(error: StepExecutionError(
                code: "APPROVAL_NOT_FOUND",
                message: "找不到审批请求",
                isRetryable: false
            ))
        }
        
        pendingApprovals.removeValue(forKey: runID)
        
        if approved {
            LogInfo("[ApprovalStepExecutor] 审批通过: \(runID)")
            return .success(output: [
                "approved": "true",
                "stepID": approval.stepID,
                "response": response ?? ""
            ])
        } else {
            LogInfo("[ApprovalStepExecutor] 审批拒绝: \(runID)")
            return .failure(error: StepExecutionError(
                code: "APPROVAL_DENIED",
                message: "用户拒绝了操作",
                isRetryable: false
            ))
        }
    }
    
    /// 检查是否有待审批的请求
    func hasPendingApproval(runID: String) -> Bool {
        pendingApprovals[runID] != nil
    }
    
    /// 获取待审批信息
    func pendingApproval(for runID: String) -> PendingApproval? {
        pendingApprovals[runID]
    }
    
    /// 检查过期的审批并自动处理
    func checkExpiredApprovals(autoDeny: Bool = true) {
        let now = Date()
        let expired = pendingApprovals.filter { _, approval in
            if let expiresAt = approval.expiresAt {
                return now > expiresAt
            }
            return false
        }
        
        for (runID, approval) in expired {
            if autoDeny || !approval.autoApproveOnTimeout {
                LogInfo("[ApprovalStepExecutor] 审批过期自动拒绝: \(runID)")
                pendingApprovals.removeValue(forKey: runID)
                // TODO: 通知 WorkflowRunCoordinator 审批已过期
            } else {
                LogInfo("[ApprovalStepExecutor] 审批过期自动通过: \(runID)")
                pendingApprovals.removeValue(forKey: runID)
                // TODO: 通知 WorkflowRunCoordinator 审批已通过
            }
        }
    }
    
    // MARK: - 辅助方法
    
    private func buildApprovalDescription(step: WorkflowStepDef, context: WorkflowContext) -> String {
        var components: [String] = []
        
        components.append("步骤: \(step.name)")
        
        if !step.description.isEmpty {
            components.append("描述: \(step.description)")
        }
        
        if !context.variables.isEmpty {
            components.append("参数:")
            for (key, value) in context.variables {
                components.append("  - \(key): \(value)")
            }
        }
        
        return components.joined(separator: "\n")
    }
    
    /// 生成给用户展示的审批消息
    func generateApprovalMessage(approval: PendingApproval) -> String {
        let expiresText: String
        if let expiresAt = approval.expiresAt {
            let minutes = Int(expiresAt.timeIntervalSinceNow / 60)
            expiresText = "（\(minutes) 分钟后过期）"
        } else {
            expiresText = ""
        }
        
        return """
        🔍 Workflow 审批请求 \(expiresText)
        
        \(approval.description)
        
        请回复：
        • "确认" 或 "通过" - 批准执行
        • "拒绝" 或 "取消" - 拒绝执行
        """
    }
}
