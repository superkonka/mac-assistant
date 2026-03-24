//
//  WorkflowDefinitionStore.swift
//  MacAssistant
//
//  WorkflowDefinition 独立存储管理
//

import Foundation

@MainActor
final class WorkflowDefinitionStore: ObservableObject {
    static let shared = WorkflowDefinitionStore()
    
    @Published private(set) var definitions: [WorkflowDefinition] = []
    
    private let fileManager = FileManager.default
    private var storageURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MacAssistant/WorkflowDefinitions", isDirectory: true)
    }
    
    private init() {
        ensureStorageDirectory()
        loadDefinitions()
    }
    
    // MARK: - 存储管理
    
    private func ensureStorageDirectory() {
        try? fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
    }
    
    private func definitionURL(for id: String) -> URL {
        storageURL.appendingPathComponent("\(id).json")
    }
    
    // MARK: - CRUD 操作
    
    func save(_ definition: WorkflowDefinition) throws {
        let url = definitionURL(for: definition.id)
        let data = try JSONEncoder().encode(definition)
        try data.write(to: url)
        
        // 更新内存缓存
        if let index = definitions.firstIndex(where: { $0.id == definition.id }) {
            definitions[index] = definition
        } else {
            definitions.append(definition)
        }
        
        LogInfo("[WorkflowDefinitionStore] 已保存: \(definition.name) (\(definition.id))")
    }
    
    func delete(id: String) throws {
        let url = definitionURL(for: id)
        try? fileManager.removeItem(at: url)
        definitions.removeAll { $0.id == id }
        LogInfo("[WorkflowDefinitionStore] 已删除: \(id)")
    }
    
    func definition(id: String) -> WorkflowDefinition? {
        definitions.first { $0.id == id }
    }
    
    func definition(name: String) -> WorkflowDefinition? {
        definitions.first { $0.name.lowercased() == name.lowercased() }
    }
    
    // MARK: - 查询
    
    func definitions(tag: String) -> [WorkflowDefinition] {
        definitions.filter { $0.tags.contains(tag) }
    }
    
    func definitions(containing keyword: String) -> [WorkflowDefinition] {
        let lowercased = keyword.lowercased()
        return definitions.filter {
            $0.name.lowercased().contains(lowercased) ||
            $0.description.lowercased().contains(lowercased)
        }
    }
    
    func templates() -> [WorkflowDefinition] {
        definitions.filter { $0.isTemplate }
    }
    
    // MARK: - 加载
    
    private func loadDefinitions() {
        guard let files = try? fileManager.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: nil) else {
            return
        }
        
        let decoder = JSONDecoder()
        definitions = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> WorkflowDefinition? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(WorkflowDefinition.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        
        LogInfo("[WorkflowDefinitionStore] 已加载 \(definitions.count) 个定义")
    }
    
    // MARK: - 从 Draft 创建
    
    func createFromDraft(_ draft: WorkflowDraft, bindings: [WorkflowBinding] = []) throws -> WorkflowDefinition {
        // suggestedSteps 已经是 [WorkflowStepDef]，直接使用或转换
        let steps = draft.suggestedSteps.isEmpty ? [] : draft.suggestedSteps
        
        let definition = WorkflowDefinition(
            name: draft.name,
            description: draft.description,
            steps: steps,
            bindings: bindings,
            tags: ["from-draft"]
        )
        
        try save(definition)
        return definition
    }
    
    // MARK: - 统计
    
    var count: Int { definitions.count }
    
    func statistics() -> (total: Int, templates: Int, active: Int) {
        let templates = definitions.filter { $0.isTemplate }.count
        return (total: definitions.count, templates: templates, active: definitions.count - templates)
    }
}
