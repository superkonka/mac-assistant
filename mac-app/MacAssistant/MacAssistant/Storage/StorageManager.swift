//
//  StorageManager.swift
//  分层存储管理器
//

import Foundation
import SQLite3

// MARK: - 数据层级定义

enum StorageTier {
    case hot      // UserDefaults - 当前会话、活跃数据
    case warm     // SQLite - 短期历史、技能库
    case cold     // JSON文件 - 长期归档、蒸馏知识
    case archive  // 按需加载 - 非常老的数据
}

enum DataPriority: Int, Codable {
    case critical = 0   // 关键技能、重要结论
    case high = 1       // 常用技能、近期对话
    case normal = 2     // 普通对话
    case low = 3        // 临时内容、可丢弃
}

enum DataLifetime: String, Codable {
    case session = "session"      // 当前会话
    case shortTerm = "shortTerm"  // 7天
    case mediumTerm = "mediumTerm" // 30天
    case longTerm = "longTerm"    // 永久
}

// MARK: - 存储元数据

struct StorageMetadata: Codable {
    let timestamp: Date
    let priority: DataPriority
    let lifetime: DataLifetime
    let accessCount: Int
    let lastAccess: Date
    let tags: [String]
}

// MARK: - 分层存储管理器

class StorageManager {
    static let shared = StorageManager()
    
    // 各层存储
    private let hotStorage = HotStorage()
    private let warmStorage = WarmStorage()
    private let coldStorage = ColdStorage()
    
    // 数据蒸馏器
    private let distiller = ContentDistiller()
    
    // 自动维护定时器
    private var maintenanceTimer: Timer?
    
    private init() {
        setupMaintenance()
    }
    
    // MARK: - 保存数据（智能路由）
    
    func saveMessage(_ message: ChatMessage, context: ConversationContext? = nil) {
        let priority = calculatePriority(for: message, context: context)
        let lifetime = determineLifetime(for: message, priority: priority)
        
        // 1. 先保存到热数据层（立即访问）
        hotStorage.appendMessage(message)
        
        // 2. 高优先级数据同时进行蒸馏
        if priority == .critical || priority == .high {
            if let distilled = distiller.distill(message, context: context) {
                warmStorage.saveDistilledContent(distilled)
            }
        }
        
        // 3. 温数据层存储（完整对话）
        warmStorage.saveMessage(message, metadata: StorageMetadata(
            timestamp: Date(),
            priority: priority,
            lifetime: lifetime,
            accessCount: 1,
            lastAccess: Date(),
            tags: extractTags(from: message)
        ))
        
        // 4. 关键数据归档到冷存储
        if priority == .critical {
            coldStorage.archiveMessage(message, metadata: nil)
        }
    }
    
    // MARK: - 读取数据（智能检索）
    
    func getRecentMessages(limit: Int = 50) -> [ChatMessage] {
        // 优先从热存储读取
        let hotMessages = hotStorage.getMessages()
        if hotMessages.count >= limit {
            return Array(hotMessages.prefix(limit))
        }
        
        // 补充从温存储读取
        let remaining = limit - hotMessages.count
        let warmMessages = warmStorage.getRecentMessages(limit: remaining)
        
        return hotMessages + warmMessages
    }
    
    func searchMessages(query: String) -> [ChatMessage] {
        // 并行搜索各层
        let hotResults = hotStorage.search(query: query)
        let warmResults = warmStorage.search(query: query)
        
        // 合并并去重
        var seenIDs = Set<UUID>()
        var results: [ChatMessage] = []
        
        for message in hotResults + warmResults {
            if !seenIDs.contains(message.id) {
                seenIDs.insert(message.id)
                results.append(message)
            }
        }
        
        // 更新访问计数
        for message in results {
            warmStorage.updateAccessCount(for: message.id)
        }
        
        return results
    }
    
    func getDistilledKnowledge(for topic: String) -> DistilledContent? {
        return warmStorage.getDistilledContent(for: topic)
    }
    
    func clearHistory() {
        hotStorage.clear()
        warmStorage.clearMessages()
    }
    
    // MARK: - 技能相关存储
    
    func saveSkill(_ skill: Skill, withEvolution: Bool = true) {
        // 技能永远保存在温数据层
        warmStorage.saveSkill(skill)
        
        // 如果开启进化，保存进化历史
        if withEvolution {
            coldStorage.saveSkillEvolution(skill)
        }
    }
    
