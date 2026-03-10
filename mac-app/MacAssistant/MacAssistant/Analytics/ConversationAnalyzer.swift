//
//  ConversationAnalyzer.swift
//  MacAssistant
//
//  对话分析器 - 分析问题并提供优化建议
//

import Foundation

/// 问题严重性
enum IssueSeverity: String, Codable {
    case critical = "严重"
    case major = "重要"
    case minor = "轻微"
    case suggestion = "建议"
}

/// 发现的问题
struct ConversationIssue: Identifiable {
    let id = UUID()
    let timestamp: Date
    let severity: IssueSeverity
    let category: String
    let title: String
    let description: String
    let suggestion: String
    let relatedEvents: [UUID]
}

/// 用户体验指标
struct UXMetrics {
    let totalTurns: Int                    // 总轮数
    let successfulTurns: Int               // 成功轮数
    let failedTurns: Int                   // 失败轮数
    let avgResponseTime: TimeInterval      // 平均响应时间
    let agentSwitchCount: Int              // Agent 切换次数
    let unnecessarySwitches: Int           // 不必要切换次数
    let confirmationCount: Int             // 确认提示次数
    let userConfirmationRate: Double       // 用户确认率
    let intentDetectionAccuracy: Double    // 意图检测准确率
    let skillExecutionSuccessRate: Double  // Skill 执行成功率
}

/// 对话分析器
class ConversationAnalyzer {
    static let shared = ConversationAnalyzer()
    
    private let logger = ConversationLogger.shared
    
    // MARK: - 分析入口
    
    /// 分析指定会话
    func analyzeSession(_ sessionId: String) -> (issues: [ConversationIssue], metrics: UXMetrics) {
        let events = logger.loadSession(sessionId)
        guard !events.isEmpty else {
            return ([], UXMetrics.zero)
        }
        
        var issues: [ConversationIssue] = []
        
        // 执行各类分析
        issues += analyzeResponseTimes(events)
        issues += analyzeAgentSwitches(events)
        issues += analyzeIntentDetection(events)
        issues += analyzeSkillExecution(events)
        issues += analyzeUserFlow(events)
        issues += analyzeErrors(events)
        issues += analyzeConfirmations(events)
        
        // 计算指标
        let metrics = calculateMetrics(events)
        
        return (issues.sorted { $0.severity.rawValue < $1.severity.rawValue }, metrics)
    }
    
    /// 生成分析报告
    func generateReport(sessionId: String) -> AnalysisReport {
        let (issues, metrics) = analyzeSession(sessionId)
        
        let criticalIssues = issues.filter { $0.severity == .critical }
        let majorIssues = issues.filter { $0.severity == .major }
        let minorIssues = issues.filter { $0.severity == .minor }
        let suggestions = issues.filter { $0.severity == .suggestion }
        
        return AnalysisReport(
            sessionId: sessionId,
            generatedAt: Date(),
            metrics: metrics,
            criticalIssues: criticalIssues,
            majorIssues: majorIssues,
            minorIssues: minorIssues,
            suggestions: suggestions,
            summary: generateSummary(metrics, issues: issues)
        )
    }
    
    // MARK: - 具体分析
    
    /// 分析响应时间
    private func analyzeResponseTimes(_ events: [ConversationEvent]) -> [ConversationIssue] {
        var issues: [ConversationIssue] = []
        
        let slowResponses = events.filter {
            guard let duration = $0.duration else { return false }
            return duration > 3.0  // 超过3秒算慢
        }
        
        if slowResponses.count > 3 {
            issues.append(ConversationIssue(
                timestamp: Date(),
                severity: .major,
                category: "性能",
                title: "响应时间过长",
                description: "检测到 \(slowResponses.count) 次响应超过 3 秒",
                suggestion: "优化 OpenClaw 连接或考虑使用更快的模型",
                relatedEvents: slowResponses.map { $0.id }
            ))
        }
        
        // 检查超时
        let timeouts = events.filter { $0.duration ?? 0 > 10.0 }
        if !timeouts.isEmpty {
            issues.append(ConversationIssue(
                timestamp: Date(),
                severity: .critical,
                category: "性能",
                title: "请求超时",
                description: "检测到 \(timeouts.count) 次请求超过 10 秒",
                suggestion: "检查网络连接，考虑添加超时处理和重试机制",
                relatedEvents: timeouts.map { $0.id }
            ))
        }
        
        return issues
    }
    
