//
//  TaskCreationPlanner.swift
//  MacAssistant
//
//  任务创建规划器 - 智能决策是创建新任务、沿用还是追加到现有任务
//

import Foundation
import NaturalLanguage

@MainActor
final class TaskCreationPlanner {
    static let shared = TaskCreationPlanner()
    
    private let taskManager = TaskManager.shared
    private let intentMatcher = IntentMatcher.shared
    private let embeddingService = VectorEmbeddingService.shared
    
    private init() {}
    
    // MARK: - 核心决策方法
    
    /// 决定如何创建任务：新建、沿用或追加
    func decideTaskCreation(for userInput: String) async -> TaskCreationDecision {
        LogInfo("[TaskCreationPlanner] 分析任务创建请求: \(userInput.prefix(50))...")
        
        // 1. 分析用户意图
        let intent = analyzeIntent(userInput)
        
        // 2. 生成输入的向量嵌入
        let inputEmbedding = await embeddingService.embedText(userInput)
        
        // 3. 获取所有相关任务
        let allTasks = getAllRelevantTasks()
        
        // 4. 计算与现有任务的相似度
        var taskSimilarities: [(task: TaskItem, similarity: Double, matchType: TaskMatchType)] = []
        
        for task in allTasks {
            let similarity = await calculateSimilarity(
                input: userInput,
                inputEmbedding: inputEmbedding,
                task: task
            )
            
            if similarity > 0.3 { // 只考虑有一定相关性的
                let matchType = determineMatchType(
                    input: userInput,
                    task: task,
                    similarity: similarity
                )
                taskSimilarities.append((task, similarity, matchType))
            }
        }
        
        // 5. 按相似度排序
        taskSimilarities.sort { $0.similarity > $1.similarity }
        
        // 6. 决策逻辑
        return makeDecision(
            userInput: userInput,
            intent: intent,
            taskSimilarities: taskSimilarities
        )
    }
    
    // MARK: - 意图分析
    
    private func analyzeIntent(_ input: String) -> TaskIntent {
        let normalized = input.lowercased()
        
        // 检查是否是"继续"类意图
        let continuationKeywords = ["继续", "接着", "跟进", "完成", "做完", "还有", "剩下的"]
        let isContinuation = continuationKeywords.contains { normalized.contains($0) }
        
        // 检查是否是"查看"类意图
        let checkKeywords = ["查看", "状态", "进度", "怎么样了", "结果"]
        let isCheckStatus = checkKeywords.contains { normalized.contains($0) }
        
        // 检查是否是"新"意图
        let newKeywords = ["新建", "新", "创建", "开始", "启动", "另一个", "别的"]
        let isNewTask = newKeywords.contains { normalized.contains($0) }
        
        // 检查输入复杂度
        let complexityScore = calculateComplexity(input)
        
        return TaskIntent(
            isContinuation: isContinuation,
            isCheckStatus: isCheckStatus,
            isNewTask: isNewTask,
            complexityScore: complexityScore
        )
    }
    
    private func calculateComplexity(_ input: String) -> Double {
        // 基于长度、词汇量等计算复杂度
        let wordCount = input.split(separator: " ").count + input.count / 4 // 粗略中文字数估算
        let hasMultipleActions = ["然后", "接着", "再", "并且", "同时"].contains { input.contains($0) }
        
        var score = min(Double(wordCount) / 20.0, 1.0) // 长度因子
        if hasMultipleActions { score += 0.3 }
        
        return min(score, 1.0)
    }
    
    // MARK: - 相似度计算
    
    private func calculateSimilarity(
        input: String,
        inputEmbedding: [Float],
        task: TaskItem
    ) async -> Double {
        var similarities: [Double] = []
        
        // 1. 基于向量嵌入的语义相似度
        let taskText = "\(task.title) \(task.description) \(task.inputContext)"
        let taskEmbedding = await embeddingService.embedText(taskText)
        let embeddingSimilarity = cosineSimilarity(inputEmbedding, taskEmbedding)
        similarities.append(embeddingSimilarity)
        
        // 2. 基于关键词的匹配
        let keywordSimilarity = calculateKeywordSimilarity(input, task: task)
        similarities.append(keywordSimilarity)
        
        // 3. 类型匹配度
        let typeSimilarity = calculateTypeSimilarity(input, task: task)
        similarities.append(typeSimilarity)
        
        // 加权平均
        let weights = [0.5, 0.3, 0.2]
        let weightedSum = zip(similarities, weights).map(*).reduce(0, +)
        let totalWeight = weights.reduce(0, +)
        
        return weightedSum / totalWeight
    }
    
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        
        let dotProduct = zip(a, b).map { Double($0) * Double($1) }.reduce(0, +)
        let normA = sqrt(a.map { Double($0) * Double($0) }.reduce(0, +))
        let normB = sqrt(b.map { Double($0) * Double($0) }.reduce(0, +))
        
