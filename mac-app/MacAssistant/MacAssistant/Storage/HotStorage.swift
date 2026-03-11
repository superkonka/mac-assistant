//
//  HotStorage.swift
//  热数据层 - UserDefaults，当前会话活跃数据
//

import Foundation

/// 热数据层：存储当前会话的活跃数据，访问速度最快
class HotStorage {
    private let defaults = UserDefaults.standard
    private let messagesKey = "hot_messages"
    private let activeSkillsKey = "hot_active_skills"
    private let maxMessages = 80
    
    // MARK: - 消息存储
    
    func appendMessage(_ message: ChatMessage) {
        let messages = normalizeMessages(getMessages() + [message], limit: maxMessages)
        saveMessages(messages)
    }
    
    func getMessages() -> [ChatMessage] {
        guard let data = defaults.data(forKey: messagesKey),
              let messages = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return []
        }
        return normalizeMessages(messages)
    }

    func replaceMessages(_ messages: [ChatMessage]) {
        saveMessages(normalizeMessages(messages, limit: maxMessages))
    }
    
    func trimTo(limit: Int) {
        let messages = normalizeMessages(getMessages(), limit: limit)
        saveMessages(messages)
    }
    
    func search(query: String) -> [ChatMessage] {
        let messages = getMessages()
        let lowerQuery = query.lowercased()
        return messages.filter { $0.content.lowercased().contains(lowerQuery) }
    }
    
    private func saveMessages(_ messages: [ChatMessage]) {
        if let data = try? JSONEncoder().encode(messages) {
            defaults.set(data, forKey: messagesKey)
        }
    }

    private func normalizeMessages(_ messages: [ChatMessage], limit: Int? = nil) -> [ChatMessage] {
        var latestByID: [UUID: ChatMessage] = [:]
        for message in messages {
            latestByID[message.id] = message
        }

        let sorted = latestByID.values.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.timestamp < rhs.timestamp
        }

        if let limit, sorted.count > limit {
            return Array(sorted.suffix(limit))
        }
        return sorted
    }
    
    // MARK: - 活跃技能管理
    
    func getActiveSkills() -> [Skill] {
        guard let data = defaults.data(forKey: activeSkillsKey),
              let skills = try? JSONDecoder().decode([Skill].self, from: data) else {
            return []
        }
        return skills
    }
    
    func touchSkill(_ skillId: String) {
        var activeSkills = getActiveSkills()
        
        // 移动到最前面（LRU）
        activeSkills.removeAll { $0.id == skillId }
        
        // 创建或更新技能活跃记录
        let skill = Skill(
            id: skillId,
            name: "",
            triggers: [],
            commandTemplate: "",
            priority: .normal,
            lastUsed: Date()
        )
        activeSkills.insert(skill, at: 0)
        
        // 只保留最近10个活跃技能
        if activeSkills.count > 10 {
            activeSkills = Array(activeSkills.prefix(10))
        }
        
        if let data = try? JSONEncoder().encode(activeSkills) {
            defaults.set(data, forKey: activeSkillsKey)
        }
    }
    
    func clear() {
        defaults.removeObject(forKey: messagesKey)
        defaults.removeObject(forKey: activeSkillsKey)
    }
}
