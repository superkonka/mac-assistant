//
//  MemoryRecallCoordinator.swift
//  MacAssistant
//
//  原生记忆召回协调器 - 使用本地向量存储和 Embedding 服务
//

import Foundation

// MARK: - 简化版 Embedding 类型（避免循环依赖）

/// 简化的嵌入向量
private struct SimpleEmbeddingVector {
    let vector: [Float]
    let dimensions: Int
    
    init(vector: [Float]) {
        self.vector = vector
        self.dimensions = vector.count
    }
}

/// 简化的 Embedding 服务协议
private protocol SimpleEmbeddingService: Actor {
    func embed(text: String) async throws -> SimpleEmbeddingVector
}

/// 本地 Embedding 服务实现
private actor LocalSimpleEmbeddingService: SimpleEmbeddingService {
    private let dimensions = 384
    
    func embed(text: String) async throws -> SimpleEmbeddingVector {
        // 使用确定性哈希生成向量
        var vector: [Float] = []
        var hash = text.hash
        
        for _ in 0..<dimensions {
            hash = hash &* 31 &+ 17
            let value = Float(hash % 1000) / 1000.0 * 2.0 - 1.0
            vector.append(value)
        }
        
        // 归一化
        let norm = sqrt(vector.map { $0 * $0 }.reduce(0, +))
        let normalizedVector = vector.map { $0 / norm }
        
        return SimpleEmbeddingVector(vector: normalizedVector)
    }
}

private extension String {
    var hash: Int {
        var h = 0
        for char in self.unicodeScalars {
            h = h &* 31 &+ Int(char.value)
        }
        return h
    }
}

struct ConversationRecallTurn: Sendable {
    let role: String
    let content: String
}

struct MemoryRecallPrelude: Sendable {
    let message: String
    let query: String
    let hitCount: Int
    let forcedReindex: Bool
}

