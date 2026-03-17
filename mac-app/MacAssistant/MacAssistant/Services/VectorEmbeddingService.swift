//
//  VectorEmbeddingService.swift
//  MacAssistant
//
//  通用向量嵌入服务 - 为记忆、检索、匹配提供统一能力
//

import Foundation
import NaturalLanguage

/// 可向量化的文档协议
protocol VectorDocument: Identifiable {
    var id: String { get }
    var text: String { get }
    var metadata: [String: String] { get }
}

/// 通用向量检索结果
struct GenericVectorSearchResult<T: VectorDocument> {
    let document: T
    let score: Double
    let distance: Double
    
    static func compare(lhs: GenericVectorSearchResult<T>, rhs: GenericVectorSearchResult<T>) -> Bool {
        lhs.score < rhs.score
    }
    
    static func isEqual(lhs: GenericVectorSearchResult<T>, rhs: GenericVectorSearchResult<T>) -> Bool {
        lhs.document.id == rhs.document.id && lhs.score == rhs.score
    }
}

/// 通用向量存储
class GenericVectorStore<T: VectorDocument> {
    private var documents: [String: T] = [:]
    private var embeddings: [String: [Double]] = [:]
    private let embeddingService: VectorEmbeddingService
    
    init(embeddingService: VectorEmbeddingService = .shared) {
        self.embeddingService = embeddingService
    }
    
    /// 添加文档
    func add(_ document: T) {
        documents[document.id] = document
        embeddings[document.id] = embeddingService.embed(document.text)
    }
    
    /// 批量添加
    func add(_ docs: [T]) {
        for doc in docs {
            add(doc)
        }
    }
    
    /// 删除文档
    func remove(id: String) {
        documents.removeValue(forKey: id)
        embeddings.removeValue(forKey: id)
    }
    
    /// 语义搜索
    func search(query: String, topK: Int = 5, threshold: Double = 0.5) -> [GenericVectorSearchResult<T>] {
        let queryVector = embeddingService.embed(query)
        
        var results: [GenericVectorSearchResult<T>] = []
        
        for (id, doc) in documents {
            guard let docVector = embeddings[id] else { continue }
            
            let similarity = cosineSimilarity(queryVector, docVector)
            
            if similarity >= threshold {
                results.append(GenericVectorSearchResult(
                    document: doc,
                    score: similarity,
                    distance: 1 - similarity
                ))
            }
        }
        
        return Array(results.sorted { $0.score > $1.score }.prefix(topK))
    }
    
    /// 相似文档查找
    func findSimilar(to document: T, topK: Int = 5) -> [GenericVectorSearchResult<T>] {
        search(query: document.text, topK: topK)
    }
    
    /// 获取文档
    func get(id: String) -> T? {
        documents[id]
    }
    
    /// 清空
    func clear() {
        documents.removeAll()
        embeddings.removeAll()
    }
    
    private func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count, !v1.isEmpty else { return 0 }
        
        let dotProduct = zip(v1, v2).map { $0 * $1 }.reduce(0, +)
        let mag1 = sqrt(v1.map { $0 * $0 }.reduce(0, +))
        let mag2 = sqrt(v2.map { $0 * $0 }.reduce(0, +))
        
        return mag1 == 0 || mag2 == 0 ? 0 : dotProduct / (mag1 * mag2)
    }
}

/// 向量嵌入服务 - 统一提供文本向量化能力
final class VectorEmbeddingService {
    static let shared = VectorEmbeddingService()
    
    private var embeddingModel: NLEmbedding?
    private let queue = DispatchQueue(label: "embedding.queue", qos: .userInitiated)
    
