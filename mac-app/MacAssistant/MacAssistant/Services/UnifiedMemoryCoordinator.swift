//
//  UnifiedMemoryCoordinator.swift
//  MacAssistant
//
//  统一记忆协调器 - 基于向量化的智能记忆系统
//  自动为每个对话检索相关历史，无需关键词触发
//

import Foundation

/// 统一记忆检索结果
struct UnifiedMemoryContext: Sendable {
    /// 检索到的相关历史对话
    let relevantHistory: [MemoryTurn]
    /// 相似度分数（用于决策是否使用）
    let relevanceScore: Double
    /// 是否找到有价值的记忆
    let hasValuableMemory: Bool
    /// 用于展示的摘要
    let summary: String
    /// 格式化后的上下文提示
    let formattedContext: String
}

/// 记忆回合
struct MemoryTurn: Sendable, Identifiable, Codable {
    let id: String
    let role: String  // "user" or "assistant"
    let content: String
    let timestamp: Date
    let similarity: Double
    let sessionID: String
}

/// 记忆特征分析
struct MemoryCharacteristics: Sendable {
    /// 话题连续性（0-1）
    let topicContinuity: Double
    /// 任务相关性（0-1）
    let taskRelevance: Double
    /// 实体匹配度（0-1）
    let entityMatch: Double
    /// 时间衰减因子（0-1）
    let recencyFactor: Double
    
    /// 综合记忆价值分数
    var valueScore: Double {
        (topicContinuity * 0.3 + taskRelevance * 0.4 + entityMatch * 0.2 + recencyFactor * 0.1)
    }
}

@MainActor
final class UnifiedMemoryCoordinator {
    static let shared = UnifiedMemoryCoordinator()
    
    // MARK: - 配置
    
    /// 最小相关性阈值（低于此值不返回记忆）
    private let minRelevanceThreshold = 0.35
    
    /// 最大返回记忆数量
    private let maxMemoryTurns = 6
    
    /// 短期记忆窗口（最近N条消息）
    private let shortTermWindow = 10
    
    /// 短期记忆时间窗口（最近30分钟）
    private let shortTermTimeWindow: TimeInterval = 30 * 60
    
    /// 长期记忆时间窗口（最近7天）
    private let longTermTimeWindow: TimeInterval = 7 * 24 * 3600
    
    /// 向量服务
    private let embeddingService = VectorEmbeddingService.shared
    
    /// 本地记忆存储（用于快速检索）
    private var memoryStore: [String: MemoryTurn] = [:]
    
    /// 会话索引
    private var sessionMemories: [String: [String]] = [:]
    
    /// 待索引队列
    private var pendingIndexQueue: [MemoryTurn] = []
    
    private init() {
        loadPersistedMemories()
    }
    
    // MARK: - 核心 API
    
    /// 为当前对话检索相关记忆（每次对话自动调用）
    func retrieveMemoryContext(
        for query: String,
        currentSessionID: String,
        recentTurns: [ConversationRecallTurn] = []
    ) async -> UnifiedMemoryContext {
        
        let startTime = Date()
        
        // 1. 构建增强查询（结合近期对话上下文）
        let enhancedQuery = buildEnhancedQuery(query: query, recentTurns: recentTurns)
        
        // 2. 短期记忆检索（当前会话）
        let shortTermMemories = retrieveShortTermMemories(
            sessionID: currentSessionID,
            query: enhancedQuery
        )
        
        // 3. 长期记忆检索（跨会话向量搜索）
        let longTermMemories = await retrieveLongTermMemories(
            query: enhancedQuery,
            excludingSession: currentSessionID
        )
        
        // 4. 合并并去重
        var allMemories = shortTermMemories + longTermMemories
        allMemories = deduplicateMemories(allMemories)
        
        // 5. 计算综合特征
        let characteristics = analyzeCharacteristics(
            query: query,
            memories: allMemories,
            recentTurns: recentTurns
        )
        
        // 6. 根据价值分数过滤
        let valuableMemories = allMemories.filter { $0.similarity >= minRelevanceThreshold }
            .sorted { $0.similarity > $1.similarity }
            .prefix(maxMemoryTurns)
            .map { $0 }
        
        // 7. 生成上下文
        let formattedContext = formatMemoryContext(
            memories: valuableMemories,
            characteristics: characteristics
        )
        
        let context = UnifiedMemoryContext(
            relevantHistory: valuableMemories,
            relevanceScore: characteristics.valueScore,
            hasValuableMemory: !valuableMemories.isEmpty && characteristics.valueScore > 0.4,
            summary: generateSummary(memories: valuableMemories, characteristics: characteristics),
            formattedContext: formattedContext
        )
        
        let duration = Date().timeIntervalSince(startTime)
        LogInfo("[UnifiedMemory] 检索完成: \(valuableMemories.count)条记忆, 相关性\(String(format: "%.2f", context.relevanceScore)), 耗时\(String(format: "%.3f", duration))s")
        
        return context
    }
    
