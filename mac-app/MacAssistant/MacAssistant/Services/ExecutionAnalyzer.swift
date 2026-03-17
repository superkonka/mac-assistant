//
//  ExecutionAnalyzer.swift
//  MacAssistant
//
//  执行过程分析器 - 分析任务执行过程中的不合理之处，提供调优建议
//

import Foundation

/// 执行过程问题类型
enum ExecutionIssueType: String, Codable, CaseIterable {
    case timeout = "timeout"                    // 超时
    case streamInterrupted = "stream_interrupted" // 流中断
    case resourceExhaustion = "resource_exhaustion" // 资源耗尽
    case agentFailure = "agent_failure"         // Agent 失败
    case networkIssue = "network_issue"         // 网络问题
    case configurationError = "config_error"    // 配置错误
    case retryExhausted = "retry_exhausted"     // 重试耗尽
    case partialResult = "partial_result"       // 部分结果
    case unknown = "unknown"                    // 未知
}

/// 执行过程问题
struct ExecutionIssue: Identifiable, Codable {
    let id = UUID()
    let type: ExecutionIssueType
    let description: String
    let severity: IssueSeverity
    let timestamp: Date
    let context: [String: String]
    let suggestedActions: [RecoveryAction]
    
    enum IssueSeverity: String, Codable {
        case critical = "critical"    // 致命，必须处理
        case high = "high"            // 高，建议处理
        case medium = "medium"        // 中，可以优化
        case low = "low"              // 低，观察即可
    }
}

/// 恢复/调优动作
struct RecoveryAction: Codable, Equatable {
    let type: ActionType
    let description: String
    let confidence: Double  // 0-1，动作成功的置信度
    let estimatedTime: TimeInterval?  // 预计执行时间
    let requiresUserConfirmation: Bool
    let configChanges: [ConfigChange]?  // 相关配置调整
    
    enum ActionType: String, Codable {
        case retryWithBackoff = "retry_backoff"           // 指数退避重试
        case switchAgent = "switch_agent"                 // 切换 Agent
        case adjustTimeout = "adjust_timeout"             // 调整超时时间
        case adjustContextWindow = "adjust_context"       // 调整上下文窗口
        case splitTask = "split_task"                     // 拆分任务
        case useLocalFallback = "local_fallback"          // 使用本地回退
        case waitAndRetry = "wait_retry"                  // 等待后重试
        case requestUserInput = "request_user_input"      // 请求用户输入
        case checkpointResume = "checkpoint_resume"       // 从检查点恢复
        case adjustStrategy = "adjust_strategy"           // 调整策略
    }
}

/// 配置变更
struct ConfigChange: Codable, Equatable {
    let key: String
    let oldValue: String
    let newValue: String
    let reason: String
    let isRevertible: Bool  // 是否可以回滚
}

/// 执行快照
struct ExecutionSnapshot: Codable {
    let timestamp: Date
    let taskSessionID: String
    let agentID: UUID?
    let status: String
    let progress: Double  // 0-1
    let duration: TimeInterval
    let retryCount: Int
    let lastError: String?
    let partialResult: String?
    let configSnapshot: [String: String]
}

/// 过程分析结果
struct ProcessAnalysisResult {
    let issues: [ExecutionIssue]
    let rootCause: String?
    let recommendedStrategy: RecoveryStrategy
    let configAdjustments: [ConfigChange]
    let needsUserConfirmation: Bool
    let autoRecoverable: Bool
}

/// 恢复策略
struct RecoveryStrategy {
    let strategy: StrategyType
    let actions: [RecoveryAction]
    let fallbackChain: [RecoveryAction]
    let maxRetries: Int
    let adjustedTimeout: TimeInterval?
    let description: String
    
    enum StrategyType: String, Codable {
        case immediateRetry = "immediate_retry"
        case exponentialBackoff = "exponential_backoff"
        case agentSwitch = "agent_switch"
        case taskDecomposition = "task_decomposition"
        case localExecution = "local_execution"
        case userAssistance = "user_assistance"
        case checkpointBased = "checkpoint_based"
    }
}

