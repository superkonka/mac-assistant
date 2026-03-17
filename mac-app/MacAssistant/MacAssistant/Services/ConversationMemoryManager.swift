//
//  ConversationMemoryManager.swift
//  MacAssistant
//
//  对话记忆管理器 - 简化的上下文回填系统
//  作为秘书最基本的职责：记住用户说过的话
//

import Foundation
import NaturalLanguage

/// 对话历史条目
struct ConversationEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let sessionID: String
    let role: MessageRole
    let content: String
    let timestamp: Date
    let agentID: String?
    let agentName: String?
    let metadata: [String: String]?
    
    var isUserMessage: Bool { role == .user }
    var isAssistantMessage: Bool { role == .assistant }
}

/// 记忆上下文
struct MemoryContext: Codable {
    let relevantEntries: [ConversationEntry]
    let summary: String?
    let lastTopic: String?
    let continuityHints: [String]
    
    var isEmpty: Bool { relevantEntries.isEmpty }
    
    /// 格式化为提示词（按时间线组织）
    func formattedForPrompt(maxEntries: Int = 10) -> String {
        var parts: [String] = []
        
        // 1. 时间线摘要
        if let summary = summary, !summary.isEmpty {
            parts.append("📋 对话时间线：\n\(summary)\n")
        }
        
        // 2. 按时间顺序排列的对话历史
        if !relevantEntries.isEmpty {
            parts.append("💬 对话历史（按时间顺序）：")
            let entriesToShow = Array(relevantEntries.suffix(maxEntries))  // 取最近的
            
            var lastTimestamp: Date?
            for entry in entriesToShow {
                let role = entry.isUserMessage ? "用户" : (entry.agentName ?? "助手")
                let timeMark = formatTimeMark(entry: entry, lastTimestamp: lastTimestamp)
                parts.append("\(timeMark)\(role)：\(entry.content.prefix(200))\(entry.content.count > 200 ? "..." : "")")
                lastTimestamp = entry.timestamp
            }
        }
        
        // 3. 当前话题提示
        if let topic = lastTopic, !topic.isEmpty {
            parts.append("\n📍 当前话题：\(topic)")
        }
        
        // 4. 连续性提示
        if !continuityHints.isEmpty {
            parts.append("\n🔔 连续性提示：\n" + continuityHints.joined(separator: "\n"))
        }
        
        return parts.joined(separator: "\n")
    }
    
    /// 格式化时间标记
    private func formatTimeMark(entry: ConversationEntry, lastTimestamp: Date?) -> String {
        guard let last = lastTimestamp else { return "" }
        
        let gap = entry.timestamp.timeIntervalSince(last)
        if gap > 300 {  // 超过5分钟显示时间
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "[\(formatter.string(from: entry.timestamp))] "
        }
        return ""
    }
}

/// 对话记忆管理器
@MainActor
final class ConversationMemoryManager: ObservableObject {
    static let shared = ConversationMemoryManager()
    
    /// 最大保留的对话历史数量
    private let maxHistorySize = 100
    
    /// 向量维度
    private let vectorDimension = 32
    
    /// 对话历史存储
    @Published private(set) var entries: [ConversationEntry] = []
    
    /// 向量缓存 (entryID -> vector)
    private var vectorCache: [String: [Double]] = [:]
    
    /// 会话索引 (sessionID -> entryIDs)
    private var sessionIndex: [String: [UUID]] = [:]
    
    private init() {
        loadPersistedEntries()
    }
    
    // MARK: - 核心 API
    
    /// 记录对话条目
    func recordEntry(
        sessionID: String,
        role: MessageRole,
        content: String,
        agentID: String? = nil,
        agentName: String? = nil,
        metadata: [String: String]? = nil
    ) {
        let entry = ConversationEntry(
            id: UUID(),
            sessionID: sessionID,
            role: role,
            content: content,
            timestamp: Date(),
            agentID: agentID,
            agentName: agentName,
            metadata: metadata
        )
        
        entries.append(entry)
        
        // 更新索引
        sessionIndex[sessionID, default: []].append(entry.id)
        
        // 生成并缓存向量
        let vector = generateVector(for: content)
        vectorCache[entry.id.uuidString] = vector
        
        // 清理旧数据
        if entries.count > maxHistorySize {
            cleanupOldEntries()
        }
        
        // 持久化
        persistEntries()
        
        LogInfo("MemoryManager: 记录对话 entry=\(entry.id), session=\(sessionID), role=\(role)")
    }
    
