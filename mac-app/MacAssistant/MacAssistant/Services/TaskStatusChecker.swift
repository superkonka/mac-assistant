//
//  TaskStatusChecker.swift
//  MacAssistant
//
//  方案B：任务状态查询服务 - 用户触发
//

import Foundation

/// 任务状态检查结果
struct TaskStatusCheckResult {
    let sessionID: String
    let status: TaskExecutionStatus
    let currentState: String
    let hasNewOutput: Bool
    let latestOutput: String?
    let suggestedAction: SuggestedUserAction
    let details: [String: Any]
}

/// 任务执行状态
enum TaskExecutionStatus: String {
    case running = "running"           // 仍在运行
    case completed = "completed"       // 已完成
    case stalled = "stalled"           // 卡住/无响应
    case error = "error"               // 出错
    case unknown = "unknown"           // 未知
}

/// 建议的用户操作
enum SuggestedUserAction: String {
    case wait = "wait"                     // 继续等待
    case checkAgain = "check_again"        // 稍后再次检查
    case continueTask = "continue"         // 继续处理
    case restart = "restart"               // 重新开始
    case manualCheck = "manual_check"      // 手动检查
    case noAction = "no_action"            // 无需操作
}

@MainActor
final class TaskStatusChecker {
    static let shared = TaskStatusChecker()
    
    private let openClawClient = OpenClawGatewayClient.shared
    private let executionAnalyzer = ExecutionAnalyzer.shared
    private let backgroundRecovery = BackgroundTaskRecoveryService.shared
    
    private init() {}
    
    // MARK: - 公共API
    
    /// 查询任务状态（方案B：用户触发）
    func checkTaskStatus(sessionID: String) async -> TaskStatusCheckResult {
        LogInfo("[TaskStatusChecker] 用户触发状态检查: session=\(sessionID)")
        
        // 1. 检查本地任务会话状态
        let localStatus = await checkLocalTaskStatus(sessionID: sessionID)
        
        // 2. 尝试从OpenClaw获取最新输出
        let openClawStatus = await checkOpenClawStatus(sessionID: sessionID)
        
        // 3. 分析执行历史
        let analysis = await analyzeExecutionHistory(sessionID: sessionID)
        
        // 4. 综合判断
        return synthesizeResult(
            sessionID: sessionID,
            localStatus: localStatus,
            openClawStatus: openClawStatus,
            analysis: analysis
        )
    }
    
    /// 获取任务的详细诊断报告
    func getDiagnosticReport(sessionID: String) async -> TaskDiagnosticReport {
        var sections: [DiagnosticSection] = []
        
        // 1. 本地状态
        let localStatus = await checkLocalTaskStatus(sessionID: sessionID)
        sections.append(DiagnosticSection(
            title: "本地状态",
            status: localStatus.exists ? .ok : .warning,
            details: localStatus.details
        ))
        
        // 2. OpenClaw连接状态
        let openClawStatus = await checkOpenClawStatus(sessionID: sessionID)
        sections.append(DiagnosticSection(
            title: "OpenClaw状态",
            status: openClawStatus.isConnected ? .ok : .error,
            details: openClawStatus.details
        ))
        
        // 3. 执行分析
        let analysis = await analyzeExecutionHistory(sessionID: sessionID)
        sections.append(DiagnosticSection(
            title: "执行分析",
            status: analysis.hasIssues ? .warning : .ok,
            details: analysis.details
        ))
        
        // 4. 后台恢复状态
        if let recoveryTask = backgroundRecovery.getTaskStatus(sessionID: sessionID) {
            sections.append(DiagnosticSection(
                title: "后台恢复",
                status: recoveryTask.state == "recovered" ? .ok : .info,
                details: [
                    "状态": recoveryTask.state,
                    "尝试次数": "\(recoveryTask.attempts)/\(recoveryTask.maxAttempts)"
                ]
            ))
        }
        
        return TaskDiagnosticReport(
            sessionID: sessionID,
            timestamp: Date(),
            overallStatus: calculateOverallStatus(sections),
            sections: sections
        )
    }
    
    // MARK: - 检查实现
    
    private func checkLocalTaskStatus(sessionID: String) async -> LocalStatusInfo {
        // 从CommandRunner获取任务会话信息
        // 这里简化处理
        return LocalStatusInfo(
            exists: true,
            lastUpdate: Date(),
            messageCount: 0,
            details: [
                "会话ID": sessionID,
                "最后更新": "刚刚"
            ]
        )
    }
    