/// 执行配置
struct ExecutionConfiguration {
    var timeoutBase: TimeInterval = 120
    var timeoutMultiplier: Double = 1.5
    var maxRetries: Int = 3
    var enableAutoRetry: Bool = true
    var enableAgentSwitch: Bool = true
    var enableTaskSplit: Bool = true
    var checkpointInterval: TimeInterval = 30
    var partialResultThreshold: Double = 0.3  // 30% 进度认为有价值
    var networkRetryDelay: TimeInterval = 5
    var streamTimeoutThreshold: TimeInterval = 60
}

/// 执行过程分析器
@MainActor
final class ExecutionAnalyzer {
    static let shared = ExecutionAnalyzer()
    
    private var executionHistory: [ExecutionSnapshot] = []
    private var configuration = ExecutionConfiguration()
    private var learnedPatterns: [String: RecoveryPattern] = [:]
    
    private init() {}
    
    // MARK: - 核心分析方法
    
    /// 分析执行过程问题
    func analyzeExecution(
        snapshot: ExecutionSnapshot,
        error: Error?,
        availableAgents: [Agent]
    ) -> ProcessAnalysisResult {
        
        var issues: [ExecutionIssue] = []
        var configAdjustments: [ConfigChange] = []
        
        // 1. 分析问题类型
        if let error = error {
            let issue = classifyError(error, context: snapshot)
            issues.append(issue)
            
            // 根据问题生成配置调整建议
            let adjustments = suggestConfigAdjustments(for: issue, currentConfig: configuration)
            configAdjustments.append(contentsOf: adjustments)
        }
        
        // 2. 分析执行模式
        let patternIssues = analyzeExecutionPatterns(snapshot)
        issues.append(contentsOf: patternIssues)
        
        // 3. 分析是否有部分结果可保留
        if let partial = snapshot.partialResult,
           !partial.isEmpty,
           snapshot.progress >= configuration.partialResultThreshold {
            let partialIssue = ExecutionIssue(
                type: .partialResult,
                description: "任务已产生 \(Int(snapshot.progress * 100))% 进度，建议保留",
                severity: .medium,
                timestamp: Date(),
                context: ["progress": "\(snapshot.progress)"],
                suggestedActions: [
                    RecoveryAction(
                        type: .checkpointResume,
                        description: "从当前检查点继续执行",
                        confidence: 0.8,
                        estimatedTime: snapshot.duration * (1 - snapshot.progress),
                        requiresUserConfirmation: false,
                        configChanges: nil
                    )
                ]
            )
            issues.append(partialIssue)
        }
        
        // 4. 分析重试次数
        if snapshot.retryCount >= configuration.maxRetries {
            let retryIssue = ExecutionIssue(
                type: .retryExhausted,
                description: "已重试 \(snapshot.retryCount) 次，需要调整策略",
                severity: .high,
                timestamp: Date(),
                context: ["retryCount": "\(snapshot.retryCount)"],
                suggestedActions: generateRetryExhaustedActions(snapshot, availableAgents: availableAgents)
            )
            issues.append(retryIssue)
        }
        
        // 5. 确定根因
        let rootCause = determineRootCause(issues)
        
        // 6. 生成恢复策略
        let strategy = generateRecoveryStrategy(
            issues: issues,
            snapshot: snapshot,
            availableAgents: availableAgents,
            configAdjustments: configAdjustments
        )
        
        // 7. 判断是否需要用户确认
        let needsUserConfirmation = issues.contains { $0.severity == .critical } ||
            configAdjustments.contains { !$0.isRevertible }
        
        // 8. 判断是否可自动恢复
        let autoRecoverable = strategy.actions.allSatisfy { !$0.requiresUserConfirmation } &&
            snapshot.retryCount < configuration.maxRetries * 2
        
        return ProcessAnalysisResult(
            issues: issues,
            rootCause: rootCause,
            recommendedStrategy: strategy,
            configAdjustments: configAdjustments,
            needsUserConfirmation: needsUserConfirmation,
            autoRecoverable: autoRecoverable
        )
    }
    
    // MARK: - 错误分类
    