    /// 检索相关历史（基于时间线提炼）
    func retrieveRelevantContext(
        for query: String,
        currentSessionID: String,
        maxEntries: Int = 8,
        timeWindow: TimeInterval = 3600  // 1小时
    ) -> MemoryContext {
        
        let cutoffTime = Date().addingTimeInterval(-timeWindow)
        let queryVector = generateVector(for: query)
        
        // 1. 获取当前会话的近期历史（按时间排序）
        let currentSessionEntries = entries
            .filter { $0.sessionID == currentSessionID && $0.timestamp > cutoffTime }
            .sorted { $0.timestamp < $1.timestamp }
        
        // 2. 时间线基础：获取最近 N 条消息作为上下文基础
        let recentBaseCount = 3
        var selectedEntries: [ConversationEntry] = Array(currentSessionEntries.suffix(recentBaseCount))
        var selectedIDs = Set(selectedEntries.map { $0.id })
        
        // 3. 语义补充：基于相似度查找更多相关内容
        if selectedEntries.count < maxEntries {
            var scoredEntries: [(entry: ConversationEntry, score: Double)] = []
            
            for entry in entries where entry.timestamp > cutoffTime && !selectedIDs.contains(entry.id) {
                guard let entryVector = vectorCache[entry.id.uuidString] else { continue }
                
                let similarity = cosineSimilarity(queryVector, entryVector)
                
                // 同一会话加权，时间越近加权越高
                let sessionBoost = entry.sessionID == currentSessionID ? 0.3 : 0
                let timeBoost = calculateTimeBoost(entry: entry, cutoff: cutoffTime)
                let finalScore = similarity + sessionBoost + timeBoost
                
                if finalScore > 0.25 {
                    scoredEntries.append((entry, finalScore))
                }
            }
            
            // 按相似度排序，选择补充条目
            scoredEntries.sort { $0.score > $1.score }
            let remainingSlots = maxEntries - selectedEntries.count
            let supplementary = scoredEntries.prefix(remainingSlots).map { $0.entry }
            
            selectedEntries.append(contentsOf: supplementary)
            selectedIDs.formUnion(supplementary.map { $0.id })
        }
        
        // 4. 按时间线排序（不是按相似度！）
        let timeLineEntries = selectedEntries.sorted { $0.timestamp < $1.timestamp }
        
        // 5. 生成时间线摘要
        let timeLineSummary = generateTimeLineSummary(from: timeLineEntries)
        
        // 6. 提取当前话题
        let currentTopic = extractCurrentTopic(from: currentSessionEntries)
        
        // 7. 生成基于时间线的连续性提示
        let continuityHints = generateTimeLineContinuityHints(
            currentQuery: query,
            timeLineEntries: timeLineEntries,
            allSessionEntries: currentSessionEntries
        )
        
        return MemoryContext(
            relevantEntries: timeLineEntries,
            summary: timeLineSummary,
            lastTopic: currentTopic,
            continuityHints: continuityHints
        )
    }
    
    /// 计算时间加权（越近越高）
    private func calculateTimeBoost(entry: ConversationEntry, cutoff: Date) -> Double {
        let totalWindow = Date().timeIntervalSince(cutoff)
        let entryAge = Date().timeIntervalSince(entry.timestamp)
        let recency = 1.0 - (entryAge / totalWindow)
        return max(0, recency * 0.2)  // 最大0.2的加权
    }
    
    /// 获取会话的完整历史
    func getSessionHistory(sessionID: String, limit: Int = 50) -> [ConversationEntry] {
        return entries
            .filter { $0.sessionID == sessionID }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(limit)
    }
    
    /// 获取最近的对话
    func getRecentEntries(count: Int = 10) -> [ConversationEntry] {
        return entries.suffix(count)
    }
    
    /// 清空历史
    func clearHistory() {
        entries.removeAll()
        vectorCache.removeAll()
        sessionIndex.removeAll()
        persistEntries()
    }
    
    /// 清空特定会话的历史
    func clearSessionHistory(sessionID: String) {
        entries.removeAll { $0.sessionID == sessionID }
        let validIDs = Set(entries.map { $0.id.uuidString })
        vectorCache = vectorCache.filter { validIDs.contains($0.key) }
        sessionIndex.removeValue(forKey: sessionID)
        persistEntries()
    }
    
