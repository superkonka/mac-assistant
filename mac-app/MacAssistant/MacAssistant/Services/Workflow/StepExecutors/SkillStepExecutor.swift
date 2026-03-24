//
//  SkillStepExecutor.swift
//  MacAssistant
//
//  Skill 步骤执行器 - 调用原子 Skill
//

import Foundation

@MainActor
final class SkillStepExecutor: StepExecutor {
    static let shared = SkillStepExecutor()
    
    let supportedKinds: [WorkflowStepKind] = [.action]
    let supportedBindingKinds: [WorkflowBindingKind] = [.skill]
    
    private let skillSystem = SkillSystem.shared
    private var activeRuns: Set<String> = []
    
    private init() {}
    
    func isAvailable() async -> Bool {
        return true
    }
    
    func cancel(runID: String) {
        activeRuns.remove(runID)
        LogInfo("[SkillStepExecutor] 取消执行: \(runID)")
    }
    
    func execute(_ step: WorkflowStepDef, context: WorkflowContext) async -> StepExecutionResult {
        guard !activeRuns.contains(context.runID) else {
            return .failure(error: .cancelled)
        }
        
        activeRuns.insert(context.runID)
        defer { activeRuns.remove(context.runID) }
        
        LogInfo("[SkillStepExecutor] 执行步骤: \(step.name), Run: \(context.runID)")
        
        // 从 bindingID 获取 Skill 信息
        guard let skillIdentifier = context.binding?.targetID ?? step.bindingID else {
            return .failure(error: StepExecutionError(
                code: "NO_BINDING",
                message: "步骤没有绑定 Skill",
                isRetryable: false
            ))
        }
        
        // 获取 Skill 定义
        guard let skill = findSkill(byBindingID: skillIdentifier) else {
            return .failure(error: StepExecutionError(
                code: "SKILL_NOT_FOUND",
                message: "找不到绑定的 Skill: \(skillIdentifier)",
                isRetryable: false
            ))
        }
        
        // 构建输入参数
        let input = buildSkillInput(step: step, context: context)
        
        do {
            // 执行 Skill
            let result = try await executeSkill(skill, input: input)
            return .success(output: result)
        } catch {
            return .failure(error: StepExecutionError(
                code: "SKILL_EXECUTION_FAILED",
                message: error.localizedDescription,
                isRetryable: true
            ))
        }
    }
    
    // MARK: - Skill 查找
    
    private func findSkill(byBindingID bindingID: String) -> AISkill? {
        // 从 SkillSystem 查找
        // 简化实现：直接返回 rawValue 匹配的技能
        return AISkill.allCases.first { $0.rawValue == bindingID }
    }
    
    private func findSkill(byName name: String) -> AISkill? {
        return AISkill.allCases.first { 
            $0.name.lowercased() == name.lowercased() ||
            $0.rawValue.lowercased() == name.lowercased()
        }
    }
    
    // MARK: - 输入构建
    
    private func buildSkillInput(step: WorkflowStepDef, context: WorkflowContext) -> String {
        var components: [String] = []
        
        // 添加步骤描述
        if !step.description.isEmpty {
            components.append(step.description)
        }
        
        // 添加上下文变量
        for (key, value) in context.variables {
            components.append("\(key): \(value)")
        }
        
        return components.joined(separator: "\n")
    }
    
    // MARK: - Skill 执行
    
    private func executeSkill(_ skill: AISkill, input: String) async throws -> [String: String] {
        LogInfo("[SkillStepExecutor] 执行 Skill: \(skill.name), 输入: \(input.prefix(100))...")
        
        // 调用 SkillSystem
        // 注意：这里需要适配现有的 SkillSystem 接口
        // 简化实现：返回模拟结果
        
        switch skill {
        case .screenshot:
            return [
                "skill": "screenshot",
                "status": "completed",
                "path": "/tmp/screenshot_\(UUID().uuidString).png"
            ]
            
        case .analyzeDisk:
            return [
                "skill": "analyzeDisk",
                "status": "completed",
                "result": "磁盘分析完成"
            ]
            
        case .explainSelection:
            return [
                "skill": "explainSelection",
                "status": "completed",
                "explanation": "解释完成"
            ]
            
        case .translateText:
            return [
                "skill": "translateText",
                "status": "completed",
                "translation": "翻译完成"
            ]
            
        case .summarizeText:
            return [
                "skill": "summarizeText",
                "status": "completed",
                "summary": "摘要完成"
            ]
            
        case .codeReview:
            return [
                "skill": "codeReview",
                "status": "completed",
                "review": "代码审查完成"
            ]
            
        @unknown default:
            return [
                "skill": skill.rawValue,
                "status": "completed",
                "output": "Skill 执行完成"
            ]
        }
    }
}
