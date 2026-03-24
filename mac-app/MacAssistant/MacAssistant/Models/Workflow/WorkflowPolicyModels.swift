//
//  WorkflowPolicyModels.swift
//  MacAssistant
//
//  Workflow 策略模型
//

import Foundation

// MARK: - Approval Policy

/// 审批策略
struct ApprovalPolicy: Codable, Equatable {
    let requiresApproval: Bool                  // 是否需要审批
    let approvalSteps: [String]                 // 哪些步骤需要审批（step ID）
    let autoApproveFirstN: Int                  // 前 N 次自动通过
    let highRiskActions: [String]               // 高风险操作列表
    
    static let `default` = ApprovalPolicy(
        requiresApproval: false,
        approvalSteps: [],
        autoApproveFirstN: 0,
        highRiskActions: ["send", "delete", "modify"]
    )
    
    static let always = ApprovalPolicy(
        requiresApproval: true,
        approvalSteps: [],
        autoApproveFirstN: 0,
        highRiskActions: []
    )
    
    func needsApproval(for step: WorkflowStepDef, runCount: Int) -> Bool {
        if !requiresApproval { return false }
        if runCount < autoApproveFirstN { return false }
        if approvalSteps.isEmpty { return step.requiresApproval }
        return approvalSteps.contains(step.id)
    }
}

// MARK: - Reflection Policy

/// 反思策略
struct ReflectionPolicy: Codable, Equatable {
    let enabled: Bool                           // 是否启用反思
    let interval: TimeInterval                  // 反思间隔（秒）
    let triggers: [ReflectionTrigger]           // 触发条件
    let maxReflectionsPerDay: Int               // 每日最大反思次数
    
    enum ReflectionTrigger: String, Codable, Equatable {
        case scheduled          // 定时触发
        case stepCompleted      // 步骤完成
        case stepFailed         // 步骤失败
        case externalEvent      // 外部事件
        case userInactive       // 用户长时间未操作
    }
    
    static let `default` = ReflectionPolicy(
        enabled: true,
        interval: 900,  // 15分钟
        triggers: [.scheduled, .stepFailed],
        maxReflectionsPerDay: 100
    )
    
    static let aggressive = ReflectionPolicy(
        enabled: true,
        interval: 300,  // 5分钟
        triggers: [.scheduled, .stepCompleted, .stepFailed, .externalEvent],
        maxReflectionsPerDay: 500
    )
    
    static let passive = ReflectionPolicy(
        enabled: false,
        interval: 3600,  // 1小时
        triggers: [.stepFailed],
        maxReflectionsPerDay: 10
    )
}

// MARK: - Reminder Policy

/// 提醒策略
struct ReminderPolicy: Codable, Equatable {
    let enabled: Bool                           // 是否启用提醒
    let maxReminders: Int                       // 最大提醒次数
    let reminderIntervals: [TimeInterval]       // 提醒间隔（秒）
    let quietHours: QuietHours?                 // 静默时段
    let escalationEnabled: Bool                 // 是否允许升级
    
    struct QuietHours: Codable, Equatable {
        let startHour: Int      // 0-23
        let endHour: Int        // 0-23
        
        func contains(_ date: Date) -> Bool {
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: date)
            if startHour <= endHour {
                return hour >= startHour && hour < endHour
            } else {
                return hour >= startHour || hour < endHour
            }
        }
    }
    
    static let `default` = ReminderPolicy(
        enabled: true,
        maxReminders: 3,
        reminderIntervals: [300, 900, 1800],  // 5分钟、15分钟、30分钟
        quietHours: QuietHours(startHour: 23, endHour: 8),
        escalationEnabled: true
    )
    
    static let never = ReminderPolicy(
        enabled: false,
        maxReminders: 0,
        reminderIntervals: [],
        quietHours: nil,
        escalationEnabled: false
    )
    
    /// 获取第 N 次提醒的间隔
    func interval(for reminderIndex: Int) -> TimeInterval? {
        guard enabled, reminderIndex < maxReminders else { return nil }
        if reminderIndex < reminderIntervals.count {
            return reminderIntervals[reminderIndex]
        }
        return reminderIntervals.last
    }
}