    // MARK: - 上下文注入
    
    /// 为请求准备带上下文的提示词
    func prepareContextualPrompt(
        userMessage: String,
        sessionID: String,
        systemPrompt: String? = nil
    ) -> (text: String, systemPrompt: String?) {
        
        let context = retrieveRelevantContext(for: userMessage, currentSessionID: sessionID)
        
        guard !context.isEmpty else {
            return (userMessage, systemPrompt)
        }
        
        // 构建增强的用户消息
        var enhancedMessage = userMessage
        
        // 如果用户消息包含"继续"、"刚才"等词，添加更多上下文
        if shouldEnrichContext(for: userMessage) {
            let contextPrompt = context.formattedForPrompt()
            enhancedMessage = """
            \(contextPrompt)
            
            ---
            
            当前用户输入：\(userMessage)
            """
        }
        
        // 增强系统提示词
        var enhancedSystemPrompt = systemPrompt
        if let sp = systemPrompt, !sp.isEmpty {
            enhancedSystemPrompt = """
            \(sp)
            
            【记忆提示】
            你在与用户的对话中。以下是相关信息：
            \(context.summary ?? "")
            \(context.continuityHints.joined(separator: "\n"))
            """
        } else if !context.continuityHints.isEmpty {
            enhancedSystemPrompt = """
            你是一个AI助手，正在与用户进行对话。
            
            【前文上下文】
            \(context.continuityHints.joined(separator: "\n"))
            """
        }
        
        return (enhancedMessage, enhancedSystemPrompt)
    }
    
    // MARK: - 辅助方法
    
    private func shouldEnrichContext(for message: String) -> Bool {
        let contextKeywords = [
            "继续", "刚才", "之前", "上面", "前面",
            "接着说", "继续讲", "回到", "刚才说",
            "continue", "previous", "earlier", "before",
            "刚才那个", "之前那个", "上面提到的"
        ]
        
        let lowercased = message.lowercased()
        return contextKeywords.contains { lowercased.contains($0) }
    }
    
    /// 生成基于时间线的摘要
    private func generateTimeLineSummary(from entries: [ConversationEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        
        // 按时间排序
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        
        // 提取话题演变
        var topics: [String] = []
        var lastRole: MessageRole?
        
        for entry in sorted {
            if entry.isUserMessage && lastRole != .user {
                let topic = entry.content.prefix(40).description
                topics.append(String(topic))
            }
            lastRole = entry.role
        }
        
        if topics.isEmpty { return nil }
        
        if topics.count == 1 {
            return "正在讨论：\(topics[0])"
        } else {
            return "对话演变：" + topics.joined(separator: " → ")
        }
    }
    
    /// 提取当前话题
    private func extractCurrentTopic(from entries: [ConversationEntry]) -> String? {
        guard let lastUser = entries.last(where: { $0.isUserMessage }) else { return nil }
        return String(lastUser.content.prefix(50))
    }
    
    /// 生成基于时间线的连续性提示
    private func generateTimeLineContinuityHints(
        currentQuery: String,
        timeLineEntries: [ConversationEntry],
        allSessionEntries: [ConversationEntry]
    ) -> [String] {
        var hints: [String] = []
        
        // 1. 最近的对话脉络（按时间）
        let recentFlow = timeLineEntries.suffix(4)
        if recentFlow.count >= 2 {
            let flow = recentFlow.map { entry -> String in
                let role = entry.isUserMessage ? "用户" : "助手"
                return "\(role)：\(entry.content.prefix(30))..."
            }.joined(separator: " → ")
            hints.append("最近对话脉络：\(flow)")
        }
        
        // 2. 用户上一条消息（如果不是当前消息）
        let userMessages = allSessionEntries.filter { $0.isUserMessage }
        if userMessages.count >= 2 {
            let lastUserMsg = userMessages.suffix(2).first
            if let msg = lastUserMsg, msg.content != currentQuery {
                hints.append("用户之前问：\(msg.content.prefix(50))...")
            }
        }
        
        // 3. 等待回应的助手消息
        if let lastAssistant = allSessionEntries.last(where: { $0.isAssistantMessage }) {
            let timeAgo = formatTimeAgo(lastAssistant.timestamp)
            hints.append("\(timeAgo)前助手回复了关于「\(lastAssistant.content.prefix(30))...」的内容")
        }
        
        return hints
    }
    
    /// 格式化时间差
    private func formatTimeAgo(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 {
            return "\(Int(seconds))秒"
        } else if seconds < 3600 {
            return "\(Int(seconds/60))分钟"
        } else {
            return "\(Int(seconds/3600))小时"
        }
    }
    
    // MARK: - 向量计算
    
    private func generateVector(for text: String) -> [Double] {
        // 简化的词袋模型
        var vector = Array(repeating: 0.0, count: vectorDimension)
        
        let keywords = [
            "代码", "分析", "审查", "优化", "重构",
            "文件", "磁盘", "存储", "清理", "迁移",
            "部署", "发布", "测试", "构建",
            "配置", "设置", "调整", "修改",
            "查询", "搜索", "查找", "定位",
            "创建", "生成", "构建", "制作",
            "查看", "显示", "列出", "展示",
            "帮助", "说明", "文档", "指南",
            "继续", "刚才", "之前", "上面",
            "问题", "错误", "失败", "超时",
            "ok", "好的", "完成", "结束"
        ]
        
        let lowercased = text.lowercased()
        
        for (index, keyword) in keywords.enumerated() {
            if index >= vectorDimension { break }
            if lowercased.contains(keyword) {
                vector[index] = 1.0
            }
        }
        
        // 归一化
        let magnitude = sqrt(vector.map { $0 * $0 }.reduce(0, +))
        if magnitude > 0 {
            vector = vector.map { $0 / magnitude }
        }
        
        return vector
    }
    
    private func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count, !v1.isEmpty else { return 0 }
        
        let dotProduct = zip(v1, v2).map { $0 * $1 }.reduce(0, +)
        let mag1 = sqrt(v1.map { $0 * $0 }.reduce(0, +))
        let mag2 = sqrt(v2.map { $0 * $0 }.reduce(0, +))
        
        return mag1 > 0 && mag2 > 0 ? dotProduct / (mag1 * mag2) : 0
    }
    