    func getSkills() -> [Skill] {
        // 优先从热存储获取活跃技能
        let hotSkills = hotStorage.getActiveSkills()
        let warmSkills = warmStorage.getSkills()
        
        // 合并，热存储优先
        var skillMap: [String: Skill] = [:]
        for skill in warmSkills {
            skillMap[skill.id] = skill
        }
        for skill in hotSkills {
            skillMap[skill.id] = skill
        }
        
        return Array(skillMap.values)
    }

    func getSkill(id: String) -> Skill? {
        getSkills().first { $0.id == id }
    }

    func getSkillUsageStats(skillId: String) -> SkillUsageStats {
        warmStorage.getSkillUsageStats(skillId: skillId)
    }
    
    func updateSkillUsage(skillId: String, success: Bool, context: String) {
        // 更新使用统计
        warmStorage.recordSkillUsage(skillId: skillId, success: success, context: context)
        
        // 同时更新热存储中的活跃状态
        hotStorage.touchSkill(skillId)
    }
    
    // MARK: - 智能维护
    
    private func setupMaintenance() {
        // 每5分钟执行一次维护
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.performMaintenance()
        }
    }
    
    func performMaintenance() {
        // 1. 热数据层清理（只保留最近20条）
        hotStorage.trimTo(limit: 20)
        
        // 2. 温数据层归档（超过30天的移至冷存储）
        let oldMessages = warmStorage.getMessagesOlderThan(days: 30)
        for message in oldMessages {
            coldStorage.archiveMessage(message, metadata: nil)
        }
        warmStorage.deleteMessagesOlderThan(days: 30)
        
        // 3. 技能进化分析
        analyzeSkillEvolution()
        
        // 4. 批量蒸馏（对中频数据进行蒸馏）
        batchDistillation()
    }
    
    private func analyzeSkillEvolution() {
        let skills = warmStorage.getSkills()
        for skill in skills {
            let usageStats = warmStorage.getSkillUsageStats(skillId: skill.id)
            
            // 检查是否需要进化
            if shouldEvolve(skill: skill, stats: usageStats) {
                // 触发技能进化（通知外部处理）
                NotificationCenter.default.post(
                    name: .skillShouldEvolve,
                    object: nil,
                    userInfo: ["skillId": skill.id]
                )
            }
        }
    }
    
    private func shouldEvolve(skill: Skill, stats: SkillUsageStats) -> Bool {
        // 进化条件：
        // 1. 使用次数超过阈值
        // 2. 成功率变化明显
        // 3. 用户反馈有改进建议
        
        guard stats.totalUses > 10 else { return false }
        
        // 成功率低于70%且使用次数多，需要优化
        if stats.successRate < 0.7 && stats.totalUses > 20 {
            return true
        }
        
        // 有改进建议
        if !stats.improvementSuggestions.isEmpty {
            return true
        }
        
        return false
    }
    
    private func batchDistillation() {
        // 获取中频、长期保存的对话进行蒸馏
        let candidates = warmStorage.getMessagesForDistillation()
        
        for message in candidates {
            if let distilled = distiller.distill(message, context: nil) {
                warmStorage.saveDistilledContent(distilled)
                // 标记已蒸馏
                warmStorage.markAsDistilled(message.id)
            }
        }
    }
    
    // MARK: - 辅助方法
    
    private func calculatePriority(for message: ChatMessage, context: ConversationContext?) -> DataPriority {
        // 系统命令高优先级
        if message.content.hasPrefix("/") {
            return .high
        }
        
        // 包含关键信息的提升优先级
        if message.content.contains("错误") || 
           message.content.contains("成功") ||
           message.content.contains("结论") {
            return .critical
        }
        
        // 长对话可能是重要内容
        if message.content.count > 200 {
            return .high
        }
        
        return .normal
    }
    
    private func determineLifetime(for message: ChatMessage, priority: DataPriority) -> DataLifetime {
        switch priority {
        case .critical:
            return .longTerm
        case .high:
            return .mediumTerm
        case .normal:
            return .shortTerm
        case .low:
            return .session
        }
    }
    
    private func extractTags(from message: ChatMessage) -> [String] {
        var tags: [String] = []
        let content = message.content.lowercased()
        
        // 提取关键词作为标签
        if content.contains("代码") || content.contains("program") {
            tags.append("code")
        }
        if content.contains("错误") || content.contains("error") {
            tags.append("error")
        }
        if content.contains("配置") || content.contains("setup") {
            tags.append("config")
        }
        
        return tags
    }
}

// MARK: - 通知扩展

extension Notification.Name {
    static let skillShouldEvolve = Notification.Name("skillShouldEvolve")
    static let skillEvolutionProposalReady = Notification.Name("skillEvolutionProposalReady")
}