    private init() {
        // 尝试加载 Apple 的语义嵌入模型
        if #available(macOS 14.0, *) {
            embeddingModel = NLEmbedding.wordEmbedding(for: .english)
            LogInfo("VectorEmbeddingService: 使用 Apple NLEmbedding")
        } else {
            LogWarning("VectorEmbeddingService: 使用回退方案")
        }
    }
    
    /// 文本向量化 - 统一入口
    func embed(_ text: String) -> [Double] {
        // 优先使用 Apple 的模型
        if let model = embeddingModel {
            return embedWithAppleModel(text, model: model)
        }
        
        // 回退到本地方案
        return embedWithLocalModel(text)
    }
    
    /// 批量向量化
    func embedBatch(_ texts: [String]) -> [[Double]] {
        texts.map { embed($0) }
    }
    
    /// 计算文本相似度
    func similarity(between text1: String, and text2: String) -> Double {
        let v1 = embed(text1)
        let v2 = embed(text2)
        return cosineSimilarity(v1, v2)
    }
    
    /// 查找最相似的文本
    func findMostSimilar(query: String, candidates: [String]) -> (String, Double)? {
        let queryVector = embed(query)
        var bestMatch: (String, Double)?
        
        for candidate in candidates {
            let candidateVector = embed(candidate)
            let similarity = cosineSimilarity(queryVector, candidateVector)
            
            if bestMatch == nil || similarity > bestMatch!.1 {
                bestMatch = (candidate, similarity)
            }
        }
        
        return bestMatch
    }
    
    // MARK: - 私有方法
    
    private func embedWithAppleModel(_ text: String, model: NLEmbedding) -> [Double] {
        let tokens = tokenize(text)
        var sumVector: [Double]?
        var count = 0
        
        for token in tokens {
            if let vector = model.vector(for: token.lowercased()) {
                let doubleVector = vector.map { Double($0) }
                
                if sumVector == nil {
                    sumVector = doubleVector
                } else {
                    sumVector = zip(sumVector!, doubleVector).map { $0 + $1 }
                }
                count += 1
            }
        }
        
        guard count > 0, var avgVector = sumVector else {
            return embedWithLocalModel(text)
        }
        
        // 平均并归一化
        avgVector = avgVector.map { $0 / Double(count) }
        return normalize(avgVector)
    }
    
    private func embedWithLocalModel(_ text: String) -> [Double] {
        // 简化的词袋模型 + TF-IDF
        let tokens = tokenize(text)
        var vector: [Double] = []
        
        // 使用预定义的关键词维度
        let dimensions = [
            "文件", "磁盘", "存储", "空间", "清理", "迁移", "移动", "复制", "删除",
            "代码", "分析", "审查", "优化", "重构", "bug", "性能",
            "部署", "发布", "上线", "构建", "测试", "ci/cd",
            "查询", "搜索", "检索", "查找", "定位",
            "创建", "生成", "构建", "制作", "新建",
            "设置", "配置", "调整", "修改", "更新",
            "查看", "显示", "列出", "展示", "统计",
            "帮助", "说明", "文档", "指南", "教程"
        ]
        
        for keyword in dimensions {
            let count = tokens.filter { 
                $0.contains(keyword) || keyword.contains($0) || editDistance($0, keyword) <= 1
            }.count
            vector.append(Double(count))
        }
        
        return normalize(vector)
    }
    
    private func tokenize(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            tokens.append(String(text[range]).lowercased())
            return true
        }
        
        return tokens
    }
    
    private func normalize(_ vector: [Double]) -> [Double] {
        let magnitude = sqrt(vector.map { $0 * $0 }.reduce(0, +))
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }
    
    private func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count, !v1.isEmpty else { return 0 }
        
        let dotProduct = zip(v1, v2).map { $0 * $1 }.reduce(0, +)
        let mag1 = sqrt(v1.map { $0 * $0 }.reduce(0, +))
        let mag2 = sqrt(v2.map { $0 * $0 }.reduce(0, +))
        
        return mag1 == 0 || mag2 == 0 ? 0 : dotProduct / (mag1 * mag2)
    }
    
    private func editDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        let n = s1Array.count
        let m = s2Array.count
        
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        
        for i in 1...n {
            for j in 1...m {
                if s1Array[i-1] == s2Array[j-1] {
                    dp[i][j] = dp[i-1][j-1]
                } else {
                    dp[i][j] = min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1]) + 1
                }
            }
        }
        
        return dp[n][m]
    }
}