    // MARK: - 数据持久化
    
    private func persistEntries() {
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: "conversation_memory_entries")
        } catch {
            LogError("MemoryManager: 持久化失败 \(error)")
        }
    }
    
    private func loadPersistedEntries() {
        guard let data = UserDefaults.standard.data(forKey: "conversation_memory_entries") else {
            return
        }
        
        do {
            entries = try JSONDecoder().decode([ConversationEntry].self, from: data)
            
            // 重建索引和向量缓存
            for entry in entries {
                sessionIndex[entry.sessionID, default: []].append(entry.id)
                vectorCache[entry.id.uuidString] = generateVector(for: entry.content)
            }
            
            LogInfo("MemoryManager: 加载了 \(entries.count) 条历史记录")
        } catch {
            LogError("MemoryManager: 加载失败 \(error)")
        }
    }
    
    private func cleanupOldEntries() {
        let cutoff = Date().addingTimeInterval(-86400 * 7)  // 保留7天
        entries.removeAll { $0.timestamp < cutoff }
        
        // 清理向量缓存
        let validIDs = Set(entries.map { $0.id.uuidString })
        vectorCache = vectorCache.filter { validIDs.contains($0.key) }
        
        // 重建索引
        sessionIndex.removeAll()
        for entry in entries {
            sessionIndex[entry.sessionID, default: []].append(entry.id)
        }
    }
}

// MARK: - CommandRunner 集成扩展

extension CommandRunner {
    
    /// 记录对话到记忆系统
    @MainActor
    func recordConversationToMemory(_ message: ChatMessage, sessionID: String? = nil) {
        let memory = ConversationMemoryManager.shared
        
        let session = sessionID ?? "main_session"
        
        memory.recordEntry(
            sessionID: session,
            role: message.role,
            content: message.content,
            agentID: message.agentId,
            agentName: message.agentName,
            metadata: message.metadata
        )
    }
    
    /// 为请求准备带记忆的上下文
    @MainActor
    func prepareRequestWithMemory(
        text: String,
        sessionID: String? = nil,
        systemPrompt: String? = nil
    ) -> (text: String, systemPrompt: String?) {
        let memory = ConversationMemoryManager.shared
        
        let session = sessionID ?? "main_session"
        
        return memory.prepareContextualPrompt(
            userMessage: text,
            sessionID: session,
            systemPrompt: systemPrompt
        )
    }
}
