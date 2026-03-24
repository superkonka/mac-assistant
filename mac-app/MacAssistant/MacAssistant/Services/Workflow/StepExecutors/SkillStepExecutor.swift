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
            // 真正执行磁盘分析
            return await performRealDiskAnalysis()
            
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
    
    // MARK: - 真实磁盘分析
    
    private func performRealDiskAnalysis() async -> [String: String] {
        LogInfo("[SkillStepExecutor] 开始执行真实磁盘分析...")
        
        // 触发分析
        await MainActor.run {
            ResourceAnalyzer.shared.startAnalysis()
        }
        
        // 等待分析完成（最多30秒）
        var attempts = 0
        while attempts < 30 {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
            
            let isAnalyzing = await MainActor.run {
                ResourceAnalyzer.shared.isAnalyzing
            }
            
            if !isAnalyzing {
                break
            }
            attempts += 1
        }
        
        // 获取结果
        let result = await MainActor.run {
            ResourceAnalyzer.shared.analysisResult
        }
        
        guard let analysis = result else {
            return [
                "skill": "analyzeDisk",
                "status": "failed",
                "error": "分析未完成或失败"
            ]
        }
        
        // 构建详细的分析结果
        var resultLines: [String] = []
        
        // 总览
        let totalSizeGB = Double(analysis.totalScannedSize) / 1_000_000_000
        resultLines.append("📊 磁盘分析结果")
        resultLines.append("总扫描大小: \(String(format: "%.2f", totalSizeGB)) GB")
        resultLines.append("")
        
        // 分类统计
        if !analysis.categories.isEmpty {
            resultLines.append("📁 按类型分布:")
            for category in analysis.categories.prefix(5) {
                let sizeGB = Double(category.size) / 1_000_000_000
                resultLines.append("  - \(category.category.rawValue): \(String(format: "%.2f", sizeGB)) GB (\(category.count) 个文件)")
            }
            resultLines.append("")
        }
        
        // 大文件
        if !analysis.largeFiles.isEmpty {
            resultLines.append("📦 最大的文件:")
            for file in analysis.largeFiles.prefix(10) {
                let sizeMB = Double(file.size) / 1_000_000
                resultLines.append("  - \(file.name): \(String(format: "%.1f", sizeMB)) MB")
            }
            resultLines.append("")
        }
        
        // 建议
        if !analysis.suggestions.isEmpty {
            resultLines.append("💡 优化建议:")
            for suggestion in analysis.suggestions.prefix(5) {
                resultLines.append("  - \(suggestion.title)")
                resultLines.append("    \(suggestion.description)")
            }
        }
        
        let fullResult = resultLines.joined(separator: "\n")
        
        return [
            "skill": "analyzeDisk",
            "status": "completed",
            "result": fullResult,
            "totalSizeGB": String(format: "%.2f", totalSizeGB),
            "categoriesCount": "\(analysis.categories.count)",
            "largeFilesCount": "\(analysis.largeFiles.count)"
        ]
    }
}