    /// 分析 Agent 切换
    private func analyzeAgentSwitches(_ events: [ConversationEvent]) -> [ConversationIssue] {
        var issues: [ConversationIssue] = []
        
        let switches = events.filter { $0.type == .agentSwitch }
        
        // 检查频繁切换
        if switches.count > 5 {
            issues.append(ConversationIssue(
                timestamp: Date(),
                severity: .minor,
                category: "Agent 管理",
                title: "Agent 切换过于频繁",
                description: "会话中切换了 \(switches.count) 次 Agent",
                suggestion: "建议用户为不同类型的任务选择默认 Agent，减少切换",
                relatedEvents: switches.map { $0.id }
            ))
        }
        
        // 检查是否有切换后立即切回的情况
        for i in 0..<(switches.count - 1) {
            let current = switches[i]
            let next = switches[i + 1]
            
            if current.metadata?["from"] == next.metadata?["to"] &&
               current.metadata?["to"] == next.metadata?["from"] {
                issues.append(ConversationIssue(
                    timestamp: current.timestamp,
                    severity: .major,
                    category: "Agent 管理",
                    title: "Agent 来回切换",
                    description: "用户在 \(current.agentName ?? "unknown") 和 \(next.agentName ?? "unknown") 之间来回切换",
                    suggestion: "切换提示不够清晰，建议改进 Agent 能力说明或添加自动选择逻辑",
                    relatedEvents: [current.id, next.id]
                ))
            }
        }
        
        return issues
    }
    
    /// 分析意图检测
    private func analyzeIntentDetection(_ events: [ConversationEvent]) -> [ConversationIssue] {
        var issues: [ConversationIssue] = []
        
        let detectedSkills = events.filter { $0.type == .skillDetected }
        let executedSkills = events.filter { $0.type == .skillExecuted }
        
        // 检查检测但未执行的情况
        let detectedSkillNames = Set(detectedSkills.compactMap { $0.metadata?["skill"] })
        let executedSkillNames = Set(executedSkills.compactMap { $0.skillName })
        let notExecuted = detectedSkillNames.subtracting(executedSkillNames)
        
        if notExecuted.count > 2 {
            issues.append(ConversationIssue(
                timestamp: Date(),
                severity: .major,
                category: "意图检测",
                title: "意图检测准确率低",
                description: "检测到 \(notExecuted.count) 个 Skill 意图但未被确认执行",
                suggestion: "用户可能觉得确认提示太烦扰。建议：1) 提高检测置信度阈值 2) 对高频技能默认执行 3) 优化确认提示文案",
                relatedEvents: detectedSkills.map { $0.id }
            ))
        }
        
        // 检查连续检测失败
        var consecutiveFails = 0
        var maxConsecutiveFails = 0
        for event in events {
            if event.type == .skillDetected {
                consecutiveFails += 1
                maxConsecutiveFails = max(maxConsecutiveFails, consecutiveFails)
            } else if event.type == .skillExecuted {
                consecutiveFails = 0
            }
        }
        
        if maxConsecutiveFails > 3 {
            issues.append(ConversationIssue(
                timestamp: Date(),
                severity: .critical,
                category: "意图检测",
                title: "连续意图检测被拒绝",
                description: "连续 \(maxConsecutiveFails) 次意图检测被用户拒绝",
                suggestion: "用户可能在使用自然语言时不想触发 Skill。建议：1) 降低自然语言检测敏感度 2) 只对明确命令触发 3) 添加关闭检测的选项",
                relatedEvents: []
            ))
        }
        
        return issues
    }
    
    /// 分析 Skill 执行
    private func analyzeSkillExecution(_ events: [ConversationEvent]) -> [ConversationIssue] {
        var issues: [ConversationIssue] = []
        
        let skillExecutions = events.filter { $0.type == .skillExecuted }
        
        // 检查失败率
        let failures = skillExecutions.filter { $0.metadata?["status"] == "error" }
        if failures.count > 0 {
            let failureRate = Double(failures.count) / Double(skillExecutions.count)
            if failureRate > 0.3 {
                issues.append(ConversationIssue(
                    timestamp: Date(),
                    severity: .critical,
                    category: "Skill 执行",
                    title: "Skill 执行失败率高",
                    description: "\(skillExecutions.count) 次执行中有 \(failures.count) 次失败 (\(Int(failureRate * 100))%)",
                    suggestion: "检查 Skill 实现，添加更健壮的错误处理和用户提示",
                    relatedEvents: failures.map { $0.id }
                ))
            }
        }
        
        // 检查需要创建 Agent 的情况
        let needAgent = skillExecutions.filter { $0.metadata?["status"] == "requires_agent" }
        if needAgent.count > 2 {
            issues.append(ConversationIssue(
                timestamp: Date(),
                severity: .major,
                category: "Skill 执行",
                title: "频繁需要创建 Agent",
                description: "\(needAgent.count) 次 Skill 执行需要创建新 Agent",
                suggestion: "建议引导用户创建通用 Vision Agent，或提供一键创建所有必要 Agents 的功能",
                relatedEvents: needAgent.map { $0.id }
            ))
        }
        
        return issues
    }
    
