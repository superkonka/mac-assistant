//
//  ContentDistiller.swift
//  内容蒸馏器 - 从对话中提取关键信息
//

import Foundation

/// 蒸馏后的内容
struct DistilledContent: Codable {
    let id: UUID
    let originalMessageId: UUID?
    let topic: String
    let intent: String
    let entities: [String]
    let conclusion: String
    let keywords: [String]
    let timestamp: Date
    let confidence: Double
}

/// 对话上下文
struct ConversationContext {
    let previousMessages: [ChatMessage]
    let currentTopic: String?
    let userIntent: String?
}

/// 内容蒸馏器
class ContentDistiller {
    
    /// 蒸馏单条消息
    func distill(_ message: ChatMessage, context: ConversationContext?) -> DistilledContent? {
        // 只蒸馏助手回复（包含答案）
        guard message.role == .assistant else { return nil }
        
        let content = message.content
        
        // 提取主题
        let topic = extractTopic(from: content, context: context)
        
        // 提取意图
        let intent = extractIntent(from: content, context: context)
        
        // 提取实体
        let entities = extractEntities(from: content)
        
        // 提取结论
        let conclusion = extractConclusion(from: content)
        
        // 提取关键词
        let keywords = extractKeywords(from: content)
        
        // 计算置信度
        let confidence = calculateConfidence(
            content: content,
            hasConclusion: !conclusion.isEmpty,
            entityCount: entities.count
        )
        
        // 置信度太低则不保存
        guard confidence > 0.5 else { return nil }
        
        return DistilledContent(
            id: UUID(),
            originalMessageId: message.id,
            topic: topic,
            intent: intent,
            entities: entities,
            conclusion: conclusion,
            keywords: keywords,
            timestamp: message.timestamp,
            confidence: confidence
        )
    }
    
    /// 批量蒸馏对话
    func distillConversation(_ messages: [ChatMessage]) -> [DistilledContent] {
        var distilledItems: [DistilledContent] = []
        
        for (index, message) in messages.enumerated() {
            let context = ConversationContext(
                previousMessages: Array(messages.prefix(index)),
                currentTopic: distilledItems.last?.topic,
                userIntent: nil
            )
            
            if let distilled = distill(message, context: context) {
                distilledItems.append(distilled)
            }
        }
        
        return distilledItems
    }
    
    /// 生成知识条目
    func generateKnowledge(from contents: [DistilledContent]) -> KnowledgeItem? {
        guard !contents.isEmpty else { return nil }
        
        // 按主题分组
        let groupedByTopic = Dictionary(grouping: contents) { $0.topic }
        
        // 选择最频繁的主题
        guard let (topic, topicContents) = groupedByTopic.max(by: { $0.value.count < $1.value.count }) else {
            return nil
        }
        
        // 合并结论
        let conclusions = topicContents.compactMap { $0.conclusion.isEmpty ? nil : $0.conclusion }
        let mergedContent = conclusions.joined(separator: "\n\n")
        
        // 合并关键词
        var allKeywords: Set<String> = []
        for content in topicContents {
            allKeywords.formUnion(content.keywords)
        }
        
        // 计算相关性分数
        let avgConfidence = topicContents.map { $0.confidence }.reduce(0, +) / Double(topicContents.count)
        
        return KnowledgeItem(
            id: UUID(),
            topic: topic,
            content: mergedContent,
            keywords: Array(allKeywords),
            sourceMessageIds: topicContents.compactMap { $0.originalMessageId },
            createdAt: Date(),
            updatedAt: Date(),
            version: 1,
            relevanceScore: avgConfidence
        )
    }
    
    // MARK: - 私有提取方法
    
    private func extractTopic(from content: String, context: ConversationContext?) -> String {
        // 检查是否是代码相关
        if content.contains("```") || content.contains("代码") || content.contains("function") {
            return "编程/代码"
        }
        
        // 检查是否是配置相关
        if content.contains("配置") || content.contains("设置") || content.contains("config") {
            return "配置/设置"
        }
        
        // 检查是否是错误相关
        if content.contains("错误") || content.contains("error") || content.contains("失败") {
            return "错误排查"
        }
        
        // 检查是否是教程/步骤
        if content.contains("步骤") || content.contains("教程") || content.contains("如何") {
            return "教程/指南"
        }
        
        // 默认从上下文中继承或使用通用主题
        return context?.currentTopic ?? "一般对话"
    }
    
