//
//  ConversationMemoryManager.swift
//  MacAssistant
//
//  对话记忆管理器 - 蒸馏模式上下文回填系统
//

import Foundation
import NaturalLanguage

// MARK: - 蒸馏后的对话信息

/// 对话条目类型
enum ConversationEntryType: String, Codable {
    case code       // 代码相关
    case file       // 文件操作
    case task       // 任务执行
    case skill      // Skill调用
    case service    // 服务管理
    case query      // 一般查询
    case chitchat   // 闲聊
}

/// 蒸馏后的对话条目 - 提取关键信息
struct DistilledEntry: Codable {
    let id: UUID
    let timestamp: Date
    let role: MessageRole
    let type: ConversationEntryType
    
    // 蒸馏信息
    let keyEntities: [String]      // 关键实体（文件名、服务名、代码片段等）
    let intent: String             // 意图摘要
    let outcome: String?           // 结果/回复摘要
    let rawContent: String         // 原始内容（保留用于详情）
    
    // 关联信息
    let agentID: String?
    let agentName: String?
    let metadata: [String: String]?
}

/// 蒸馏后的记忆上下文
struct DistilledMemoryContext: Codable {
    // 按类型分组的条目
    let codeEntries: [DistilledEntry]
    let fileEntries: [DistilledEntry]
    let taskEntries: [DistilledEntry]
    let skillEntries: [DistilledEntry]
    let serviceEntries: [DistilledEntry]
    let queryEntries: [DistilledEntry]
    
    // 提取的关键信息
    let keyEntities: [String: [String]]  // 类型 -> 实体列表
    let topicEvolution: [String]         // 话题演变
    let activeTasks: [String]            // 进行中的任务
    let lastUserIntent: String?          // 最后用户意图
    
    var isEmpty: Bool {
        codeEntries.isEmpty && 
        fileEntries.isEmpty && 
        taskEntries.isEmpty && 
        skillEntries.isEmpty && 
        serviceEntries.isEmpty && 
        queryEntries.isEmpty
    }
}

// MARK: - 原始对话条目

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

/// 记忆上下文（原始模式 - 用于兼容）
struct MemoryContext: Codable {
    let relevantEntries: [ConversationEntry]
    let summary: String?
    let lastTopic: String?
    let continuityHints: [String]
    
    var isEmpty: Bool { relevantEntries.isEmpty }
}

// MARK: - 上下文格式化扩展

extension DistilledMemoryContext {
    /// 格式化为系统提示词（蒸馏模式）
    func formatForSystemPrompt() -> String {
        var sections: [String] = []
        
        // 1. 话题演变
        if !topicEvolution.isEmpty {
            sections.append("【话题演变】\n" + topicEvolution.joined(separator: " => "))
        }
        
        // 2. 关键实体
        if !keyEntities.isEmpty {
            var entityLines: [String] = []
            for (type, entities) in keyEntities where !entities.isEmpty {
                entityLines.append("- \(type): \(entities.joined(separator: ", "))")
            }
            if !entityLines.isEmpty {
                sections.append("【关键实体】\n" + entityLines.joined(separator: "\n"))
            }
        }
        
        // 3. 代码相关（优先级高）
        if !codeEntries.isEmpty {
            sections.append(formatEntries(codeEntries, title: "代码相关", icon: "CODE"))
        }
        
        // 4. 文件操作
        if !fileEntries.isEmpty {
            sections.append(formatEntries(fileEntries, title: "文件操作", icon: "FILE"))
        }
        
        // 5. 任务执行
        if !taskEntries.isEmpty {
            sections.append(formatEntries(taskEntries, title: "任务执行", icon: "TASK"))
        }
        
        // 6. Skill调用
        if !skillEntries.isEmpty {
            sections.append(formatEntries(skillEntries, title: "Skill调用", icon: "SKILL"))
        }
        
        // 7. 服务管理
        if !serviceEntries.isEmpty {
            sections.append(formatEntries(serviceEntries, title: "服务管理", icon: "SVC"))
        }
        
        // 8. 一般查询（优先级低，只显示最近的）
        if !queryEntries.isEmpty {
            let recentQueries = Array(queryEntries.suffix(2))
            sections.append(formatEntries(recentQueries, title: "近期对话", icon: "CHAT"))
        }
        
        // 9. 进行中的任务
        if !activeTasks.isEmpty {
            sections.append("【进行中】\n- \(activeTasks.joined(separator: "\n- "))")
        }
        
        // 10. 当前意图提示
        if let intent = lastUserIntent {
            sections.append("【当前意图】\n\(intent)")
        }
        
        return sections.joined(separator: "\n\n")
    }
    