// MARK: - 使用示例和扩展

/// 对话消息向量文档
struct MessageDocument: VectorDocument {
    let id: String
    let text: String
    let metadata: [String: String]
    let timestamp: Date
    let role: String
}

/// 记忆向量存储
class MemoryVectorStore {
    static let shared = MemoryVectorStore()
    
    private let store: GenericVectorStore<MessageDocument>
    
    private init() {
        store = GenericVectorStore()
    }
    
    /// 添加对话历史
    func addMessage(_ message: ChatMessage) {
        let doc = MessageDocument(
            id: message.id.uuidString,
            text: message.content,
            metadata: [
                "agentId": message.agentId ?? "",
                "timestamp": "\(message.timestamp)"
            ],
            timestamp: message.timestamp,
            role: message.role.rawValue
        )
        store.add(doc)
    }
    
    /// 检索相关历史
    func retrieveRelevant(to query: String, limit: Int = 5) -> [ChatMessage] {
        let results = store.search(query: query, topK: limit, threshold: 0.3)
        
        // 转换为 ChatMessage（简化版，实际应该从持久化存储获取完整消息）
        return results.map { result in
            ChatMessage(
                id: UUID(uuidString: result.document.id) ?? UUID(),
                role: MessageRole(rawValue: result.document.role) ?? .assistant,
                content: "[相似度: \(String(format: "%.2f", result.score))] \(result.document.text)",
                timestamp: result.document.timestamp
            )
        }
    }
    
    /// 查找相似对话
    func findSimilarMessages(to message: ChatMessage, limit: Int = 3) -> [ChatMessage] {
        let doc = MessageDocument(
            id: message.id.uuidString,
            text: message.content,
            metadata: [:],
            timestamp: message.timestamp,
            role: message.role.rawValue
        )
        
        let results = store.findSimilar(to: doc, topK: limit)
        return results.map { result in
            ChatMessage(
                id: UUID(uuidString: result.document.id) ?? UUID(),
                role: MessageRole(rawValue: result.document.role) ?? .assistant,
                content: result.document.text,
                timestamp: result.document.timestamp
            )
        }
    }
    
    /// 清空记忆
    func clear() {
        store.clear()
    }
}

/// Skill 向量文档
struct SkillDocument: VectorDocument {
    let id: String
    let text: String
    let metadata: [String: String]
    let skillType: String
}

/// 智能 Skill 发现
class SkillVectorMatcher {
    static let shared = SkillVectorMatcher()
    
    private let store: GenericVectorStore<SkillDocument>
    
    private init() {
        store = GenericVectorStore()
        registerAllSkills()
    }
    
    private func registerAllSkills() {
        // 注册所有 AISkill
        for skill in AISkill.allCases {
            let doc = SkillDocument(
                id: "skill_\(skill.rawValue)",
                text: "\(skill.name) \(skill.description)",
                metadata: [
                    "name": skill.name,
                    "type": "builtin"
                ],
                skillType: "builtin"
            )
            store.add(doc)
        }
    }
    
    /// 发现最适合的 Skill
    func discoverSkill(for request: String) -> AISkill? {
        let results = store.search(query: request, topK: 1, threshold: 0.4)
        
        guard let bestMatch = results.first else { return nil }
        
        let skillRawValue = bestMatch.document.id.replacingOccurrences(of: "skill_", with: "")
        return AISkill.allCases.first { $0.rawValue == skillRawValue }
    }
    
    /// 获取多个候选 Skill
    func discoverSkills(for request: String, limit: Int = 3) -> [(skill: AISkill, score: Double)] {
        let results = store.search(query: request, topK: limit, threshold: 0.3)
        
        return results.compactMap { result in
            let skillRawValue = result.document.id.replacingOccurrences(of: "skill_", with: "")
            guard let skill = AISkill.allCases.first(where: { $0.rawValue == skillRawValue }) else {
                return nil
            }
            return (skill, result.score)
        }
    }
}
