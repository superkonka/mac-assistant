//
//  WorkflowDraftService.swift
//  MacAssistant
//
//  从 RequestPlan 生成 WorkflowDraft
//

import Foundation

@MainActor
final class WorkflowDraftService {
    static let shared = WorkflowDraftService()
    
    private let draftStore = WorkflowDraftStore.shared
    private let definitionStore = WorkflowDefinitionStore.shared
    
    private init() {}
    
    // MARK: - 生成 Draft
    
    /// 从 WorkflowCandidate 创建 Draft
    func createDraft(from candidate: WorkflowCandidate, originalInput: String) throws -> WorkflowDraft {
        LogInfo("[WorkflowDraftService] 从 Candidate 创建 Draft: \(candidate.name)")
        return try draftStore.createFromCandidate(candidate, originalInput: originalInput)
    }
    
    /// 补充缺失的槽位
    func fillSlots(draftID: String, slots: [PlanningSlot]) throws -> WorkflowDraft {
        guard var draft = draftStore.draft(id: draftID) else {
            throw WorkflowDraftError.draftNotFound
        }
        
        // 合并槽位值
        var updatedMissingSlots: [PlanningSlot] = []
        for slot in draft.missingSlots {
            if let filledSlot = slots.first(where: { $0.name == slot.name && $0.isFilled }) {
                // 已填充，跳过
                LogInfo("[WorkflowDraftService] 槽位已填充: \(slot.name) = \(filledSlot.value ?? "")")
            } else {
                updatedMissingSlots.append(slot)
            }
        }
        
        // 创建更新后的 Draft
        let updatedDraft = WorkflowDraft(
            id: draft.id,
            name: draft.name,
            description: draft.description,
            originalInput: draft.originalInput,
            suggestedSteps: draft.suggestedSteps,
            missingSlots: updatedMissingSlots,
            context: draft.context,
            status: updatedMissingSlots.isEmpty ? .ready : .clarifying
        )
        
        try draftStore.save(updatedDraft)
        return updatedDraft
    }
    
    /// 发布 Draft 为正式的 WorkflowDefinition
    func publishDraft(draftID: String, approvalPolicy: ApprovalPolicy? = nil) throws -> WorkflowDefinition {
        guard let draft = draftStore.draft(id: draftID) else {
            throw WorkflowDraftError.draftNotFound
        }
        
        guard draft.status == .ready || draft.missingSlots.isEmpty else {
            throw WorkflowDraftError.invalidTransition
        }
        
        LogInfo("[WorkflowDraftService] 发布 Draft: \(draft.name)")
        
        // 创建 Definition
        let definition = try definitionStore.createFromDraft(draft, bindings: [])
        
        // 标记 Draft 为已发布
        try draftStore.markAsPublished(id: draftID, definitionID: definition.id)
        
        return definition
    }

    func createReplanDraft(
        definitionID: String,
        runID: String,
        stepID: String?,
        workflowName: String,
        workflowDescription: String,
        userInput: String,
        steps: [WorkflowStepDef]
    ) throws -> WorkflowDraft {
        let draft = WorkflowDraft(
            name: workflowName,
            description: workflowDescription,
            originalInput: userInput,
            suggestedSteps: steps,
            missingSlots: [],
            context: WorkflowDraftContext(
                purpose: .replan,
                definitionID: definitionID,
                runID: runID,
                stepID: stepID
            ),
            status: .ready
        )
        try draftStore.save(draft)
        return draft
    }

    func markReplanDraftApplied(draftID: String) throws {
        try draftStore.markAsApplied(id: draftID)
    }
    
    /// 修改 Draft 步骤
    func updateDraftSteps(draftID: String, steps: [WorkflowStepDef]) throws -> WorkflowDraft {
        guard let draft = draftStore.draft(id: draftID) else {
            throw WorkflowDraftError.draftNotFound
        }
        
        let updatedDraft = WorkflowDraft(
            id: draft.id,
            name: draft.name,
            description: draft.description,
            originalInput: draft.originalInput,
            suggestedSteps: steps,
            missingSlots: draft.missingSlots,
            context: draft.context,
            status: draft.status
        )
        
        try draftStore.save(updatedDraft)
        return updatedDraft
    }
    
    /// 放弃 Draft
    func discardDraft(draftID: String) throws {
        try draftStore.markAsDiscarded(id: draftID)
    }
    
    // MARK: - 生成建议
    
    /// 基于用户输入和 Draft 生成下一步建议
    func generateNextStepsSuggestion(draft: WorkflowDraft) -> String {
        if !draft.missingSlots.isEmpty {
            let slotDescriptions = draft.missingSlots.map { "• \($0.description)" }.joined(separator: "\n")
            return """
            我还需要以下信息才能创建 workflow：
            \(slotDescriptions)
            
            请直接告诉我，例如："每天早上9点" 或 "发给张三"。
            """
        }
        
        if draft.status == .ready {
            return """
            Workflow 草稿「\(draft.name)」已准备就绪。
            
            包含 \(draft.suggestedSteps.count) 个步骤：
            \(draft.suggestedSteps.enumerated().map { "\($0 + 1). \($1.name)" }.joined(separator: "\n"))
            
            你可以：
            • 回复"确认"发布为正式 workflow
            • 回复"修改"调整步骤
            • 回复"取消"放弃创建
            """
        }
        
        return "Workflow 草稿「\(draft.name)」当前状态：\(draft.status.rawValue)"
    }
    
    /// 生成 workflow 执行预览
    func generateExecutionPreview(draft: WorkflowDraft) -> String {
        let steps = draft.suggestedSteps.enumerated().map { index, step in
            let approvalMark = step.requiresApproval ? " [需审批]" : ""
            return "\(index + 1). \(step.name)\(approvalMark)"
        }.joined(separator: "\n")
        
        return """
        Workflow「\(draft.name)」执行预览：
        
        \(steps)
        
        预估执行时间：\(estimateExecutionTime(steps: draft.suggestedSteps)) 分钟
        是否需要审批：\(draft.suggestedSteps.contains { $0.requiresApproval } ? "是" : "否")
        """
    }
    
    private func estimateExecutionTime(steps: [WorkflowStepDef]) -> Int {
        // 简化估算：每个步骤平均 2 分钟
        return steps.count * 2
    }
}