    private func checkOpenClawStatus(sessionID: String) async -> OpenClawStatusInfo {
        do {
            // 尝试获取OpenClaw的会话状态
            // 实际应该调用OpenClaw API
            return OpenClawStatusInfo(
                isConnected: true,
                hasActiveSession: false,
                lastActivity: nil,
                details: [
                    "连接状态": "正常",
                    "活跃会话": "无"
                ]
            )
        } catch {
            return OpenClawStatusInfo(
                isConnected: false,
                hasActiveSession: false,
                lastActivity: nil,
                details: [
                    "连接状态": "异常",
                    "错误": error.localizedDescription
                ]
            )
        }
    }
    
    private func analyzeExecutionHistory(sessionID: String) async -> ExecutionAnalysisInfo {
        // 调用ExecutionAnalyzer分析执行历史
        return ExecutionAnalysisInfo(
            hasIssues: false,
            rootCause: nil,
            details: [
                "分析状态": "正常",
                "检测到问题": "无"
            ]
        )
    }
    
    private func synthesizeResult(
        sessionID: String,
        localStatus: LocalStatusInfo,
        openClawStatus: OpenClawStatusInfo,
        analysis: ExecutionAnalysisInfo
    ) -> TaskStatusCheckResult {
        
        // 根据各种状态综合判断
        let status: TaskExecutionStatus
        let suggestedAction: SuggestedUserAction
        let hasNewOutput: Bool
        
        if !openClawStatus.isConnected {
            status = .error
            suggestedAction = .manualCheck
            hasNewOutput = false
        } else if let recoveryTask = backgroundRecovery.getTaskStatus(sessionID: sessionID),
                  recoveryTask.state == "recovered",
                  let result = recoveryTask.recoveredResult {
            // 后台恢复成功
            status = .completed
            suggestedAction = .continueTask
            hasNewOutput = true
            
            return TaskStatusCheckResult(
                sessionID: sessionID,
                status: status,
                currentState: "后台自动恢复完成",
                hasNewOutput: hasNewOutput,
                latestOutput: result,
                suggestedAction: suggestedAction,
                details: [
                    "recovery_status": "success",
                    "auto_recovered": true
                ]
            )
        } else {
            // 默认情况
            status = .unknown
            suggestedAction = .checkAgain
            hasNewOutput = false
        }
        
        return TaskStatusCheckResult(
            sessionID: sessionID,
            status: status,
            currentState: status.rawValue,
            hasNewOutput: hasNewOutput,
            latestOutput: nil,
            suggestedAction: suggestedAction,
            details: [:]
        )
    }
    
    private func calculateOverallStatus(_ sections: [DiagnosticSection]) -> DiagnosticOverallStatus {
        let hasError = sections.contains { $0.status == .error }
        let hasWarning = sections.contains { $0.status == .warning }
        
        if hasError { return .error }
        if hasWarning { return .warning }
        return .ok
    }
    
    // MARK: - 用户操作建议
    
    func getActionDescription(_ action: SuggestedUserAction) -> String {
        switch action {
        case .wait:
            return "任务似乎仍在进行中，建议稍等片刻"
        case .checkAgain:
            return "请稍后再次检查状态"
        case .continueTask:
            return "发现可恢复的内容，点击「继续处理」查看"
        case .restart:
            return "建议重新开始任务"
        case .manualCheck:
            return "检测到异常，请手动检查相关服务状态"
        case .noAction:
            return "无需操作"
        }
    }
}

// MARK: - 辅助类型

struct LocalStatusInfo {
    let exists: Bool
    let lastUpdate: Date
    let messageCount: Int
    let details: [String: String]
}

struct OpenClawStatusInfo {
    let isConnected: Bool
    let hasActiveSession: Bool
    let lastActivity: Date?
    let details: [String: String]
}

struct ExecutionAnalysisInfo {
    let hasIssues: Bool
    let rootCause: String?
    let details: [String: String]
}

struct TaskDiagnosticReport {
    let sessionID: String
    let timestamp: Date
    let overallStatus: DiagnosticOverallStatus
    let sections: [DiagnosticSection]
}

struct DiagnosticSection {
    let title: String
    let status: DiagnosticStatus
    let details: [String: String]
}

enum DiagnosticStatus {
    case ok, warning, error, info
}

enum DiagnosticOverallStatus {
    case ok, warning, error
}
