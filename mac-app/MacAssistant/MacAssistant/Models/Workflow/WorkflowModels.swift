//
//  WorkflowModels.swift
//  MacAssistant
//
//  Workflow 核心模型定义
//

import Foundation

// MARK: - Workflow Definition

/// Workflow 定义 - 长期稳定的业务做法
struct WorkflowDefinition: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let createdAt: Date
    var updatedAt: Date
    
    // 步骤和绑定
    let steps: [WorkflowStepDef]
    let bindings: [WorkflowBinding]
    
    // 策略
    let approvalPolicy: ApprovalPolicy
    let reflectionPolicy: ReflectionPolicy
    let reminderPolicy: ReminderPolicy
    
    // 元数据
    let tags: [String]
    let isTemplate: Bool
    let templateID: String?
    
    init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        steps: [WorkflowStepDef] = [],
        bindings: [WorkflowBinding] = [],
        approvalPolicy: ApprovalPolicy = .default,
        reflectionPolicy: ReflectionPolicy = .default,
        reminderPolicy: ReminderPolicy = .default,
        tags: [String] = [],
        isTemplate: Bool = false,
        templateID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = Date()
        self.updatedAt = Date()
        self.steps = steps
        self.bindings = bindings
        self.approvalPolicy = approvalPolicy
        self.reflectionPolicy = reflectionPolicy
        self.reminderPolicy = reminderPolicy
        self.tags = tags
        self.isTemplate = isTemplate
        self.templateID = templateID
    }
}

// MARK: - Workflow Step

/// Workflow 步骤
struct WorkflowStepDef: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let kind: WorkflowStepKind
    let bindingID: String?              // 引用的 WorkflowBinding
    let nextStepID: String?             // 下一步（nil 表示结束）
    let onFailureStepID: String?        // 失败时跳转的步骤
    let timeout: TimeInterval?          // 超时时间（秒）
    let requiresApproval: Bool          // 是否需要人工审批
    
    init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        kind: WorkflowStepKind,
        bindingID: String? = nil,
        nextStepID: String? = nil,
        onFailureStepID: String? = nil,
        timeout: TimeInterval? = 300,
        requiresApproval: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
        self.bindingID = bindingID
        self.nextStepID = nextStepID
        self.onFailureStepID = onFailureStepID
        self.timeout = timeout
        self.requiresApproval = requiresApproval
    }
}

/// Workflow 步骤类型
enum WorkflowStepKind: String, Codable, Equatable {
    case action         // 执行动作
    case decision       // 条件判断
    case wait           // 等待事件/时间
    case parallel       // 并行执行
    case loop           // 循环
    case approval       // 人工审批
    case notification   // 发送通知
}

// MARK: - Workflow Binding

/// Workflow 能力绑定 - 引用外部 Skill/Service/Tool
struct WorkflowBinding: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let kind: WorkflowBindingKind
    let targetID: String              // Skill/Service/Tool 的 ID
    let inputMapping: [String: String] // 参数映射
    let outputMapping: [String: String] // 输出映射
    
    init(
        id: String = UUID().uuidString,
        name: String,
        kind: WorkflowBindingKind,
        targetID: String,
        inputMapping: [String: String] = [:],
        outputMapping: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.targetID = targetID
        self.inputMapping = inputMapping
        self.outputMapping = outputMapping
    }
}

/// Workflow 绑定类型
enum WorkflowBindingKind: String, Codable, Equatable {
    case skill          // 原子 Skill
    case service        // MCP Service
    case browser        // Browser 操作
    case agent          // Agent 调用
    case system         // 系统操作
}

// MARK: - Workflow Draft

/// Workflow 草稿 - 创建过程中的过渡态
struct WorkflowDraft: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let originalInput: String
    let suggestedSteps: [WorkflowStepDef]
    let missingSlots: [PlanningSlot]
    let context: WorkflowDraftContext?
    var status: WorkflowDraftStatus
    let createdAt: Date
    var updatedAt: Date
    
    init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        originalInput: String,
        suggestedSteps: [WorkflowStepDef] = [],
        missingSlots: [PlanningSlot] = [],
        context: WorkflowDraftContext? = nil,
        status: WorkflowDraftStatus = .draft
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.originalInput = originalInput
        self.suggestedSteps = suggestedSteps
        self.missingSlots = missingSlots
        self.context = context
        self.status = status
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

struct WorkflowDraftContext: Codable, Equatable {
    let purpose: WorkflowDraftPurpose
    let definitionID: String?
    let runID: String?
    let stepID: String?
}

enum WorkflowDraftPurpose: String, Codable, Equatable {
    case creation
    case replan
}

enum WorkflowDraftStatus: String, Codable, Equatable {
    case draft          // 草稿
    case clarifying     // 等待澄清
    case ready          // 可发布
    case published      // 已发布为 Definition
    case appliedToRun   // 已应用到运行中的 workflow
    case discarded      // 已放弃
}

// MARK: - Workflow Spec

/// Workflow 规格 - 用于 TaskDefinition 的 workflow 配置
struct WorkflowSpec: Codable, Equatable {
    let definitionID: String                    // 关联的 WorkflowDefinition ID
    let bindings: [WorkflowBinding]             // 运行时绑定
    let initialContext: [String: String]        // 初始上下文
    let executionMode: WorkflowExecutionMode    // 执行模式
    
    enum WorkflowExecutionMode: String, Codable, Equatable {
        case sequential     // 顺序执行
        case parallel       // 并行执行
        case interactive    // 交互式（每步需确认）
    }
}