    private func formatEntries(_ entries: [DistilledEntry], title: String, icon: String) -> String {
        var lines: [String] = ["[\(icon)] 【\(title)】"]
        
        for entry in entries.suffix(3) {  // 每类最多3条
            let role = entry.role == .user ? "用户" : "助手"
            var line = "- [\(role)] \(entry.intent)"
            
            if !entry.keyEntities.isEmpty {
                line += " (\(entry.keyEntities.joined(separator: ", ")))"
            }
            
            if let outcome = entry.outcome, !outcome.isEmpty {
                line += " [=] \(outcome)"
            }
            
            lines.append(line)
        }
        
        return lines.joined(separator: "\n")
    }
}

// MARK: - 对话记忆管理器

@MainActor
final class ConversationMemoryManager: ObservableObject {
    static let shared = ConversationMemoryManager()
    
    private let maxHistorySize = 100
    private let vectorDimension = 32
    
    @Published private(set) var entries: [ConversationEntry] = []
    private var distilledCache: [UUID: DistilledEntry] = [:]
    private var vectorCache: [String: [Double]] = [:]
    private var sessionIndex: [String: [UUID]] = [:]
    
    private init() {
        loadPersistedEntries()
    }
    
    // MARK: - 核心 API
    
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
        sessionIndex[sessionID, default: []].append(entry.id)
        
        let vector = generateVector(for: content)
        vectorCache[entry.id.uuidString] = vector
        
        if entries.count > maxHistorySize {
            cleanupOldEntries()
        }
        
        persistEntries()
        
        Task {
            let distilled = await distillEntry(entry)
            await MainActor.run {
                self.distilledCache[entry.id] = distilled
            }
        }
        
