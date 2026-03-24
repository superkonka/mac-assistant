//
//  TaskLegacyBridge.swift
//  MacAssistant
//
//  新旧任务模型兼容桥接
//

import Foundation

enum TaskLegacyBridge {
    static func buildLegacyTasks(
        definitions: [TaskDefinition],
        runs: [TaskRun]
    ) -> [UnifiedTask] {
        definitions
            .compactMap { definition in
                makeLegacyTask(
                    from: definition,
                    runs: runs.filter { $0.definitionID == definition.id }
                )
            }
            .sorted { lhs, rhs in
                lhs.updatedAt > rhs.updatedAt
            }
    }

    static func makeStatistics(from tasks: [UnifiedTask]) -> TaskStatistics {
        TaskStatistics(
            total: tasks.count,
            pending: tasks.filter { $0.status == .pending }.count,
            running: tasks.filter { $0.status == .running }.count,
            paused: tasks.filter { $0.status == .paused }.count,
            completed: tasks.filter { $0.status == .completed }.count,
            failed: tasks.filter { $0.status == .failed }.count
        )
    }

    static func makeLegacyTask(from definition: TaskDefinition, runs: [TaskRun]) -> UnifiedTask? {
        let latestRun = preferredRun(from: runs)
        let status = mapStatus(definition: definition, latestRun: latestRun)
        let detail = detailText(definition: definition, latestRun: latestRun)
        let result = latestRun?.output.summary
        let errorMessage = latestRun?.error?.message

        var task = UnifiedTask(
            id: definition.id,
            type: definition.kind.unifiedTaskType,
            title: definition.title,
            description: detail,
            status: status,
            assignedAgentID: definition.assignedAgentID,
            assignedAgentName: definition.assignedAgentName,
            strategy: definition.strategy,
            inputContext: definition.inputContext,
            result: result,
            errorMessage: errorMessage,
            messages: definition.messages,
            logs: definition.logs,
            canResume: definition.canResume,
            gatewaySessionKey: definition.gatewaySessionKey,
            originalRequest: definition.originalRequest,
            scheduledTime: definition.nextRunAt ?? latestRun?.scheduledAt ?? latestRun?.nextRetryAt,
            parentTaskID: definition.parentTaskID,
            maxRetries: definition.policy.maxRetries
        )

        task.createdAt = definition.createdAt
        task.updatedAt = latestRun?.updatedAt ?? definition.updatedAt
        task.startedAt = latestRun?.startedAt
        task.completedAt = latestRun?.finishedAt
        task.executionTime = latestRun?.executionTime
        task.retryCount = max((latestRun?.attempt ?? 0) - 1, 0)

        return task
    }

    private static func preferredRun(from runs: [TaskRun]) -> TaskRun? {
        runs.sorted { lhs, rhs in
            if lhs.phase.isActive != rhs.phase.isActive {
                return lhs.phase.isActive && !rhs.phase.isActive
            }
            return lhs.updatedAt > rhs.updatedAt
        }.first
    }

    private static func mapStatus(definition: TaskDefinition, latestRun: TaskRun?) -> UnifiedTaskStatus {
        if definition.state == .paused {
            return .paused
        }

        guard let latestRun else {
            return definition.nextRunAt != nil ? .pending : .pending
        }

        switch latestRun.phase {
        case .scheduled, .queued:
            return .pending
        case .running:
            return .running
        case .paused, .waitingInput, .retryWaiting:
            return .paused
        case .succeeded:
            return .completed
        case .failed, .cancelled:
            return .failed
        }
    }

    private static func detailText(definition: TaskDefinition, latestRun: TaskRun?) -> String {
        if definition.kind == .workflow,
           let workflowState = latestRun?.workflowState,
           let workflowDetail = workflowDetailText(for: workflowState) {
            return workflowDetail
        }

        if let latestRun,
           latestRun.phase == .retryWaiting,
           let retryTime = latestRun.nextRetryAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let retryLabel = formatter.localizedString(for: retryTime, relativeTo: Date())
            return "自动重试 \(retryLabel)"
        }

        if let latestRun,
           let error = latestRun.error?.message,
           !error.isEmpty,
           latestRun.phase == .failed || latestRun.phase == .waitingInput {
            return error
        }

        if let latestRun,
           let result = latestRun.output.summary,
           !result.isEmpty,
           latestRun.phase == .succeeded {
            return String(result.prefix(80))
        }

        if !definition.description.isEmpty {
            return definition.description
        }

        if let nextRunAt = definition.nextRunAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "计划执行 \(formatter.localizedString(for: nextRunAt, relativeTo: Date()))"
        }

        return definition.strategy.displayName
    }

    private static func workflowDetailText(for state: WorkflowRunState) -> String? {
        if let approval = state.pendingApproval {
            return "等待审批：\(approval.stepName)"
        }

        if let pendingReplan = state.pendingReplan {
            let preview = pendingReplan.proposedSteps.prefix(2).map(\.name).joined(separator: " -> ")
            if !preview.isEmpty {
                return "等待确认新方案：\(preview)"
            }
            return "等待确认新的 workflow 规划"
        }

        if let blockingReason = state.blockingReason {
            return blockingReason.displayMessage
        }

        if let activeStepID = state.activeStepID,
           let stepRun = state.stepRuns.last(where: { $0.stepID == activeStepID }) {
            switch stepRun.status {
            case .running:
                return "执行中：\(stepRun.stepName)"
            case .waitingApproval:
                return "等待审批：\(stepRun.stepName)"
            case .failed:
                return stepRun.error?.message ?? "步骤失败：\(stepRun.stepName)"
            default:
                break
            }
        }

        if let nextWakeAt = state.nextWakeAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "下次唤醒 \(formatter.localizedString(for: nextWakeAt, relativeTo: Date()))"
        }

        return nil
    }
}