    private func classifyError(_ error: Error, context: ExecutionSnapshot) -> ExecutionIssue {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        
        // Stream 中断
        if UserFacingErrorFormatter.isStreamInterruptedError(error) {
            return ExecutionIssue(
                type: .streamInterrupted,
                description: "OpenClaw 流中断，未收到完整响应",
                severity: .high,
                timestamp: Date(),
                context: [
                    "duration": "\(context.duration)",
                    "progress": "\(context.progress)"
                ],
                suggestedActions: [
                    RecoveryAction(
                        type: .adjustTimeout,
                        description: "增加超时时间到 \(Int(configuration.timeoutBase * 1.5))s",
                        confidence: 0.7,
                        estimatedTime: nil,
                        requiresUserConfirmation: false,
                        configChanges: [
                            ConfigChange(
                                key: "timeoutBase",
                                oldValue: "\(configuration.timeoutBase)",
                                newValue: "\(configuration.timeoutBase * 1.5)",
                                reason: "流中断通常因超时过短",
                                isRevertible: true
                            )
                        ]
                    ),
                    RecoveryAction(
                        type: .useLocalFallback,
                        description: "切换到本地 Kimi CLI 执行",
                        confidence: 0.8,
                        estimatedTime: context.duration * 0.8,
                        requiresUserConfirmation: false,
                        configChanges: nil
                    )
                ]
            )
        }
        
        // 超时
        if description.contains("timeout") || description.contains("timed out") || description.contains("超时") {
            return ExecutionIssue(
                type: .timeout,
                description: "请求超时 (\(Int(context.duration))s)",
                severity: .high,
                timestamp: Date(),
                context: ["duration": "\(context.duration)"],
                suggestedActions: [
                    RecoveryAction(
                        type: .adjustTimeout,
                        description: "增加超时时间",
                        confidence: 0.8,
                        estimatedTime: nil,
                        requiresUserConfirmation: false,
                        configChanges: [
                            ConfigChange(
                                key: "timeoutBase",
                                oldValue: "\(configuration.timeoutBase)",
                                newValue: "\(configuration.timeoutBase * configuration.timeoutMultiplier)",
                                reason: "任务执行时间超过当前超时设置",
                                isRevertible: true
                            )
                        ]
                    ),
                    RecoveryAction(
                        type: .splitTask,
                        description: "将任务拆分为多个子任务",
                        confidence: 0.6,
                        estimatedTime: nil,
                        requiresUserConfirmation: true,
                        configChanges: [
                            ConfigChange(
                                key: "enableTaskSplit",
                                oldValue: "\(configuration.enableTaskSplit)",
                                newValue: "true",
                                reason: "长任务拆分可降低单次超时风险",
                                isRevertible: true
                            )
                        ]
                    )
                ]
            )
        }
        
        // 网络问题
        if description.contains("network") || description.contains("connection") ||
           description.contains("网络") || description.contains("连接") {
            return ExecutionIssue(
                type: .networkIssue,
                description: "网络连接问题",
                severity: .medium,
                timestamp: Date(),
                context: [:],
                suggestedActions: [
                    RecoveryAction(
                        type: .waitAndRetry,
                        description: "等待 \(Int(configuration.networkRetryDelay))s 后重试",
                        confidence: 0.7,
                        estimatedTime: configuration.networkRetryDelay + context.duration,
                        requiresUserConfirmation: false,
                        configChanges: nil
                    )
                ]
            )
        }
        
        // Agent 失败
        return ExecutionIssue(
            type: .agentFailure,
            description: "Agent 执行失败: \(nsError.localizedDescription)",
            severity: .high,
            timestamp: Date(),
            context: ["agentID": context.agentID?.uuidString ?? "unknown"],
            suggestedActions: [
                RecoveryAction(
                    type: .switchAgent,
                    description: "尝试切换到备用 Agent",
                    confidence: 0.75,
                    estimatedTime: context.duration * 0.9,
                    requiresUserConfirmation: false,
                    configChanges: nil
                )
            ]
        )
    }
    
    // MARK: - 模式分析
    
