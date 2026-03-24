//
//  WorkflowDraftStore.swift
//  MacAssistant
//
//  WorkflowDraft 草稿状态管理
//

import Foundation

@MainActor
final class WorkflowDraftStore: ObservableObject {
    static let shared = WorkflowDraftStore()
    
    @Published private(set) var drafts: [WorkflowDraft] = []
    
    private let fileManager = FileManager.default
    private let expirationDays = 7  // 草稿过期天数
    
    private var storageURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MacAssistant/WorkflowDrafts", isDirectory: true)
    }
    
    private init() {
        ensureStorageDirectory()
        loadDrafts()
        cleanExpiredDrafts()
    }
    
    // MARK: - 存储管理
    
    private func ensureStorageDirectory() {
        try? fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
    }
    
    private func draftURL(for id: String) -> URL {
        storageURL.appendingPathComponent("\(id).json")
    }
    
    // MARK: - CRUD 操作
    
    func save(_ draft: WorkflowDraft) throws {
        let url = draftURL(for: draft.id)
        let data = try JSONEncoder().encode(draft)
        try data.write(to: url)
        
        if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[index] = draft
        } else {
            drafts.append(draft)
        }
        
        LogInfo("[WorkflowDraftStore] 已保存草稿: \(draft.name) (\(draft.id))")
    }
    
    func delete(id: String) throws {
        let url = draftURL(for: id)
        try? fileManager.removeItem(at: url)
        drafts.removeAll { $0.id == id }
        LogInfo("[WorkflowDraftStore] 已删除草稿: \(id)")
    }
    
    func draft(id: String) -> WorkflowDraft? {
        drafts.first { $0.id == id }
    }
    
    // MARK: - 状态转换
    
    func markAsReady(id: String) throws {
        guard var draft = draft(id: id) else {
            throw WorkflowDraftError.draftNotFound
        }
        // 使用新的实例，因为 struct 是值类型
        let updatedDraft = WorkflowDraft(
            id: draft.id,
            name: draft.name,
            description: draft.description,
            originalInput: draft.originalInput,
            suggestedSteps: draft.suggestedSteps,
            missingSlots: draft.missingSlots,
            context: draft.context,
            status: .ready
        )
        try save(updatedDraft)
    }
    
    func markAsPublished(id: String, definitionID: String) throws {
        guard let draft = draft(id: id) else {
            throw WorkflowDraftError.draftNotFound
        }

        let updatedDraft = WorkflowDraft(
            id: draft.id,
            name: draft.name,
            description: draft.description,
            originalInput: draft.originalInput,
            suggestedSteps: draft.suggestedSteps,
            missingSlots: draft.missingSlots,
            context: draft.context,
            status: .published
        )
        try save(updatedDraft)
        LogInfo("[WorkflowDraftStore] 草稿已发布为 Definition: \(definitionID)")
    }

    func markAsApplied(id: String) throws {
        guard let draft = draft(id: id) else {
            throw WorkflowDraftError.draftNotFound
        }

        let updatedDraft = WorkflowDraft(
            id: draft.id,
            name: draft.name,
            description: draft.description,
            originalInput: draft.originalInput,
            suggestedSteps: draft.suggestedSteps,
            missingSlots: draft.missingSlots,
            context: draft.context,
            status: .appliedToRun
        )
        try save(updatedDraft)
    }
    
    func markAsDiscarded(id: String) throws {
        guard let draft = draft(id: id) else {
            throw WorkflowDraftError.draftNotFound
        }

        let updatedDraft = WorkflowDraft(
            id: draft.id,
            name: draft.name,
            description: draft.description,
            originalInput: draft.originalInput,
            suggestedSteps: draft.suggestedSteps,
            missingSlots: draft.missingSlots,
            context: draft.context,
            status: .discarded
        )
        try save(updatedDraft)
    }
    
    // MARK: - 查询
    
    func drafts(status: WorkflowDraftStatus) -> [WorkflowDraft] {
        drafts.filter { $0.status == status }
    }
    
    func draftsAwaitingClarification() -> [WorkflowDraft] {
        drafts.filter { $0.status == .clarifying && !$0.missingSlots.isEmpty }
    }

    func draftsReadyToPublish() -> [WorkflowDraft] {
        drafts.filter { $0.status == .ready }
    }

    func drafts(forRunID runID: String) -> [WorkflowDraft] {
        drafts.filter { $0.context?.runID == runID }
    }
    
    // MARK: - 过期清理
    
    func cleanExpiredDrafts() {
        let calendar = Calendar.current
        let now = Date()
        
        let expiredDrafts = drafts.filter { draft in
            guard let expirationDate = calendar.date(byAdding: .day, value: expirationDays, to: draft.createdAt) else {
                return false
            }
            return now > expirationDate && draft.status != .published
        }
        
        for draft in expiredDrafts {
            try? delete(id: draft.id)
        }
        
        if !expiredDrafts.isEmpty {
            LogInfo("[WorkflowDraftStore] 清理了 \(expiredDrafts.count) 个过期草稿")
        }
    }
    
    // MARK: - 加载
    
    private func loadDrafts() {
        guard let files = try? fileManager.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: nil) else {
            return
        }
        
        let decoder = JSONDecoder()
        drafts = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> WorkflowDraft? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(WorkflowDraft.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        
        LogInfo("[WorkflowDraftStore] 已加载 \(drafts.count) 个草稿")
    }
    
    // MARK: - 从 Candidate 创建
    
    func createFromCandidate(_ candidate: WorkflowCandidate, originalInput: String) throws -> WorkflowDraft {
        let steps = candidate.stepsPreview.map { stepName in
            WorkflowStepDef(name: stepName, kind: .action)
        }
        
        let draft = WorkflowDraft(
            name: candidate.name,
            description: candidate.description,
            originalInput: originalInput,
            suggestedSteps: steps,
            missingSlots: candidate.missingSlots,
            context: WorkflowDraftContext(
                purpose: .creation,
                definitionID: nil,
                runID: nil,
                stepID: nil
            ),
            status: candidate.missingSlots.isEmpty ? .ready : .clarifying
        )
        
        try save(draft)
        return draft
    }
    
    // MARK: - 统计
    
    var count: Int { drafts.count }
    
    func statistics() -> (total: Int, draft: Int, clarifying: Int, ready: Int, published: Int) {
        let draftCount = drafts.filter { $0.status == .draft }.count
        let clarifyingCount = drafts.filter { $0.status == .clarifying }.count
        let readyCount = drafts.filter { $0.status == .ready }.count
        let publishedCount = drafts.filter { $0.status == .published }.count
        return (total: drafts.count, draft: draftCount, clarifying: clarifyingCount, ready: readyCount, published: publishedCount)
    }
}

// MARK: - Error

enum WorkflowDraftError: Error {
    case draftNotFound
    case invalidTransition
    case saveFailed
    
    var localizedDescription: String {
        switch self {
        case .draftNotFound:
            return "草稿不存在"
        case .invalidTransition:
            return "无效的状态转换"
        case .saveFailed:
            return "保存失败"
        }
    }
}
