//
//  ColdStorage.swift
//  冷数据层 - JSON文件归档，长期存储
//

import Foundation

/// 冷数据层：长期归档存储，按需加载
class ColdStorage {
    private let archiveDirectory: URL
    
    init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        archiveDirectory = documentsPath.appendingPathComponent("MacAssistant/Archive")
        
        try? FileManager.default.createDirectory(
            at: archiveDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
    
    // MARK: - 消息归档
    
    func archiveMessage(_ message: ChatMessage, metadata: StorageMetadata?) {
        let monthKey = monthKeyFromDate(message.timestamp)
        var archive = loadArchive(for: monthKey)
        
        archive.messages.append(ArchivedMessage(
            id: message.id,
            role: message.role,
            content: message.content,
            timestamp: message.timestamp,
            metadata: metadata,
            archivedAt: Date()
        ))
        
        saveArchive(archive, for: monthKey)
    }
    
    func loadArchivedMessages(from startDate: Date, to endDate: Date) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        
        let months = monthsBetween(start: startDate, end: endDate)
        for month in months {
            let archive = loadArchive(for: month)
            for archived in archive.messages {
                if let timestamp = archived.timestamp,
                   timestamp >= startDate && timestamp <= endDate {
                    messages.append(ChatMessage(
                        id: archived.id,
                        role: archived.role,
                        content: archived.content,
                        timestamp: timestamp
                    ))
                }
            }
        }
        
        return messages.sorted { $0.timestamp < $1.timestamp }
    }
    
    // MARK: - 技能进化历史
    
    func saveSkillEvolution(_ skill: Skill) {
        let evolution = SkillEvolutionRecord(
            skillId: skill.id,
            version: skill.version,
            name: skill.name,
            triggers: skill.triggers,
            commandTemplate: skill.commandTemplate,
            timestamp: Date(),
            reason: skill.lastEvolutionReason
        )
        
        var history = loadSkillEvolutionHistory(skillId: skill.id)
        history.append(evolution)
        
        saveSkillEvolutionHistory(history, skillId: skill.id)
    }
    
    func getSkillEvolutionHistory(skillId: String) -> [SkillEvolutionRecord] {
        return loadSkillEvolutionHistory(skillId: skillId)
    }
    
    // MARK: - 知识库管理
    
    func saveToKnowledgeBase(_ knowledge: KnowledgeItem) {
        var knowledgeBase = loadKnowledgeBase()
        
        // 检查是否已存在相似知识
        if let existingIndex = knowledgeBase.firstIndex(where: { $0.topic == knowledge.topic }) {
            // 更新版本
            var updated = knowledge
            updated.version = knowledgeBase[existingIndex].version + 1
            knowledgeBase[existingIndex] = updated
        } else {
            knowledgeBase.append(knowledge)
        }
        
        saveKnowledgeBase(knowledgeBase)
    }
    
    func searchKnowledgeBase(query: String) -> [KnowledgeItem] {
        let knowledgeBase = loadKnowledgeBase()
        let lowerQuery = query.lowercased()
        
        return knowledgeBase.filter { item in
            item.topic.lowercased().contains(lowerQuery) ||
            item.content.lowercased().contains(lowerQuery) ||
            item.keywords.contains { $0.lowercased().contains(lowerQuery) }
        }.sorted { $0.relevanceScore > $1.relevanceScore }
    }
    
    // MARK: - 数据导出
    
    func exportAllData() -> URL? {
        let exportDirectory = archiveDirectory.appendingPathComponent("Export_\(dateString())")
        try? FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        
        // 导出消息
        let allMessages = loadAllArchivedMessages()
        let messagesData = try? JSONEncoder().encode(allMessages)
        try? messagesData?.write(to: exportDirectory.appendingPathComponent("messages.json"))
        
        // 导出知识库
        let knowledgeBase = loadKnowledgeBase()
        let knowledgeData = try? JSONEncoder().encode(knowledgeBase)
        try? knowledgeData?.write(to: exportDirectory.appendingPathComponent("knowledge.json"))
        
        return exportDirectory
    }
    
    // MARK: - 私有方法
    
    private func loadArchive(for monthKey: String) -> MonthlyArchive {
        let url = archiveDirectory.appendingPathComponent("messages_\(monthKey).json")
        
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(MonthlyArchive.self, from: data) else {
            return MonthlyArchive(month: monthKey, messages: [])
        }
        
        return archive
    }
    
    private func saveArchive(_ archive: MonthlyArchive, for monthKey: String) {
        let url = archiveDirectory.appendingPathComponent("messages_\(monthKey).json")
        
        if let data = try? JSONEncoder().encode(archive) {
            try? data.write(to: url)
        }
    }
    
    private func loadSkillEvolutionHistory(skillId: String) -> [SkillEvolutionRecord] {
        let url = archiveDirectory.appendingPathComponent("skill_\(skillId)_history.json")
        
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode([SkillEvolutionRecord].self, from: data) else {
            return []
        }
        
        return history
    }
    
    private func saveSkillEvolutionHistory(_ history: [SkillEvolutionRecord], skillId: String) {
        let url = archiveDirectory.appendingPathComponent("skill_\(skillId)_history.json")
        
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: url)
        }
    }
    
    private func loadKnowledgeBase() -> [KnowledgeItem] {
        let url = archiveDirectory.appendingPathComponent("knowledge_base.json")
        
        guard let data = try? Data(contentsOf: url),
              let knowledge = try? JSONDecoder().decode([KnowledgeItem].self, from: data) else {
            return []
        }
        
        return knowledge
    }
    
    private func saveKnowledgeBase(_ knowledge: [KnowledgeItem]) {
        let url = archiveDirectory.appendingPathComponent("knowledge_base.json")
        
        if let data = try? JSONEncoder().encode(knowledge) {
            try? data.write(to: url)
        }
    }
    
    private func loadAllArchivedMessages() -> [ArchivedMessage] {
        var allMessages: [ArchivedMessage] = []
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: nil)
            for file in files where file.lastPathComponent.hasPrefix("messages_") {
                if let data = try? Data(contentsOf: file),
                   let archive = try? JSONDecoder().decode(MonthlyArchive.self, from: data) {
                    allMessages.append(contentsOf: archive.messages)
                }
            }
        } catch {
            print("加载归档消息失败: \(error)")
        }
        
        return allMessages
    }
    
    private func monthKeyFromDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }
    
    private func monthsBetween(start: Date, end: Date) -> [String] {
        var months: [String] = []
        let calendar = Calendar.current
        var current = start
        
        while current <= end {
            months.append(monthKeyFromDate(current))
            current = calendar.date(byAdding: .month, value: 1, to: current) ?? end
        }
        
        return months
    }
    
    private func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - 归档数据结构

struct MonthlyArchive: Codable {
    let month: String
    var messages: [ArchivedMessage]
}

struct ArchivedMessage: Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date?
    let metadata: StorageMetadata?
    let archivedAt: Date
}

struct SkillEvolutionRecord: Codable {
    let skillId: String
    let version: Int
    let name: String
    let triggers: [String]
    let commandTemplate: String
    let timestamp: Date
    let reason: String?
}

struct KnowledgeItem: Codable {
    let id: UUID
    var topic: String
    var content: String
    var keywords: [String]
    var sourceMessageIds: [UUID]
    var createdAt: Date
    var updatedAt: Date
    var version: Int
    var relevanceScore: Double
}