    /// 索引新对话（在对话完成后调用）
    func indexConversation(
        sessionID: String,
        userMessage: String,
        assistantResponse: String,
        timestamp: Date = Date()
    ) {
        // 创建用户消息记忆
        let userTurn = MemoryTurn(
            id: "\(sessionID)_user_\(timestamp.timeIntervalSince1970)",
            role: "user",
            content: userMessage,
            timestamp: timestamp,
            similarity: 1.0,
            sessionID: sessionID
        )
        
        // 创建助手回复记忆
        let assistantTurn = MemoryTurn(
            id: "\(sessionID)_assistant_\(timestamp.timeIntervalSince1970)",
            role: "assistant",
            content: assistantResponse,
            timestamp: timestamp.addingTimeInterval(1), // 略晚于用户消息
            similarity: 1.0,
            sessionID: sessionID
        )
        
        // 存入记忆库
        memoryStore[userTurn.id] = userTurn
        memoryStore[assistantTurn.id] = assistantTurn
        
        // 更新会话索引
        sessionMemories[sessionID, default: []].append(userTurn.id)
        sessionMemories[sessionID, default: []].append(assistantTurn.id)
        
        // 加入待索引队列（用于向量嵌入）
        pendingIndexQueue.append(userTurn)
        pendingIndexQueue.append(assistantTurn)
        
        // 触发异步索引
        Task {
            await processPendingIndices()
        }
        
        // 持久化
        persistMemories()
        
        LogDebug("[UnifiedMemory] 索引对话: session=\(sessionID), 队列大小=\(pendingIndexQueue.count)")
    }
    
    /// 检查是否需要注入记忆上下文（基于相关性而非关键词）
    func shouldInjectMemory(_ context: UnifiedMemoryContext) -> Bool {
        // 只要有足够相关的记忆就注入，不依赖关键词
        return context.hasValuableMemory && context.relevanceScore > 0.4
    }
    
    // MARK: - 检索实现
    
    /// 短期记忆检索（当前会话的近期对话）
    private func retrieveShortTermMemories(sessionID: String, query: String) -> [MemoryTurn] {
        guard let sessionMemoryIDs = sessionMemories[sessionID] else { return [] }
        
        let cutoffTime = Date().addingTimeInterval(-shortTermTimeWindow)
        
        // 获取当前会话的近期记忆
        let recentMemories = sessionMemoryIDs
            .compactMap { memoryStore[$0] }
            .filter { $0.timestamp > cutoffTime }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(shortTermWindow)
            .map { $0 }
        
        // 计算与查询的相似度
        return recentMemories.map { memory in
            // 简化：使用内容重叠度作为相似度估计
            let similarity = estimateSimilarity(query: query, content: memory.content)
            return MemoryTurn(
                id: memory.id,
                role: memory.role,
                content: memory.content,
                timestamp: memory.timestamp,
                similarity: similarity,
                sessionID: memory.sessionID
            )
        }
    }
    
    /// 长期记忆检索（跨会话向量搜索）
    private func retrieveLongTermMemories(
        query: String,
        excludingSession: String
    ) async -> [MemoryTurn] {
        let cutoffTime = Date().addingTimeInterval(-longTermTimeWindow)
        
        // 获取所有候选记忆（排除当前会话和过期记忆）
        let candidates = memoryStore.values
            .filter { $0.sessionID != excludingSession && $0.timestamp > cutoffTime }
        
        // 生成查询向量
        let queryEmbedding = embeddingService.embed(query)
        
        // 计算向量相似度
        var scoredMemories: [(memory: MemoryTurn, score: Double)] = []
        
        for memory in candidates {
            let memoryEmbedding = embeddingService.embed(memory.content)
            let similarity = cosineSimilarity(queryEmbedding, memoryEmbedding)
            
            // 时间衰减
            let age = Date().timeIntervalSince(memory.timestamp)
            let recencyBoost = exp(-age / longTermTimeWindow) // 指数衰减
            let adjustedScore = similarity * (0.7 + 0.3 * recencyBoost)
            
            if adjustedScore > 0.25 { // 预过滤
                scoredMemories.append((memory, adjustedScore))
            }
        }
        
        // 排序并返回
        return scoredMemories
            .sorted { $0.score > $1.score }
            .prefix(maxMemoryTurns)
            .map { entry in
                MemoryTurn(
                    id: entry.memory.id,
                    role: entry.memory.role,
                    content: entry.memory.content,
                    timestamp: entry.memory.timestamp,
                    similarity: entry.score,
                    sessionID: entry.memory.sessionID
                )
            }
    }
    
