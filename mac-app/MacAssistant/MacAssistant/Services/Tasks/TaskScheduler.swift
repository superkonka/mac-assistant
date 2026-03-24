//
//  TaskScheduler.swift
//  MacAssistant
//
//  新任务系统统一调度器
//

import Foundation

@MainActor
final class TaskScheduler {
    static let shared = TaskScheduler()

    var runsProvider: (() -> [TaskRun])?
    var onRunDue: ((String) -> Void)?

    private var timer: Timer?
    private var signaledRunIDs: Set<String> = []
    private let interval: TimeInterval = 5

    private init() {}

    func bootstrap() {
        guard timer == nil else { return }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.processDueRuns()
            }
        }

        processDueRuns()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        signaledRunIDs.removeAll()
    }

    func processDueRuns(now: Date = Date()) {
        guard let runsProvider else { return }

        let dueRuns = runsProvider().filter { run in
            switch run.phase {
            case .scheduled:
                return (run.scheduledAt ?? now) <= now
            case .retryWaiting:
                return (run.nextRetryAt ?? now) <= now
            default:
                return false
            }
        }

        for run in dueRuns where !signaledRunIDs.contains(run.id) {
            signaledRunIDs.insert(run.id)
            onRunDue?(run.id)
        }

        let activeIDs = Set(dueRuns.map(\.id))
        signaledRunIDs = signaledRunIDs.intersection(activeIDs)
    }

    func clearSignal(for runID: String) {
        signaledRunIDs.remove(runID)
    }
}
