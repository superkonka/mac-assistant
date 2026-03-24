//
//  TaskScheduleModels.swift
//  MacAssistant
//
//  新任务系统调度模型
//

import Foundation

enum TaskTriggerKind: String, Codable, Equatable, CaseIterable {
    case manual = "manual"
    case once = "once"
    case delay = "delay"
    case recurring = "recurring"
    case event = "event"
}

struct RecurrenceRule: Codable, Equatable {
    var intervalSeconds: Int
}

struct TaskTrigger: Codable, Equatable {
    var kind: TaskTriggerKind
    var scheduledAt: Date?
    var delaySeconds: Int?
    var recurrenceRule: RecurrenceRule?
    var eventName: String?

    static let manual = TaskTrigger(kind: .manual)

    static func once(at date: Date) -> TaskTrigger {
        TaskTrigger(kind: .once, scheduledAt: date)
    }

    static func delay(seconds: Int) -> TaskTrigger {
        TaskTrigger(kind: .delay, delaySeconds: seconds)
    }

    static func recurring(every seconds: Int) -> TaskTrigger {
        TaskTrigger(
            kind: .recurring,
            recurrenceRule: RecurrenceRule(intervalSeconds: seconds)
        )
    }

    static func event(_ name: String) -> TaskTrigger {
        TaskTrigger(kind: .event, eventName: name)
    }

    init(
        kind: TaskTriggerKind,
        scheduledAt: Date? = nil,
        delaySeconds: Int? = nil,
        recurrenceRule: RecurrenceRule? = nil,
        eventName: String? = nil
    ) {
        self.kind = kind
        self.scheduledAt = scheduledAt
        self.delaySeconds = delaySeconds
        self.recurrenceRule = recurrenceRule
        self.eventName = eventName
    }

    func nextRunDate(from referenceDate: Date = Date()) -> Date? {
        switch kind {
        case .manual, .event:
            return nil
        case .once:
            return scheduledAt
        case .delay:
            guard let delaySeconds else { return nil }
            return referenceDate.addingTimeInterval(TimeInterval(delaySeconds))
        case .recurring:
            guard let recurrenceRule else { return nil }
            return referenceDate.addingTimeInterval(TimeInterval(recurrenceRule.intervalSeconds))
        }
    }
}

struct RetryBackoff: Codable, Equatable {
    var initialDelaySeconds: Int
    var multiplier: Double
    var maxDelaySeconds: Int

    static let standard = RetryBackoff(
        initialDelaySeconds: 1,
        multiplier: 2,
        maxDelaySeconds: 300
    )

    func delaySeconds(for attempt: Int) -> Int {
        guard attempt > 1 else { return initialDelaySeconds }

        let steppedDelay = Double(initialDelaySeconds) * pow(multiplier, Double(attempt - 1))
        return min(Int(steppedDelay.rounded()), maxDelaySeconds)
    }
}

struct TaskPolicy: Codable, Equatable {
    var maxRetries: Int
    var retryBackoff: RetryBackoff
    var timeoutSeconds: Int?
    var dedupKey: String?
    var concurrencyKey: String?
    var notifyOnSuccess: Bool
    var notifyOnFailure: Bool

    static let `default` = TaskPolicy(
        maxRetries: 3,
        retryBackoff: .standard,
        timeoutSeconds: nil,
        dedupKey: nil,
        concurrencyKey: nil,
        notifyOnSuccess: true,
        notifyOnFailure: true
    )
}