    // MARK: - 辅助方法
    
    private func buildEnhancedQuery(query: String, recentTurns: [ConversationRecallTurn]) -> String {
        guard !recentTurns.isEmpty else { return query }
        
        // 取最近2-3轮对话作为上下文增强
        let context = recentTurns
            .suffix(3)
            .map { "\($0.role): \($0.content)" }
            .joined(separator: " | ")
        
        return "\(query) [上下文: \(context)]"
    }
    
    private func estimateSimilarity(query: String, content: String) -> Double {
        // 快速估计：共享词汇比例
        let queryWords = Set(query.lowercased().components(separatedBy: .whitespacesAndNewlines))
        let contentWords = Set(content.lowercased().components(separatedBy: .whitespacesAndNewlines))
        
        let intersection = queryWords.intersection(contentWords)
        let union = queryWords.union(contentWords)
        
        guard !union.isEmpty else { return 0 }
        return Double(intersection.count) / Double(union.count)
    }
    
    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        
        let dotProduct = zip(a, b).map(*).reduce(0, +)
        let normA = sqrt(a.map { $0 * $0 }.reduce(0, +))
        let normB = sqrt(b.map { $0 * $0 }.reduce(0, +))
        
        guard normA > 0 && normB > 0 else { return 0 }
        return dotProduct / (normA * normB)
    }
    
    private func deduplicateMemories(_ memories: [MemoryTurn]) -> [MemoryTurn] {
        var seen = Set<String>()
        return memories.filter { memory in
            // 基于内容哈希去重
            let key = String(memory.content.prefix(100))
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }
    }
    
    private func analyzeCharacteristics(
        query: String,
        memories: [MemoryTurn],
        recentTurns: [ConversationRecallTurn]
    ) -> MemoryCharacteristics {
        // 提取查询中的实体（简化版）
        let queryEntities = extractEntities(from: query)
        
        // 话题连续性
        let topicContinuity: Double
        if let lastTurn = recentTurns.last {
            let similarity = estimateSimilarity(query: query, content: lastTurn.content)
            topicContinuity = min(1.0, similarity * 2) // 放大
        } else {
            topicContinuity = 0.5
        }
        
        // 任务相关性（是否有待办/任务相关词汇）
        let taskKeywords = ["任务", "todo", "待办", "完成", "进度", "状态", "分析", "迁移", "清理"]
        let hasTaskContext = taskKeywords.contains { query.contains($0) }
        let taskRelevance = hasTaskContext ? 0.8 : 0.5
        
        // 实体匹配度
        let entityMatch: Double
        if !queryEntities.isEmpty {
            let matchedEntities = memories.flatMap { extractEntities(from: $0.content) }
                .filter { queryEntities.contains($0) }
            entityMatch = Double(Set(matchedEntities).count) / Double(queryEntities.count)
        } else {
            entityMatch = 0.5
        }
        
        // 时间衰减
        let recencyFactor = memories.isEmpty ? 0 : 1.0
        
        return MemoryCharacteristics(
            topicContinuity: topicContinuity,
            taskRelevance: taskRelevance,
            entityMatch: entityMatch,
            recencyFactor: recencyFactor
        )
    }
    
    private func extractEntities(from text: String) -> Set<String> {
        // 简单实体提取：找出可能的名词短语
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        var entities: Set<String> = []
        
        // 提取长度大于2的词和专有名词（简化）
        for word in words {
            let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
            if cleaned.count >= 3 {
                entities.insert(cleaned.lowercased())
            }
        }
        
        return entities
    }
    
    private func formatMemoryContext(memories: [MemoryTurn], characteristics: MemoryCharacteristics) -> String {
        guard !memories.isEmpty else { return "" }
        
        var parts: [String] = []
        
        // 添加相关性说明
        parts.append("[相关历史记忆 | 相关度: \(String(format: "%.0f", characteristics.valueScore * 100))%]")
        
        // 按时间排序
        let sortedMemories = memories.sorted { $0.timestamp < $1.timestamp }
        
        for (index, memory) in sortedMemories.enumerated() {
            let role = memory.role == "user" ? "用户" : "助手"
            let timeMark = formatTimeMark(memory.timestamp)
            parts.append("\(index + 1). [\(timeMark)] \(role): \(memory.content.prefix(150))\(memory.content.count > 150 ? "..." : "")")
        }
        
        parts.append("[记忆结束 - 请基于以上上下文回答当前问题]")
        
        return parts.joined(separator: "\n")
    }
    
    private func formatTimeMark(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
    
    private func generateSummary(memories: [MemoryTurn], characteristics: MemoryCharacteristics) -> String {
        if memories.isEmpty {
            return "未找到相关记忆"
        }
        
        let timeRange = formatTimeRange(memories.map { $0.timestamp })
        return "找到\(memories.count)条相关记忆（\(timeRange)），综合相关度\(String(format: "%.0f", characteristics.valueScore * 100))%"
    }
    
    private func formatTimeRange(_ dates: [Date]) -> String {
        guard let oldest = dates.min(), let newest = dates.max() else { return "" }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        
        let daysApart = Calendar.current.dateComponents([.day], from: oldest, to: newest).day ?? 0
        
        if daysApart == 0 {
            return "今天"
        } else if daysApart <= 7 {
            return "近\(daysApart)天"
        } else {
            return "\(formatter.string(from: oldest))-\(formatter.string(from: newest))"
        }
    }
    
    // MARK: - 异步索引处理
    
    private func processPendingIndices() async {
        guard !pendingIndexQueue.isEmpty else { return }
        
        let batch = pendingIndexQueue
        pendingIndexQueue.removeAll()
        
        // 这里可以添加批量向量索引逻辑
        // 目前使用实时嵌入，所以不需要额外处理
        
        LogDebug("[UnifiedMemory] 处理索引队列: \(batch.count)条")
    }
    
    // MARK: - 持久化
    
    private func persistMemories() {
        do {
            let data = try JSONEncoder().encode(Array(memoryStore.values))
            UserDefaults.standard.set(data, forKey: "unified_memory_store")
            
            let sessionData = try JSONEncoder().encode(sessionMemories)
            UserDefaults.standard.set(sessionData, forKey: "unified_memory_sessions")
        } catch {
            LogError("[UnifiedMemory] 持久化失败: \(error)")
        }
    }
    
    private func loadPersistedMemories() {
        guard let data = UserDefaults.standard.data(forKey: "unified_memory_store") else { return }
        
        do {
            let memories = try JSONDecoder().decode([MemoryTurn].self, from: data)
            memoryStore = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0) })
            
            // 重建会话索引
            for memory in memories {
                sessionMemories[memory.sessionID, default: []].append(memory.id)
            }
            
            LogInfo("[UnifiedMemory] 加载了\(memories.count)条记忆")
        } catch {
            LogError("[UnifiedMemory] 加载失败: \(error)")
        }
    }
    
    // MARK: - 管理接口
    
    /// 清空所有记忆
    func clearAllMemories() {
        memoryStore.removeAll()
        sessionMemories.removeAll()
        pendingIndexQueue.removeAll()
        persistMemories()
        LogInfo("[UnifiedMemory] 已清空所有记忆")
    }
    
    /// 获取记忆统计
    func getStatistics() -> (totalMemories: Int, sessionCount: Int, oldestMemory: Date?) {
        let oldest = memoryStore.values.map { $0.timestamp }.min()
        return (memoryStore.count, sessionMemories.count, oldest)
    }
}