    /// 分析用户流程
    private func analyzeUserFlow(_ events: [ConversationEvent]) -> [ConversationIssue] {
        var issues: [ConversationIssue] = []
        
        // 检查会话开始后的第一次交互
        let userInputs = events.filter { $0.type == .userInput }
        guard userInputs.count > 1 else { return [] }
        
        let firstInput = userInputs[0]
        let secondInput = userInputs[1]
        
        // 检查是否第一次就遇到问题
        if let firstResponse = events.first(where: { $0.type == .systemResponse && $0.timestamp > firstInput.timestamp }),
           firstResponse.response?.contains("❌") == true || firstResponse.response?.contains("错误") == true {
            issues.append(ConversationIssue(
                timestamp: firstInput.timestamp,
                severity: .critical,
                category: "用户体验",
                title: "首次交互失败",
                description: "用户在第一次发送消息时就遇到错误",
                suggestion: "首次体验至关重要！检查默认 Agent 配置，确保开箱即用",
                relatedEvents: [firstInput.id, firstResponse.id]
            ))
        }
        
        // 检查是否有大量重试
        let similarInputs = findSimilarInputs(in: userInputs)
        if similarInputs.count > 2 {
            issues.append(ConversationIssue(
                timestamp: Date(),
                severity: .major,
                category: "用户体验",
                title: "用户多次尝试相同输入",
                description: "检测到 \(similarInputs.count) 次相似输入，用户可能在重试",
                suggestion: "系统响应可能不符合预期，检查是否正确理解用户意图",
                relatedEvents: similarInputs.map { $0.id }
            ))
        }
        
        return issues
    }
    
    /// 分析错误
    private func analyzeErrors(_ events: [ConversationEvent]) -> [ConversationIssue] {
        var issues: [ConversationIssue] = []
        
        let errors = events.filter { $0.type == .error }
        
        // 按错误类型分组
        let errorTypes = Dictionary(grouping: errors) { $0.error ?? "未知错误" }
        
        for (errorType, errorEvents) in errorTypes {
            if errorEvents.count > 2 {
                issues.append(ConversationIssue(
                    timestamp: Date(),
                    severity: .critical,
                    category: "错误",
                    title: "重复错误: \(errorType.prefix(50))...",
                    description: "该错误发生了 \(errorEvents.count) 次",
                    suggestion: "这是一个高频错误，需要优先修复",
                    relatedEvents: errorEvents.map { $0.id }
                ))
            }
        }
        
        return issues
    }
    
    /// 分析确认提示
    private func analyzeConfirmations(_ events: [ConversationEvent]) -> [ConversationIssue] {
        var issues: [ConversationIssue] = []
        
        let suggestions = events.filter {
            $0.type == .agentSuggested || $0.type == .skillDetected
        }
        
        // 检查确认提示频率
        if suggestions.count > 5 {
            issues.append(ConversationIssue(
                timestamp: Date(),
                severity: .minor,
                category: "确认提示",
                title: "确认提示过于频繁",
                description: "会话中出现 \(suggestions.count) 次确认提示",
                suggestion: "过多的确认会打断用户流程。建议：1) 对高置信度意图直接执行 2) 添加"记住我的选择"选项 3) 减少不必要的检测",
                relatedEvents: suggestions.map { $0.id }
            ))
        }
        
        return issues
    }
    
    // MARK: - 计算指标
    