/// 原生记忆召回协调器 - 不依赖 OpenClaw
actor MemoryRecallCoordinator {
    static let shared = MemoryRecallCoordinator()

    private let minUsefulScore = 0.3  // 余弦相似度阈值
    private let maxPreludeHits = 4
    private let reindexCooldown: TimeInterval = 15

    private var lastIndexAttemptAt = Date.distantPast
    
    // 依赖服务
    private let embeddingService: any SimpleEmbeddingService
    private let vectorStore: InMemoryVectorStore
    
    init() {
        self.embeddingService = LocalSimpleEmbeddingService()
        self.vectorStore = InMemoryVectorStore()
    }

    /// 检查是否需要记忆召回，并返回相关上下文
    func recallPreludeIfNeeded(
        text: String,
        turns: [ConversationRecallTurn]
    ) async -> MemoryRecallPrelude? {
        let normalizedText = self.normalizedText(text)
        guard Self.isMemorySensitive(normalizedText) else {
            return nil
        }

        let query = self.searchQuery(for: normalizedText, turns: turns)

        do {
            // 执行向量搜索
            var hits = try await self.search(query: query)
            var forcedReindex = false

            // 如果没有结果，尝试刷新索引
            if hits.isEmpty, await self.needsReindex() {
                forcedReindex = await self.forceReindexIfAllowed(reason: "prelude:\(normalizedText)")
                if forcedReindex {
                    hits = try await self.search(query: query)
                }
            }

            let usefulHits = self.usefulHits(from: hits)
            guard !usefulHits.isEmpty else {
                LogInfo(
                    "Memory recall found no useful match " +
                    "queryLength=\(query.count) forcedReindex=\(forcedReindex)"
                )
                return nil
            }

            LogInfo(
                "Memory recall prepared prelude " +
                "queryLength=\(query.count) hits=\(usefulHits.count) forcedReindex=\(forcedReindex)"
            )

            return MemoryRecallPrelude(
                message: self.composePreludeMessage(from: usefulHits),
                query: query,
                hitCount: usefulHits.count,
                forcedReindex: forcedReindex
            )
        } catch {
            LogWarning(
                "Memory recall failed before main conversation " +
                "queryLength=\(query.count) error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    /// 记录转录变更，触发重新索引
    func noteTranscriptMutation(reason: String) async {
        guard await self.needsReindex() else {
            return
        }
        _ = await self.forceReindexIfAllowed(reason: reason)
    }

    /// 添加对话历史到记忆存储
    func addConversationMessage(_ message: ChatMessage) async {
        let text = message.content
        guard !text.isEmpty else { return }
        
        do {
            // 生成嵌入向量
            let embedding = try await embeddingService.embed(text: text)
            
            // 创建记忆条目
            let entry = MemoryEntry(
                id: message.id.uuidString,
                text: text,
                role: message.role.rawValue,
                timestamp: message.timestamp,
                metadata: [
                    "agentId": message.agentId ?? "",
                    "type": "conversation"
                ]
            )
            
            // 存储到向量存储
            await vectorStore.add(entry: entry, embedding: embedding)
            
            LogDebug("[MemoryRecall] Added message to vector store: \(String(text.prefix(50)))...")
        } catch {
            LogError("[MemoryRecall] Failed to add message: \(error)")
        }
    }

    /// 检查文本是否与记忆敏感相关
    nonisolated static func isMemorySensitive(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else {
            return false
        }

        let directSignals = [
            "记得", "还记得", "记忆", "回忆", "聊过", "说过", "上次", "之前", "刚才", "刚刚",
            "前面", "接着", "接上", "继续刚才", "我叫什么", "我的名字", "我是谁", "偏好", "习惯",
            "待办", "todo", "open loop", "上一步", "刚刚那个", "remember", "recall", "earlier",
            "previous", "before", "we discussed", "you said", "my name", "preference", "todo",
            "what did we", "what did i"
        ]

        if directSignals.contains(where: { normalized.contains($0) }) {
            return true
        }

        let followUpSignals = ["那个", "那次", "那件事", "上面", "前面那个", "刚那条", "that one", "that", "it"]
        let followUpQuestionSignals = ["多少", "哪个", "什么", "where", "what", "which", "how much"]
        return followUpSignals.contains(where: { normalized.contains($0) }) &&
            followUpQuestionSignals.contains(where: { normalized.contains($0) })
    }

    // MARK: - Private Methods

    private func searchQuery(for text: String, turns: [ConversationRecallTurn]) -> String {
        let baseQuery = String(text.prefix(320))
        var parts = [baseQuery]

        let needsExpansion = text.count <= 48 || ["刚才", "刚刚", "前面", "上面", "那个", "that", "it"]
            .contains(where: { text.lowercased().contains($0) })

        guard needsExpansion else {
            return baseQuery
        }

        let recentTurns = turns
            .reversed()
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { !$0.role.lowercased().contains("system") }
            .prefix(4)
            .map { String(self.normalizedText($0.content).prefix(180)) }
            .filter { !$0.isEmpty && $0 != baseQuery }
            .reversed()

        parts.append(contentsOf: recentTurns.map { "上下文: \($0)" })
        return parts.joined(separator: "\n")
    }

    /// 执行向量搜索
    private func search(query: String) async throws -> [SearchHit] {
        // 生成查询向量
        let queryEmbedding = try await embeddingService.embed(text: query)
        
        // 在向量存储中搜索
        let results = await vectorStore.search(
            queryEmbedding: queryEmbedding,
            topK: 6,
            threshold: minUsefulScore
        )
        
        // 转换为 SearchHit
        return results.map { result in
            SearchHit(
                score: Double(result.similarity),
                path: "memory://\(result.entry.id)",
                startLine: 0,
                endLine: 0,
                snippet: result.entry.text
            )
        }
    }

    private func composePreludeMessage(from hits: [SearchHit]) -> String {
        let lines = hits.enumerated().map { index, hit in
            "\(index + 1). \(self.cleanSnippet(hit.snippet))"
        }

        return """
        [Internal Recall Context]
        供下一轮回答参考的持久记忆命中如下。仅在与当前问题直接相关时使用；不要提及检索过程、路径、文件名或内部上下文。
        \(lines.joined(separator: "\n"))
        """
    }

    private func usefulHits(from hits: [SearchHit]) -> [SearchHit] {
        let filtered = hits.filter { $0.score >= self.minUsefulScore }
        let source = filtered.isEmpty ? Array(hits.prefix(2)) : filtered

        var seen = Set<String>()
        var result: [SearchHit] = []

        for hit in source {
            let snippet = self.cleanSnippet(hit.snippet)
            guard !snippet.isEmpty else { continue }
            let dedupeKey = "\(hit.path)#\(hit.startLine)#\(snippet)"
            guard seen.insert(dedupeKey).inserted else { continue }
            result.append(hit)
            if result.count >= self.maxPreludeHits {
                break
            }
        }

        return result
    }

    private func cleanSnippet(_ snippet: String) -> String {
        let collapsed = snippet
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 220 else {
            return collapsed
        }
        return String(collapsed.prefix(220)) + "..."
    }

    private func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func needsReindex() async -> Bool {
        // 检查是否需要重新索引
        // 简化：基于时间和存储大小判断
        let entryCount = await vectorStore.count()
        return entryCount > 0 && Date().timeIntervalSince(lastIndexAttemptAt) > reindexCooldown
    }

    private func forceReindexIfAllowed(reason: String) async -> Bool {
        let now = Date()
        guard now.timeIntervalSince(self.lastIndexAttemptAt) >= self.reindexCooldown else {
            return false
        }

        self.lastIndexAttemptAt = now
        
        // 执行重新索引（优化向量存储）
        await vectorStore.optimize()
        
        LogInfo("Memory index refresh completed reason=\(reason)")
        return true
    }
}

// MARK: - Supporting Types

private struct SearchHit {
    let score: Double
    let path: String
    let startLine: Int
    let endLine: Int
    let snippet: String
}

/// 记忆条目
private struct MemoryEntry: Identifiable {
    let id: String
    let text: String
    let role: String
    let timestamp: Date
    let metadata: [String: String]
}

/// 向量搜索结果
private struct VectorSearchResult {
    let entry: MemoryEntry
    let similarity: Float
}

/// 内存向量存储
private actor InMemoryVectorStore {
    private var entries: [String: MemoryEntry] = [:]
    private var embeddings: [String: SimpleEmbeddingVector] = [:]
    
    /// 添加条目
    func add(entry: MemoryEntry, embedding: SimpleEmbeddingVector) {
        entries[entry.id] = entry
        embeddings[entry.id] = embedding
    }
    
    /// 搜索相似条目
    func search(queryEmbedding: SimpleEmbeddingVector, topK: Int, threshold: Double) -> [VectorSearchResult] {
        var results: [VectorSearchResult] = []
        
        for (id, entry) in entries {
            guard let embedding = embeddings[id] else { continue }
            
            // 计算余弦相似度
            let similarity = cosineSimilarity(queryEmbedding.vector, embedding.vector)
            
            if similarity >= Float(threshold) {
                results.append(VectorSearchResult(entry: entry, similarity: similarity))
            }
        }
        
        // 按相似度排序并限制数量
        return results
            .sorted { $0.similarity > $1.similarity }
            .prefix(topK)
            .map { $0 }
    }
    
    /// 获取条目数量
    func count() -> Int {
        entries.count
    }
    
    /// 优化存储
    func optimize() {
        // 清理过期条目（简化实现）
        let cutoffDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)  // 7天前
        let expiredIds = entries
            .filter { $0.value.timestamp < cutoffDate }
            .map { $0.key }
        
        for id in expiredIds {
            entries.removeValue(forKey: id)
            embeddings.removeValue(forKey: id)
        }
        
        LogInfo("[VectorStore] Optimized: removed \(expiredIds.count) expired entries, remaining \(entries.count)")
    }
    
    /// 计算余弦相似度
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        
        guard normA > 0 && normB > 0 else { return 0 }
        return dotProduct / (sqrt(normA) * sqrt(normB))
    }
}

// MARK: - UserPreferenceStore Extension

extension UserPreferenceStore {
    var useCustomEmbedding: Bool {
        get { UserDefaults.standard.bool(forKey: "useCustomEmbedding") }
        set { UserDefaults.standard.set(newValue, forKey: "useCustomEmbedding") }
    }
    
    var embeddingAPIKey: String? {
        get { UserDefaults.standard.string(forKey: "embeddingAPIKey") }
        set { UserDefaults.standard.set(newValue, forKey: "embeddingAPIKey") }
    }
    
    var embeddingModel: String {
        get { UserDefaults.standard.string(forKey: "embeddingModel") ?? "text-embedding-3-small" }
        set { UserDefaults.standard.set(newValue, forKey: "embeddingModel") }
    }
    
    var embeddingBaseURL: String {
        get { UserDefaults.standard.string(forKey: "embeddingBaseURL") ?? "https://api.openai.com/v1" }
        set { UserDefaults.standard.set(newValue, forKey: "embeddingBaseURL") }
    }
}
