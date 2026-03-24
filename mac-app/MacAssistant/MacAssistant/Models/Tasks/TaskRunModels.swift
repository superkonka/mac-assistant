//
//  TaskRunModels.swift
//  MacAssistant
//
//  新任务系统运行模型
//

import Foundation

enum RunPhase: String, Codable, Equatable, CaseIterable {
    case scheduled = "scheduled"
    case queued = "queued"
    case running = "running"
    case paused = "paused"
    case waitingInput = "waiting_input"
    case retryWaiting = "retry_waiting"
    case succeeded = "succeeded"
    case failed = "failed"
    case cancelled = "cancelled"

    var isTerminal: Bool {
        self == .succeeded || self == .failed || self == .cancelled
    }

    var isActive: Bool {
        self == .queued || self == .running || self == .paused || self == .waitingInput || self == .retryWaiting
    }
}

struct TaskProgress: Codable, Equatable {
    var completedUnitCount: Int
    var totalUnitCount: Int
    var detail: String?

    static let empty = TaskProgress(completedUnitCount: 0, totalUnitCount: 0, detail: nil)
}

struct TaskOutput: Codable, Equatable {
    var summary: String?
}

struct TaskFailure: Codable, Equatable {
    var message: String
    var recordedAt: Date
}

struct TaskRun: Identifiable, Codable, Equatable {
    let id: String
    let definitionID: String
    let parentRunID: String?
    var phase: RunPhase
    var attempt: Int
    var scheduledAt: Date?
    var startedAt: Date?
    var finishedAt: Date?
    var nextRetryAt: Date?
    var progress: TaskProgress
    var output: TaskOutput
    var error: TaskFailure?
    var updatedAt: Date
    var executionTime: TimeInterval?
    
    // MARK: - Workflow 扩展（新增）
    var workflowState: WorkflowRunState?  // Workflow 类型任务专用

    init(
        id: String? = nil,
        definitionID: String,
        parentRunID: String? = nil,
        phase: RunPhase = .queued,
        attempt: Int = 0,
        scheduledAt: Date? = nil,
        workflowState: WorkflowRunState? = nil
    ) {
        self.id = id ?? UUID().uuidString
        self.definitionID = definitionID
        self.parentRunID = parentRunID
        self.phase = phase
        self.attempt = attempt
        self.scheduledAt = scheduledAt
        self.startedAt = nil
        self.finishedAt = nil
        self.nextRetryAt = nil
        self.progress = .empty
        self.output = TaskOutput(summary: nil)
        self.error = nil
        self.updatedAt = Date()
        self.executionTime = nil
        self.workflowState = workflowState
    }

    mutating func queueForExecution() {
        phase = .queued
        scheduledAt = nil
        nextRetryAt = nil
        updatedAt = Date()
    }

    mutating func start(incrementAttempt: Bool = false) {
        if attempt == 0 || incrementAttempt {
            attempt += 1
        }
        phase = .running
        startedAt = Date()
        updatedAt = Date()
        error = nil
    }

    mutating func pause() {
        phase = .paused
        updatedAt = Date()
    }

    mutating func waitForInput(message: String) {
        phase = .waitingInput
        error = TaskFailure(message: message, recordedAt: Date())
        updatedAt = Date()
    }

    mutating func succeed(result: String) {
        phase = .succeeded
        output = TaskOutput(summary: result)
        finishedAt = Date()
        updatedAt = Date()
        nextRetryAt = nil
        error = nil
        if let startedAt {
            executionTime = Date().timeIntervalSince(startedAt)
        }
    }

    mutating func fail(message: String) {
        phase = .failed
        error = TaskFailure(message: message, recordedAt: Date())
        finishedAt = Date()
        updatedAt = Date()
        if let startedAt {
            executionTime = Date().timeIntervalSince(startedAt)
        }
    }

    mutating func queueRetry(after seconds: Int, message: String) {
        phase = .retryWaiting
        nextRetryAt = Date().addingTimeInterval(TimeInterval(seconds))
        error = TaskFailure(message: message, recordedAt: Date())
        updatedAt = Date()
    }

    mutating func cancel(message: String = "已取消") {
        phase = .cancelled
        error = TaskFailure(message: message, recordedAt: Date())
        finishedAt = Date()
        updatedAt = Date()
    }
}
