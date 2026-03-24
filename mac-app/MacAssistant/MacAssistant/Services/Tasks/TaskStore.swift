//
//  TaskStore.swift
//  MacAssistant
//
//  新任务系统持久化存储
//

import Foundation

@MainActor
final class TaskStore {
    static let shared = TaskStore()

    private(set) var definitions: [TaskDefinition] = []
    private(set) var runs: [TaskRun] = []

    private var storageDirectoryURL: URL {
        let rootURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return rootURL.appendingPathComponent("TaskCenter", isDirectory: true)
    }

    private var definitionsURL: URL {
        storageDirectoryURL.appendingPathComponent("task_definitions.json")
    }

    private var runsURL: URL {
        storageDirectoryURL.appendingPathComponent("task_runs.json")
    }

    private init() {
        load()
    }

    func load() {
        try? FileManager.default.createDirectory(
            at: storageDirectoryURL,
            withIntermediateDirectories: true
        )

        definitions = loadFile([TaskDefinition].self, from: definitionsURL) ?? []
        runs = loadFile([TaskRun].self, from: runsURL) ?? []
    }

    func definition(id: String) -> TaskDefinition? {
        definitions.first { $0.id == id }
    }

    func run(id: String) -> TaskRun? {
        runs.first { $0.id == id }
    }

    func runs(for definitionID: String) -> [TaskRun] {
        runs
            .filter { $0.definitionID == definitionID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func upsert(definition: TaskDefinition) {
        if let index = definitions.firstIndex(where: { $0.id == definition.id }) {
            definitions[index] = definition
        } else {
            definitions.append(definition)
        }
        saveDefinitions()
    }

    func upsert(run: TaskRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
        saveRuns()
    }

    func removeDefinition(id: String) {
        definitions.removeAll { $0.id == id }
        runs.removeAll { $0.definitionID == id }
        saveDefinitions()
        saveRuns()
    }

    func replaceDefinitions(_ definitions: [TaskDefinition]) {
        self.definitions = definitions
        saveDefinitions()
    }

    func replaceRuns(_ runs: [TaskRun]) {
        self.runs = runs
        saveRuns()
    }

    private func saveDefinitions() {
        save(definitions, to: definitionsURL)
    }

    private func saveRuns() {
        save(runs, to: runsURL)
    }

    private func loadFile<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            print("Failed to load task store file: \(url.lastPathComponent), error: \(error)")
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url)
        } catch {
            print("Failed to save task store file: \(url.lastPathComponent), error: \(error)")
        }
    }
}