    private func extractIntent(from content: String, context: ConversationContext?) -> String {
        // 识别意图类型
        if content.hasPrefix("错误") || content.contains("无法") {
            return "问题解决"
        }
        
        if content.contains("可以") || content.contains("建议") || content.hasPrefix("建议") {
            return "建议/推荐"
        }
        
        if content.contains("解释") || content.contains("说明") {
            return "解释说明"
        }
        
        if content.contains("首先") || content.contains("然后") || content.contains("最后") {
            return "操作指导"
        }
        
        return "信息提供"
    }
    
    private func extractEntities(from content: String) -> [String] {
        var entities: [String] = []
        
        // 提取代码块中的函数名、变量名
        let codePattern = "`([^`]+)`"
        if let regex = try? NSRegularExpression(pattern: codePattern) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let range = Range(match.range(at: 1), in: content) {
                    entities.append(String(content[range]))
                }
            }
        }
        
        // 提取文件路径
        let pathPattern = "(/[\\w/\\.]+)"
        if let regex = try? NSRegularExpression(pattern: pathPattern) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let range = Range(match.range(at: 1), in: content) {
                    let path = String(content[range])
                    if !entities.contains(path) {
                        entities.append(path)
                    }
                }
            }
        }
        
        // 提取URL
        let urlPattern = "(https?://[^\\s]+)"
        if let regex = try? NSRegularExpression(pattern: urlPattern) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let range = Range(match.range(at: 1), in: content) {
                    entities.append(String(content[range]))
                }
            }
        }
        
        return entities
    }
    
    private func extractConclusion(from content: String) -> String {
        // 查找总结性语句
        let summaryIndicators = ["总结", "结论", "因此", "所以", "总之", "综上"]
        let lines = content.split(separator: "\n")
        
        for line in lines {
            let lineString = String(line).trimmingCharacters(in: .whitespaces)
            for indicator in summaryIndicators {
                if lineString.contains(indicator) {
                    return lineString
                }
            }
        }
        
        // 如果没有找到总结，返回最后一段（通常是结论）
        if let lastParagraph = lines.last {
            let paragraph = String(lastParagraph).trimmingCharacters(in: .whitespaces)
            if paragraph.count > 10 && paragraph.count < 200 {
                return paragraph
            }
        }
        
        return ""
    }
    
    private func extractKeywords(from content: String) -> [String] {
        var keywords: [String] = []
        let lowerContent = content.lowercased()
        
        // 技术关键词
        let techKeywords = [
            "swift", "python", "javascript", "ios", "macos", "xcode",
            "git", "docker", "sql", "api", "json", "xml",
            "服务器", "客户端", "数据库", "缓存", "异步"
        ]
        
        for keyword in techKeywords {
            if lowerContent.contains(keyword) && !keywords.contains(keyword) {
                keywords.append(keyword)
            }
        }
        
        // 动作关键词
        let actionKeywords = [
            "配置", "安装", "部署", "调试", "优化", "修复",
            "创建", "删除", "更新", "查询", "导入", "导出"
        ]
        
        for keyword in actionKeywords {
            if content.contains(keyword) && !keywords.contains(keyword) {
                keywords.append(keyword)
            }
        }
        
        return keywords
    }
    
    private func calculateConfidence(content: String, hasConclusion: Bool, entityCount: Int) -> Double {
        var score = 0.5
        
        // 有结论增加置信度
        if hasConclusion {
            score += 0.2
        }
        
        // 有实体增加置信度
        score += min(Double(entityCount) * 0.05, 0.15)
        
        // 内容长度适中增加置信度
        let length = content.count
        if length > 100 && length < 2000 {
            score += 0.1
        }
        
        // 包含结构化内容（代码块、列表）增加置信度
        if content.contains("```") || content.contains("1.") || content.contains("-") {
            score += 0.05
        }
        
        return min(score, 1.0)
    }
}