        LogInfo("MemoryManager: recorded entry=\(entry.id), session=\(sessionID), role=\(role)")
    }
    
    // MARK: - 蒸馏模式检索
    
    func retrieveDistilledContext(
        for query: String,
        currentSessionID: String,
        maxEntries: Int = 10
    ) -> DistilledMemoryContext {
        
        let cutoffTime = Date().addingTimeInterval(-3600)
        
        let sessionEntries = entries
            .filter { $0.sessionID == currentSessionID && $0.timestamp > cutoffTime }
            .sorted { $0.timestamp < $1.timestamp }
        
        var distilledEntries: [DistilledEntry] = []
        for entry in sessionEntries {
            if let distilled = distilledCache[entry.id] {
                distilledEntries.append(distilled)
            } else {
                let distilled = distillEntrySync(entry)
                distilledCache[entry.id] = distilled
                distilledEntries.append(distilled)
            }
        }
        
        let codeEntries = distilledEntries.filter { $0.type == .code }
        let fileEntries = distilledEntries.filter { $0.type == .file }
        let taskEntries = distilledEntries.filter { $0.type == .task }
        let skillEntries = distilledEntries.filter { $0.type == .skill }
        let serviceEntries = distilledEntries.filter { $0.type == .service }
        let queryEntries = distilledEntries.filter { $0.type == .query }
        
        var keyEntities: [String: [String]] = [:]
        for entry in distilledEntries {
            let typeKey = entry.type.rawValue
            var entities = keyEntities[typeKey] ?? []
            entities.append(contentsOf: entry.keyEntities)
            keyEntities[typeKey] = Array(Set(entities)).sorted()
        }
        
        let topicEvolution = extractTopicEvolution(from: distilledEntries)
        let activeTasks = identifyActiveTasks(from: distilledEntries)
        let lastUserIntent = distilledEntries.last { $0.role == .user }?.intent
        
        return DistilledMemoryContext(
            codeEntries: codeEntries,
            fileEntries: fileEntries,
            taskEntries: taskEntries,
            skillEntries: skillEntries,
            serviceEntries: serviceEntries,
            queryEntries: queryEntries,
            keyEntities: keyEntities,
            topicEvolution: topicEvolution,
            activeTasks: activeTasks,
            lastUserIntent: lastUserIntent
        )
    }

    // MARK: - 上下文注入（蒸馏模式）
    
    func prepareDistilledContextPrompt(
        userMessage: String,
        sessionID: String,
        baseSystemPrompt: String? = nil
    ) -> (text: String, systemPrompt: String?) {
        
        let context = retrieveDistilledContext(for: userMessage, currentSessionID: sessionID)
        
        var enhancedSystemPrompt = baseSystemPrompt
        
        if !context.isEmpty {
            let distilledContext = context.formatForSystemPrompt()
            
            if let base = baseSystemPrompt, !base.isEmpty {
                enhancedSystemPrompt = base + "\n\n【对话上下文 - 蒸馏模式】\n" + distilledContext
            } else {
                enhancedSystemPrompt = """
                你是 MacAssistant，一个智能助手。
                
                【对话上下文 - 蒸馏模式】
                \(distilledContext)
                
                请基于以上上下文回答用户的问题。不要说你没有记忆或这是第一次对话。
                """
            }
        } else {
            if enhancedSystemPrompt == nil {
                enhancedSystemPrompt = "你是 MacAssistant，一个运行在 macOS 上的智能助手。"
            }
        }
        
        return (userMessage, enhancedSystemPrompt)
    }
    
    // MARK: - 蒸馏逻辑
    
    private func distillEntry(_ entry: ConversationEntry) async -> DistilledEntry {
        return distillEntrySync(entry)
    }
    
    private func distillEntrySync(_ entry: ConversationEntry) -> DistilledEntry {
        let content = entry.content
        
        let type = classifyEntryType(content: content)
        let entities = extractKeyEntities(from: content, type: type)
        let intent = generateIntentSummary(content: content, type: type, role: entry.role)
        let outcome: String? = entry.role == .assistant ? generateOutcomeSummary(content: content) : nil
        
        return DistilledEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            role: entry.role,
            type: type,
            keyEntities: entities,
            intent: intent,
            outcome: outcome,
            rawContent: content,
            agentID: entry.agentID,
            agentName: entry.agentName,
            metadata: entry.metadata
        )
    }
    
    private func classifyEntryType(content: String) -> ConversationEntryType {
        let lower = content.lowercased()
        
        let codePatterns = ["代码", "code", "函数", "类", "bug", "error", "编译", "syntax", "def ", "func ", "class "]
        if codePatterns.contains(where: lower.contains) {
            return .code
        }
        
        let filePatterns = ["文件", "file", "路径", "path", "目录", "folder", "打开", "读取", "保存"]
        if filePatterns.contains(where: lower.contains) {
            return .file
        }
        
        let taskPatterns = ["任务", "task", "执行", "运行", "处理", "分析", "检查"]
        if taskPatterns.contains(where: lower.contains) {
            return .task
        }
        
        let skillPatterns = ["skill", "技能", "工具", "截图", "翻译", "总结"]
        if skillPatterns.contains(where: lower.contains) {
            return .skill
        }
        
        let servicePatterns = ["服务", "service", "启动", "停止", "重启", "运行中"]
        if servicePatterns.contains(where: lower.contains) {
            return .service
        }
        
        return .query
    }
    
    private func extractKeyEntities(from content: String, type: ConversationEntryType) -> [String] {
        var entities: [String] = []
        
        switch type {
        case .code:
            // 提取代码相关实体
            if content.contains("函数") || content.contains("func ") {
                entities.append("函数定义")
            }
            if content.contains("类") || content.contains("class ") {
                entities.append("类定义")
            }
            if content.contains("bug") || content.contains("error") {
                entities.append("问题修复")
            }
            
        case .file:
            // 提取文件路径
            let filePattern = try? NSRegularExpression(pattern: "[/\\][\\w\\-./]+\\.[\\w]+", options: [])
            if let matches = filePattern?.matches(in: content, options: [], range: NSRange(location: 0, length: content.utf16.count)) {
                for match in matches.prefix(3) {
                    if let range = Range(match.range, in: content) {
                        entities.append(String(content[range]))
                    }
                }
            }
            
        case .service:
            // 提取服务名
            let serviceNames = ["postgresql", "redis", "mysql", "nginx", "mongodb", "rabbitmq"]
            for name in serviceNames {
                if content.lowercased().contains(name) {
                    entities.append(name)
                }
            }
            
        case .skill:
            // 提取技能名
            let skillNames = ["截图", "翻译", "总结", "分析", "explain", "translate", "summarize"]
            for name in skillNames {
                if content.lowercased().contains(name) {
                    entities.append(name)
                }
            }
            
        default:
            break
        }
        
        return entities
    }
    
    private func generateIntentSummary(content: String, type: ConversationEntryType, role: MessageRole) -> String {
        let lower = content.lowercased()
        
        if role == .user {
            // 用户意图
            if lower.contains("查看") || lower.contains("看") {
                return "查看\(type == .service ? "服务状态" : "信息")"
            } else if lower.contains("启动") || lower.contains("开始") {
                return "启动\(type == .service ? "服务" : "任务")"
            } else if lower.contains("停止") || lower.contains("关闭") {
                return "停止\(type == .service ? "服务" : "任务")"
            } else if lower.contains("重启") {
                return "重启服务"
            } else if lower.contains("分析") || lower.contains("检查") {
                return "分析\(type == .code ? "代码" : "问题")"
            } else if lower.contains("帮助") || lower.contains("怎么做") {
                return "寻求帮助"
            } else if lower.contains("记得") || lower.contains("聊过") {
                return "询问对话历史"
            }
        } else {
            // 助手回复摘要
            if lower.contains("完成") || lower.contains("成功") {
                return "任务完成"
            } else if lower.contains("错误") || lower.contains("失败") {
                return "遇到问题"
            } else if lower.contains("建议") {
                return "提供建议"
            }
        }
        
        // 默认摘要
        let prefix = String(content.prefix(20))
        return prefix + (content.count > 20 ? "..." : "")
    }
    
    private func generateOutcomeSummary(content: String) -> String? {
        let lower = content.lowercased()
        
        if lower.contains("完成") || lower.contains("成功") || lower.contains("已") {
            return "已完成"
        } else if lower.contains("失败") || lower.contains("错误") {
            return "执行失败"
        } else if lower.contains("运行中") || lower.contains("进行中") {
            return "运行中"
        }
        
        return nil
    }

    // MARK: - 话题演变与任务识别
    
    private func extractTopicEvolution(from entries: [DistilledEntry]) -> [String] {
        var topics: [String] = []
        var lastType: ConversationEntryType?
        
        for entry in entries where entry.role == .user {
            if entry.type != lastType {
                let topic = topicName(for: entry.type)
                if !topics.contains(topic) {
                    topics.append(topic)
                }
                lastType = entry.type
            }
        }
        
        return topics
    }
    
    private func topicName(for type: ConversationEntryType) -> String {
        switch type {
        case .code: return "代码开发"
        case .file: return "文件操作"
        case .task: return "任务执行"
        case .skill: return "技能调用"
        case .service: return "服务管理"
        case .query: return "一般查询"
        case .chitchat: return "闲聊"
        }
    }
    
    private func identifyActiveTasks(from entries: [DistilledEntry]) -> [String] {
        var tasks: [String] = []
        
        // 查找未完成的任务
        let taskEntries = entries.filter { $0.type == .task || $0.type == .skill }
        
        for entry in taskEntries.suffix(3) {
            if entry.outcome == nil || entry.outcome == "运行中" {
                tasks.append(entry.intent)
            }
        }
        
        return tasks
    }
    
    // MARK: - 向量计算
    
    private func generateVector(for text: String) -> [Double] {
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
            LogError("MemoryManager: persist failed \(error)")
        }
    }
    
    private func loadPersistedEntries() {
        guard let data = UserDefaults.standard.data(forKey: "conversation_memory_entries") else {
            return
        }
        
        do {
            entries = try JSONDecoder().decode([ConversationEntry].self, from: data)
            
            for entry in entries {
                sessionIndex[entry.sessionID, default: []].append(entry.id)
                vectorCache[entry.id.uuidString] = generateVector(for: entry.content)
            }
            
            LogInfo("MemoryManager: loaded \(entries.count) entries")
        } catch {
            LogError("MemoryManager: load failed \(error)")
        }
    }
    
    private func cleanupOldEntries() {
        let cutoff = Date().addingTimeInterval(-86400 * 7)
        entries.removeAll { $0.timestamp < cutoff }
        
        let validIDs = Set(entries.map { $0.id.uuidString })
        vectorCache = vectorCache.filter { validIDs.contains($0.key) }
        distilledCache = distilledCache.filter { validIDs.contains($0.key.uuidString) }
        
        sessionIndex.removeAll()
        for entry in entries {
            sessionIndex[entry.sessionID, default: []].append(entry.id)
        }
    }
    
    // MARK: - 兼容旧API（保留）
    
    func getSessionHistory(sessionID: String, limit: Int = 50) -> [ConversationEntry] {
        return entries
            .filter { $0.sessionID == sessionID }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(limit)
    }
    
    func getRecentEntries(count: Int = 10) -> [ConversationEntry] {
        return entries.suffix(count)
    }
    
    func clearHistory() {
        entries.removeAll()
        vectorCache.removeAll()
        distilledCache.removeAll()
        sessionIndex.removeAll()
        persistEntries()
    }
    
    func clearSessionHistory(sessionID: String) {
        entries.removeAll { $0.sessionID == sessionID }
        let validIDs = Set(entries.map { $0.id.uuidString })
        vectorCache = vectorCache.filter { validIDs.contains($0.key) }
        distilledCache = distilledCache.filter { validIDs.contains($0.key.uuidString) }
        sessionIndex.removeValue(forKey: sessionID)
        persistEntries()
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
    
    /// 为请求准备带蒸馏记忆的上下文（新模式）
    @MainActor
    func prepareRequestWithDistilledMemory(
        text: String,
        sessionID: String? = nil,
        baseSystemPrompt: String? = nil
    ) -> (text: String, systemPrompt: String?) {
        let memory = ConversationMemoryManager.shared
        
        let session = sessionID ?? "main_session"
        
        return memory.prepareDistilledContextPrompt(
            userMessage: text,
            sessionID: session,
            baseSystemPrompt: baseSystemPrompt
        )
    }
    
    /// 为请求准备带记忆的上下文（兼容旧模式）
    @MainActor
    func prepareRequestWithMemory(
        text: String,
        sessionID: String? = nil,
        systemPrompt: String? = nil
    ) -> (text: String, systemPrompt: String?) {
        // 使用新的蒸馏模式
        return prepareRequestWithDistilledMemory(
            text: text,
            sessionID: sessionID,
            baseSystemPrompt: systemPrompt
        )
    }
}