    private func calculateMetrics(_ events: [ConversationEvent]) -> UXMetrics {
        let userInputs = events.filter { $0.type == .userInput }
        let systemResponses = events.filter { $0.type == .systemResponse }
        let agentSwitches = events.filter { $0.type == .agentSwitch }
        let skillExecutions = events.filter { $0.type == .skillExecuted }
        let errors = events.filter { $0.type == .error }
        let detections = events.filter { $0.type == .skillDetected }
        
        // 计算成功轮数（有响应且无错误）
        var successfulTurns = 0
        for input in userInputs {
            if let response = systemResponses.first(where: { $0.timestamp > input.timestamp }),
               response.error == nil && !(response.response?.contains("❌") ?? false) {
                successfulTurns += 1
            }
        }
        
        // 计算平均响应时间
        let responseTimes = systemResponses.compactMap { $0.duration }
        let avgResponseTime = responseTimes.isEmpty ? 0 : responseTimes.reduce(0, +) / Double(responseTimes.count)
        
        // 计算确认率
        let executedSkills = skillExecutions.count
        let detectedSkills = detections.count
        let confirmationRate = detectedSkills > 0 ? Double(executedSkills) / Double(detectedSkills) : 1.0
        
        // 计算 Skill 成功率
        let successfulSkills = skillExecutions.filter { $0.metadata?["status"] == "success" }.count
        let skillSuccessRate = skillExecutions.isEmpty ? 1.0 : Double(successfulSkills) / Double(skillExecutions.count)
        
        return UXMetrics(
            totalTurns: userInputs.count,
            successfulTurns: successfulTurns,
            failedTurns: userInputs.count - successfulTurns,
            avgResponseTime: avgResponseTime,
            agentSwitchCount: agentSwitches.count,
            unnecessarySwitches: 0,  // 需要更复杂的逻辑判断
            confirmationCount: detections.count,
            userConfirmationRate: confirmationRate,
            intentDetectionAccuracy: confirmationRate,
            skillExecutionSuccessRate: skillSuccessRate
        )
    }
    
    // MARK: - 辅助方法
    
    private func findSimilarInputs(in events: [ConversationEvent]) -> [ConversationEvent] {
        var groups: [[ConversationEvent]] = []
        
        for event in events {
            guard let input = event.input else { continue }
            
            var found = false
            for i in 0..<groups.count {
                if let firstInput = groups[i].first?.input,
                   similarity(between: input, and: firstInput) > 0.7 {
                    groups[i].append(event)
                    found = true
                    break
                }
            }
            
            if !found {
                groups.append([event])
            }
        }
        
        return groups.filter { $0.count > 1 }.flatMap { $0 }
    }
    
    private func similarity(between s1: String, and s2: String) -> Double {
        // 简单的相似度计算
        let set1 = Set(s1.lowercased())
        let set2 = Set(s2.lowercased())
        let intersection = set1.intersection(set2).count
        let union = set1.union(set2).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }
    
    private func generateSummary(_ metrics: UXMetrics, issues: [ConversationIssue]) -> String {
        var parts: [String] = []
        
        // 总体评价
        if metrics.successfulTurns == metrics.totalTurns {
            parts.append("✅ 本次会话体验良好，所有交互均成功完成。")
        } else {
            let successRate = Int(Double(metrics.successfulTurns) / Double(metrics.totalTurns) * 100)
            parts.append("⚠️ 本次会话成功率 \(successRate)%，存在改进空间。")
        }
        
        // 问题概述
        let critical = issues.filter { $0.severity == .critical }.count
        let major = issues.filter { $0.severity == .major }.count
        
        if critical > 0 {
            parts.append("发现 \(critical) 个严重问题需要立即修复。")
        }
        if major > 0 {
            parts.append("发现 \(major) 个重要问题建议优先处理。")
        }
        
        // 性能评价
        if metrics.avgResponseTime > 3 {
            parts.append("平均响应时间 \(String(format: "%.1f", metrics.avgResponseTime))s，建议优化。")
        }
        
        // Agent 切换评价
        if metrics.agentSwitchCount > 5 {
            parts.append("Agent 切换较频繁，建议优化 Agent 能力覆盖。")
        }
        
        return parts.joined(separator: "\n")
    }
}

// MARK: - 分析报告

struct AnalysisReport {
    let sessionId: String
    let generatedAt: Date
    let metrics: UXMetrics
    let criticalIssues: [ConversationIssue]
    let majorIssues: [ConversationIssue]
    let minorIssues: [ConversationIssue]
    let suggestions: [ConversationIssue]
    let summary: String
    
    var totalIssues: Int {
        criticalIssues.count + majorIssues.count + minorIssues.count + suggestions.count
    }
}

// MARK: - UXMetrics 扩展

extension UXMetrics {
    static var zero: UXMetrics {
        UXMetrics(
            totalTurns: 0,
            successfulTurns: 0,
            failedTurns: 0,
            avgResponseTime: 0,
            agentSwitchCount: 0,
            unnecessarySwitches: 0,
            confirmationCount: 0,
            userConfirmationRate: 0,
            intentDetectionAccuracy: 0,
            skillExecutionSuccessRate: 0
        )
    }
}