    private func analyzeExecutionPatterns(_ snapshot: ExecutionSnapshot) -> [ExecutionIssue] {
        var issues: [ExecutionIssue] = []
        
        // 分析历史模式
        let relatedHistory = executionHistory.filter {
            $0.agentID == snapshot.agentID &&
            Date().timeIntervalSince($0.timestamp) < 3600  // 1小时内
        }
        
        // 检测频繁失败模式
        let recentFailures = relatedHistory.filter { $0.lastError != nil }
        if recentFailures.count >= 3 {
            let failureRate = Double(recentFailures.count) / Double(relatedHistory.count)
            if failureRate > 0.5 {
                let issue = ExecutionIssue(
                    type: .agentFailure,
                    description: "该 Agent 最近失败率 \(Int(failureRate * 100))%，建议切换",
                    severity: .high,
                    timestamp: Date(),
                    context: ["failureRate": "\(failureRate)"],
                    suggestedActions: [
                        RecoveryAction(
                            type: .switchAgent,
                            description: "切换到更稳定的 Agent",
                            confidence: 0.85,
                            estimatedTime: nil,
                            requiresUserConfirmation: false,
                            configChanges: [
                                ConfigChange(
                                    key: "preferredAgent",
                                    oldValue: snapshot.agentID?.uuidString ?? "unknown",
                                    newValue: "auto_select",
                                    reason: "当前 Agent 失败率过高",
                                    isRevertible: true
                                )
                            ]
                        )
                    ]
                )
                issues.append(issue)
            }
        }
        
        // 检测长时间执行模式
        if snapshot.duration > configuration.timeoutBase * 0.8 {
            let issue = ExecutionIssue(
                type: .resourceExhaustion,
                description: "任务执行时间接近超时限制，可能需要优化",
                severity: .medium,
                timestamp: Date(),
                context: ["duration": "\(snapshot.duration)"],
                suggestedActions: [
                    RecoveryAction(
                        type: .splitTask,
                        description: "拆分任务以减少单次执行时间",
                        confidence: 0.7,
                        estimatedTime: nil,
                        requiresUserConfirmation: true,
                        configChanges: nil
                    )
                ]
            )
            issues.append(issue)
        }
        
        return issues
    }
    
    // MARK: - 策略生成
    
    private func generateRecoveryStrategy(
        issues: [ExecutionIssue],
        snapshot: ExecutionSnapshot,
        availableAgents: [Agent],
        configAdjustments: [ConfigChange]
    ) -> RecoveryStrategy {
        
        // 根据问题类型确定策略
        let hasStreamInterrupted = issues.contains { $0.type == .streamInterrupted }
        let hasTimeout = issues.contains { $0.type == .timeout }
        let hasRetryExhausted = issues.contains { $0.type == .retryExhausted }
        let hasPartialResult = issues.contains { $0.type == .partialResult }
        
        // 收集所有建议动作
        var actions: [RecoveryAction] = []
        var fallbackChain: [RecoveryAction] = []
        
        for issue in issues {
            actions.append(contentsOf: issue.suggestedActions)
        }
        
        // 按置信度排序
        actions.sort { $0.confidence > $1.confidence }
        
        // 确定策略类型
        let strategy: RecoveryStrategy.StrategyType
        let description: String
        
        if hasRetryExhausted {
            strategy = .userAssistance
            description = "自动恢复次数已耗尽，需要用户协助"
        } else if hasPartialResult && hasStreamInterrupted {
            strategy = .checkpointBased
            description = "从检查点继续执行，保留已有进度"
        } else if hasTimeout {
            strategy = .exponentialBackoff
            description = "指数退避重试，逐步增加超时时间"
        } else if actions.contains(where: { $0.type == .switchAgent }) && availableAgents.count > 1 {
            strategy = .agentSwitch
            description = "切换到备用 Agent 执行"
        } else if snapshot.duration > 60 {
            strategy = .taskDecomposition
            description = "拆分任务为多个子任务"
        } else {
            strategy = .immediateRetry
            description = "立即重试"
        }
        
        // 计算调整后的超时
        let adjustedTimeout: TimeInterval?
        if hasTimeout {
            adjustedTimeout = configuration.timeoutBase * pow(configuration.timeoutMultiplier, Double(snapshot.retryCount + 1))
        } else {
            adjustedTimeout = nil
        }
        
        // 生成 fallback 链
        fallbackChain = [
            RecoveryAction(
                type: .switchAgent,
                description: "切换到本地回退",
                confidence: 0.6,
                estimatedTime: nil,
                requiresUserConfirmation: false,
                configChanges: nil
            ),
            RecoveryAction(
                type: .requestUserInput,
                description: "请求用户协助",
                confidence: 0.9,
                estimatedTime: nil,
                requiresUserConfirmation: true,
                configChanges: nil
            )
        ]
        
        return RecoveryStrategy(
            strategy: strategy,
            actions: Array(actions.prefix(3)),  // 最多3个主要动作
            fallbackChain: fallbackChain,
            maxRetries: configuration.maxRetries - snapshot.retryCount,
            adjustedTimeout: adjustedTimeout,
            description: description
        )
    }
    
