//
//  ExecutionJournalStore.swift
//  MacAssistant
//

import Foundation

final class ExecutionJournalStore {
    static let shared = ExecutionJournalStore()

    private struct PersistedJournal: Codable {
        let schemaVersion: Int
        let taskSessions: [AgentTaskSession]
        let savedAt: Date
    }

    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "macassistant.execution-journal", qos: .utility)
    private let journalURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directoryURL = appSupportURL
            .appendingPathComponent("MacAssistant", isDirectory: true)
            .appendingPathComponent("ExecutionJournal", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        journalURL = directoryURL.appendingPathComponent("task-sessions.json", isDirectory: false)
    }

    func loadTaskSessions() -> [AgentTaskSession] {
        guard let data = try? Data(contentsOf: journalURL),
              let journal = try? decoder.decode(PersistedJournal.self, from: data) else {
            return []
        }
        return journal.taskSessions.sorted { $0.updatedAt < $1.updatedAt }
    }

    func saveTaskSessions(_ sessions: [AgentTaskSession]) {
        let snapshot = sessions.sorted { $0.updatedAt < $1.updatedAt }
        let journal = PersistedJournal(schemaVersion: 1, taskSessions: snapshot, savedAt: Date())

        ioQueue.async { [encoder, journalURL] in
            do {
                let data = try encoder.encode(journal)
                try data.write(to: journalURL, options: .atomic)
            } catch {
                LogError("保存 ExecutionJournal 失败", error: error)
            }
        }
    }

    func clear() {
        ioQueue.async { [fileManager, journalURL] in
            do {
                if fileManager.fileExists(atPath: journalURL.path) {
                    try fileManager.removeItem(at: journalURL)
                }
            } catch {
                LogError("清理 ExecutionJournal 失败", error: error)
            }
        }
    }
}