        guard normA > 0 && normB > 0 else { return 0 }
        
        return dotProduct / (normA * normB)
    }
    
    private func calculateKeywordSimilarity(_ input: String, task: TaskItem) -> Double {
        let inputKeywords = extractKeywords(input)
        let taskKeywords = extractKeywords("\(task.title) \(task.description)")
        
        guard !inputKeywords.isEmpty, !taskKeywords.isEmpty else { return 0 }
        
        let common = Set(inputKeywords).intersection(Set(taskKeywords))
        let union = Set(inputKeywords).union(Set(taskKeywords))
        
        return Double(common.count) / Double(union.count)
    }
    
    private func extractKeywords(_ text: String) -> [String] {
        // 简单的关键词提取 - 去除停用词
        let stopWords = Set(["的", "了", "是", "我", "有", "和", "就", "不", "人", "都", "一", "一个", "上", "也", "很", "到", "说", "要", "去", "你", "会", "着", "没有", "看", "好", "自己", "这", "那"])
        
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
            .filter { !stopWords.contains($0) }
        
        return words
    }
    
    private func calculateTypeSimilarity(_ input: String, task: TaskItem) -> Double {
        // 根据任务类型和输入内容判断匹配度
        let typeKeywords: [SubtaskType: [String]] = [
            .diskAnalysis: ["磁盘", "空间", "存储", "分析", "占用"],
            .diskCleanup: ["清理", "删除", "垃圾", "释放", "缓存"],
            .fileOperation: ["文件", "移动", "复制", "重命名", "整理"],
            .codeAnalysis: ["代码", "分析", "审查", "质量", "bug", "问题"],
            .codeGeneration: ["生成", "写代码", "创建", "实现", "编写"],
            .codeReview: ["review", "评审", "review", "检查代码"],
            .securityScan: ["安全", "扫描", "漏洞", "风险"],
            .deployment: ["部署", "发布", "上线", "deploy"],
            .custom: []
        ]
        
        guard let keywords = typeKeywords[task.type] else { return 0 }
        
        let matches = keywords.filter { input.lowercased().contains($0) }
        return Double(matches.count) / Double(max(keywords.count, 1))
    }
    
    private func determineMatchType(
        input: String,
        task: TaskItem,
        similarity: Double
    ) -> TaskMatchType {
        // 判断是精确匹配、相似主题还是弱相关
        if similarity > 0.85 {
            return .exact
        } else if similarity > 0.6 {
            return .similarTopic
        } else {
            return .weaklyRelated
        }
    }
    
    // MARK: - 决策逻辑
    
    private func makeDecision(
        userInput: String,
        intent: TaskIntent,
        taskSimilarities: [(task: TaskItem, similarity: Double, matchType: TaskMatchType)]
    ) -> TaskCreationDecision {
        
        // 策略1：如果明确表达"新建"意图，创建新任务
        if intent.isNewTask && !intent.isContinuation {
            return createNewTaskDecision(for: userInput)
        }
        
        // 策略2：如果表达"继续"意图且有高匹配任务，沿用或追加
        if intent.isContinuation {
            if let bestMatch = taskSimilarities.first,
               bestMatch.similarity > 0.7 {
                return createAppendDecision(
                    userInput: userInput,
                    task: bestMatch.task,
                    similarity: bestMatch.similarity
                )
            }
        }
        
        // 策略3：如果有精确匹配的任务（相似度>0.85），建议沿用
        if let exactMatch = taskSimilarities.first(where: { $0.matchType == .exact }) {
            // 检查任务状态
            if exactMatch.task.status == .completed {
                return createAppendDecision(
                    userInput: userInput,
                    task: exactMatch.task,
                    similarity: exactMatch.similarity
                )
            } else {
                return createUseExistingDecision(
                    userInput: userInput,
                    task: exactMatch.task,
                    similarity: exactMatch.similarity
                )
            }
        }
        
        // 策略4：如果有相似主题（相似度>0.6），建议追加
        if let similarMatch = taskSimilarities.first(where: { $0.similarity > 0.6 }) {
            return createAppendDecision(
                userInput: userInput,
                task: similarMatch.task,
                similarity: similarMatch.similarity
            )
        }
        
        // 策略5：默认创建新任务
        return createNewTaskDecision(for: userInput)
    }
    
    // MARK: - 决策构造
    
    private func createNewTaskDecision(for userInput: String) -> TaskCreationDecision {
        // 生成建议标题和描述
        let suggestedTitle = generateTaskTitle(from: userInput)
        let suggestedDescription = generateTaskDescription(from: userInput)
        
        return TaskCreationDecision(
            action: .createNew,
            targetTask: nil,
            suggestedTitle: suggestedTitle,
            suggestedDescription: suggestedDescription,
            reasoning: "未找到高度匹配的现有任务，建议创建新任务以更好地跟踪和管理。",
            confidence: 0.8
        )
    }
    
    private func createUseExistingDecision(
        userInput: String,
        task: TaskItem,
        similarity: Double
    ) -> TaskCreationDecision {
        return TaskCreationDecision(
            action: .useExisting,
            targetTask: task,
            suggestedTitle: task.title,
            suggestedDescription: task.description,
            reasoning: "找到高度匹配的任务「\(task.title)」（相似度\(Int(similarity * 100))%），该任务当前状态为\(task.status.displayName)。",
            confidence: similarity
        )
    }
    
    private func createAppendDecision(
        userInput: String,
        task: TaskItem,
        similarity: Double
    ) -> TaskCreationDecision {
        return TaskCreationDecision(
            action: .appendToExisting,
            targetTask: task,
            suggestedTitle: task.title,
            suggestedDescription: "\(task.description)\n追加: \(userInput.prefix(100))",
            reasoning: "你的需求与现有任务「\(task.title)」相关（相似度\(Int(similarity * 100))%），建议追加到该任务以保持上下文连贯。",
            confidence: similarity
        )
    }
    
    // MARK: - 辅助方法
    
    private func getAllRelevantTasks() -> [TaskItem] {
        // 获取所有非已销毁的任务
        let pending = taskManager.pendingTasks
        let running = taskManager.runningTasks
        let completed = taskManager.completedTasks.filter { task in
            // 只保留最近7天内完成的任务
            let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            return task.updatedAt > sevenDaysAgo
        }
        
        return pending + running + completed
    }
    
    private func generateTaskTitle(from input: String) -> String {
        // 智能生成标题 - 提取核心意图
        let maxLength = 30
        
        // 尝试提取动词+名词结构
        let patterns = [
            "帮我(.*?)(?:[，,。]|$)",
            "需要(.*?)(?:[，,。]|$)",
            "把(.*?)(?:[，,。]|$)",
            "对(.*?)(?:[，,。]|$)"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: input, options: [], range: NSRange(location: 0, length: input.utf16.count)) {
                let range = match.range(at: 1)
                if let swiftRange = Range(range, in: input) {
                    let extracted = String(input[swiftRange]).trimmingCharacters(in: .whitespaces)
                    if !extracted.isEmpty {
                        return extracted.count > maxLength ? String(extracted.prefix(maxLength)) + "..." : extracted
                    }
                }
            }
        }
        
        // 默认截取前30个字符
        if input.count <= maxLength {
            return input
        }
        return String(input.prefix(maxLength)) + "..."
    }
    
    private func generateTaskDescription(from input: String) -> String {
        // 生成更详细的描述
        let maxLength = 200
        if input.count <= maxLength {
            return input
        }
        return String(input.prefix(maxLength)) + "..."
    }
}

// MARK: - 辅助类型

struct TaskIntent {
    let isContinuation: Bool
    let isCheckStatus: Bool
    let isNewTask: Bool
    let complexityScore: Double
}

enum TaskMatchType {
    case exact           // 精确匹配
    case similarTopic    // 相似主题
    case weaklyRelated   // 弱相关
}

// MARK: - 向量转换扩展

extension VectorEmbeddingService {
    /// 异步嵌入文本（转换为 Float 数组以匹配接口）
    func embedText(_ text: String) async -> [Float] {
        let embedding = embed(text)
        return embedding.map { Float($0) }
    }
}