    // MARK: - 辅助方法
    
    private func determineRootCause(_ issues: [ExecutionIssue]) -> String? {
        // 按严重程度排序
        let sorted = issues.sorted { 
            severityWeight($0.severity) > severityWeight($1.severity)
        }
        return sorted.first?.description
    }
    
    private func severityWeight(_ severity: ExecutionIssue.IssueSeverity) -> Int {
        switch severity {
        case .critical: return 4
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }
    
    private func suggestConfigAdjustments(
        for issue: ExecutionIssue,
        currentConfig: ExecutionConfiguration
    ) -> [ConfigChange] {
        var changes: [ConfigChange] = []
        
        switch issue.type {
        case .timeout:
            changes.append(ConfigChange(
                key: "timeoutBase",
                oldValue: "\(currentConfig.timeoutBase)",
                newValue: "\(currentConfig.timeoutBase * 1.5)",
                reason: "解决超时问题",
                isRevertible: true
            ))
            
        case .streamInterrupted:
            changes.append(ConfigChange(
                key: "streamTimeoutThreshold",
                oldValue: "\(currentConfig.streamTimeoutThreshold)",
                newValue: "\(currentConfig.streamTimeoutThreshold * 1.2)",
                reason: "减少流中断",
                isRevertible: true
            ))
            
        case .retryExhausted:
            changes.append(ConfigChange(
                key: "maxRetries",
                oldValue: "\(currentConfig.maxRetries)",
                newValue: "\(currentConfig.maxRetries + 1)",
                reason: "增加重试次数",
                isRevertible: true
            ))
            
        default:
            break
        }
        
        return changes
    }
    
    private func generateRetryExhaustedActions(
        _ snapshot: ExecutionSnapshot,
        availableAgents: [Agent]
    ) -> [RecoveryAction] {
        var actions: [RecoveryAction] = [
            RecoveryAction(
                type: .adjustStrategy,
                description: "调整执行策略",
                confidence: 0.7,
                estimatedTime: nil,
                requiresUserConfirmation: true,
                configChanges: [
                    ConfigChange(
                        key: "executionMode",
                        oldValue: "standard",
                        newValue: "conservative",
                        reason: "降低失败风险",
                        isRevertible: true
                    )
                ]
            )
        ]
        
        if availableAgents.count > 1 {
            actions.append(RecoveryAction(
                type: .switchAgent,
                description: "切换到备用 Agent",
                confidence: 0.75,
                estimatedTime: nil,
                requiresUserConfirmation: false,
                configChanges: nil
            ))
        }
        
        actions.append(RecoveryAction(
            type: .requestUserInput,
            description: "请求用户确认调优方案",
            confidence: 0.9,
            estimatedTime: nil,
            requiresUserConfirmation: true,
            configChanges: nil
        ))
        
        return actions
    }
    
    // MARK: - 公共 API
    
    /// 记录执行快照
    func recordSnapshot(_ snapshot: ExecutionSnapshot) {
        executionHistory.append(snapshot)
        
        // 清理过期历史
        let cutoff = Date().addingTimeInterval(-86400)  // 24小时
        executionHistory.removeAll { $0.timestamp < cutoff }
    }
    
    /// 应用配置调整
    func applyConfigChanges(_ changes: [ConfigChange]) {
        for change in changes {
            switch change.key {
            case "timeoutBase":
                if let value = Double(change.newValue) {
                    configuration.timeoutBase = value
                }
            case "maxRetries":
                if let value = Int(change.newValue) {
                    configuration.maxRetries = value
                }
            case "streamTimeoutThreshold":
                if let value = Double(change.newValue) {
                    configuration.streamTimeoutThreshold = value
                }
            default:
                break
            }
        }
    }
    
    /// 获取当前配置
    func currentConfiguration() -> ExecutionConfiguration {
        configuration
    }
    
    /// 更新配置
    func updateConfiguration(_ config: ExecutionConfiguration) {
        configuration = config
    }
}

/// 恢复模式（用于学习）
private struct RecoveryPattern: Codable {
    let issueType: ExecutionIssueType
    let strategy: RecoveryStrategy.StrategyType
    let successRate: Double
    let averageRecoveryTime: TimeInterval
    let usageCount: Int
}