// MARK: - CommandRunner 集成扩展

extension CommandRunner {
    
    /// 统一记忆检索入口（替代原有的 maybeInjectRecallPrelude）
    @MainActor
    func retrieveUnifiedMemoryContext(
        text: String,
        sessionKey: String,
        turns: [ConversationRecallTurn]
    ) async -> UnifiedMemoryContext? {
        
        // 提取会话ID
        let sessionID = extractSessionID(from: sessionKey)
        
        // 调用统一记忆协调器
        let context = await UnifiedMemoryCoordinator.shared.retrieveMemoryContext(
            for: text,
            currentSessionID: sessionID,
            recentTurns: turns
        )
        
        // 记录检索结果
        if context.hasValuableMemory {
            LogInfo("[UnifiedMemory] 检索到相关记忆: \(context.summary)")
        }
        
        return context
    }
    
    /// 索引对话到统一记忆系统
    @MainActor
    func indexToUnifiedMemory(
        sessionKey: String,
        userMessage: String,
        assistantResponse: String
    ) {
        let sessionID = extractSessionID(from: sessionKey)
        
        UnifiedMemoryCoordinator.shared.indexConversation(
            sessionID: sessionID,
            userMessage: userMessage,
            assistantResponse: assistantResponse
        )
    }
    
    private func extractSessionID(from sessionKey: String) -> String {
        // 从 sessionKey 提取 sessionID
        // 例如: "plan-xxx/task-yyy" -> "plan-xxx"
        return sessionKey.components(separatedBy: "/").first ?? sessionKey
    }
}
