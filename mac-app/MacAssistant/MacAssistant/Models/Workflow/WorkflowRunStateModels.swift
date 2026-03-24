//
//  WorkflowRunStateModels.swift
//  MacAssistant
//
//  Workflow 运行状态模型
//

import Foundation

// MARK: - Workflow Run State

/// Workflow 运行状态 - 挂靠在 TaskRun 上
struct WorkflowRunState: Codable, Equatable {
    let definitionID: String                    // 关联的 Definition
    var activeStepID: String?                   // 当前步骤 ID
    var stepRuns: [WorkflowStepRun]             // 步骤执行历史
    var sharedContext: [String: String]         // 共享上下文变量
    var pendingApproval: PendingApproval?       // 待审批项
    var pendingReplan: PendingWorkflowReplan?   // 待确认的新规划
    var blockingReason: WorkflowBlockingReason? // 阻塞原因
    var lastReflectionAt: Date?                 // 上次反思时间
    var nextWakeAt: Date?                       // 下次唤醒时间
    var checkpoints: [WorkflowCheckpoint]       // 检查点记录
    
    init(
        definitionID: String,
        activeStepID: String? = nil,
        stepRuns: [WorkflowStepRun] = [],
        sharedContext: [String: String] = [:],
        pendingApproval: PendingApproval? = nil,
        pendingReplan: PendingWorkflowReplan? = nil,
        blockingReason: WorkflowBlockingReason? = nil,
        lastReflectionAt: Date? = nil,
        nextWakeAt: Date? = nil,
        checkpoints: [WorkflowCheckpoint] = []
    ) {
        self.definitionID = definitionID
        self.activeStepID = activeStepID
        self.stepRuns = stepRuns
        self.sharedContext = sharedContext
        self.pendingApproval = pendingApproval
        self.pendingReplan = pendingReplan
        self.blockingReason = blockingReason
        self.lastReflectionAt = lastReflectionAt
        self.nextWakeAt = nextWakeAt
        self.checkpoints = checkpoints
    }
    
    var currentStepRun: WorkflowStepRun? {
        guard let activeStepID = activeStepID else { return nil }
        return stepRuns.first { $0.stepID == activeStepID && $0.status == .running }
    }
    
    var isBlocked: Bool {
        blockingReason != nil || pendingApproval != nil || pendingReplan != nil
    }
    
    var progress: Double {
        guard !stepRuns.isEmpty else { return 0 }
        let completed = stepRuns.filter { $0.status == .completed }.count
        return Double(completed) / Double(stepRuns.count)
    }
}

// MARK: - Workflow Step Run

/// Workflow 步骤执行记录
struct WorkflowStepRun: Identifiable, Codable, Equatable {
    let id: String
    let stepID: String
    let stepName: String
    var status: StepRunStatus
    let startedAt: Date
    var completedAt: Date?
    var output: [String: String]?           // 步骤输出
    var error: StepRunError?                // 错误信息
    var retryCount: Int                     // 重试次数
    
    init(
        id: String = UUID().uuidString,
        stepID: String,
        stepName: String,
        status: StepRunStatus = .pending,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        output: [String: String]? = nil,
        error: StepRunError? = nil,
        retryCount: Int = 0
    ) {
        self.id = id
        self.stepID = stepID
        self.stepName = stepName
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.output = output
        self.error = error
        self.retryCount = retryCount
    }
}

enum StepRunStatus: String, Codable, Equatable {
    case pending       // 等待执行
    case running       // 执行中
    case completed     // 已完成
    case failed        // 失败
    case waitingApproval // 等待审批
    case skipped       // 已跳过
    case cancelled     // 已取消
}

struct StepRunError: Codable, Equatable {
    let code: String
    let message: String
    let isRetryable: Bool
}

// MARK: - Pending Approval

/// 待审批项
struct PendingApproval: Codable, Equatable {
    let stepID: String
    let stepName: String
    let description: String
    let requestedAt: Date
    let expiresAt: Date?
    let autoApproveOnTimeout: Bool
}

/// 待确认的重规划预览
struct PendingWorkflowReplan: Codable, Equatable {
    let draftID: String
    let sourceStepID: String?
    let reason: String
    let userInput: String
    let requestedAt: Date
    let proposedSteps: [WorkflowStepDef]
}

// MARK: - Workflow Blocking Reason

/// Workflow 阻塞原因
enum WorkflowBlockingReason: Codable, Equatable {
    case waitingUser(String)           // 等待用户输入
    case waitingExternal(String)       // 等待外部事件
    case waitingApproval(String)       // 等待审批
    case error(String, Bool)           // 错误（是否可重试）
    case maxRetriesExceeded(String)    // 超过最大重试次数
    case paused                        // 用户暂停
    
    var displayMessage: String {
        switch self {
        case .waitingUser(let detail):
            return "等待用户: \(detail)"
        case .waitingExternal(let detail):
            return "等待外部: \(detail)"
        case .waitingApproval(let detail):
            return "等待审批: \(detail)"
        case .error(let detail, let retryable):
            return retryable ? "错误(可重试): \(detail)" : "错误: \(detail)"
        case .maxRetriesExceeded(let detail):
            return "超过重试次数: \(detail)"
        case .paused:
            return "用户暂停"
        }
    }
}

// MARK: - Workflow Checkpoint

/// Workflow 检查点 - 记录重要决策
struct WorkflowCheckpoint: Identifiable, Codable, Equatable {
    let id: String
    let timestamp: Date
    let kind: CheckpointKind
    let description: String
    let metadata: [String: String]
    
    enum CheckpointKind: String, Codable, Equatable {
        case stepStarted
        case stepCompleted
        case stepFailed
        case approvalRequested
        case approvalGranted
        case approvalDenied
        case reflectionTriggered
        case replanRequested
        case replanExecuted
        case reminderSent
        case escalated
    }
}
