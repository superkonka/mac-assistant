//
//  IntentMatcher.swift
//  MacAssistant
//
//  基于向量的意图匹配系统 - 使用统一 VectorEmbeddingService
//

import Foundation
import NaturalLanguage

/// 能力向量表示
struct CapabilityVector: Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let keywords: [String]
    let vector: [Double]  // 预计算的向量
    let type: CapabilityType
    
    enum CapabilityType: String, Codable {
        case builtin        // 内置功能
        case skill          // 内置 Skill
        case agent          // Agent
        case openClawSkill  // OpenClaw Skill
    }
}

/// 意图匹配结果
struct IntentMatch: Comparable {
    let capability: CapabilityVector
    let score: Double
    let matchedKeywords: [String]
    
    static func < (lhs: IntentMatch, rhs: IntentMatch) -> Bool {
        lhs.score < rhs.score
    }
}

/// 意图匹配器 - 基于 VectorEmbeddingService
final class IntentMatcher {
    static let shared = IntentMatcher()
    
    private var capabilityRegistry: [CapabilityVector] = []
    private let embeddingService = VectorEmbeddingService.shared
    
    private init() {
        setupCapabilityRegistry()
    }
    
    // MARK: - 注册系统能力
    
    private func setupCapabilityRegistry() {
        registerBuiltinCapabilities()
        registerSkillCapabilities()
        
        // 延迟加载 Agents，避免初始化循环
        Task { @MainActor in
            await refreshAgentCapabilities()
        }
    }
    
    private func registerBuiltinCapabilities() {
        let builtins: [(String, String, [String], CapabilityVector.CapabilityType)] = [
            (
                "disk_manager_analyze",
                "分析磁盘空间使用情况，扫描文件分布，识别大文件和可清理项",
                ["磁盘", "空间", "分析", "文件", "清理", "迁移", "存储", "容量", "占用", "大文件", "扫描"],
                .builtin
            ),
            (
                "disk_manager_cleanup",
                "清理系统缓存、临时文件和垃圾文件，释放磁盘空间",
                ["清理", "缓存", "临时文件", "垃圾", "释放空间", "优化", "删除", "腾出空间"],
                .builtin
            ),
            (
                "resource_analyzer",
                "智能分析资源分布，发现大文件，提供优化建议",
                ["分析", "资源", "大文件", "扫描", "统计", "分布", "占用", "优化"],
                .builtin
            ),
            (
                "file_operations",
                "执行文件操作，移动、复制、删除、整理文件",
                ["文件", "移动", "复制", "删除", "迁移", "转移", "整理", "操作", "管理"],
                .builtin
            ),
            (
                "system_commands",
                "执行系统命令和脚本，调用命令行工具",
                ["命令", "脚本", "终端", "执行", "运行", "shell", "bash", "命令行"],
                .builtin
            ),
            (
                "app_launcher",
                "启动应用程序，打开软件，管理进程",
                ["打开", "启动", "应用", "软件", "程序", "app", "运行", "关闭"],
                .builtin
            )
        ]
        
        for (id, desc, keywords, type) in builtins {
            let vector = embeddingService.embed(desc + " " + keywords.joined(separator: " "))
            capabilityRegistry.append(CapabilityVector(
                id: id,
                name: id,
                description: desc,
                keywords: keywords,
                vector: vector,
                type: type
            ))
        }
    }
    
    private func registerSkillCapabilities() {
        // 为每个 Skill 定义精准的关键词，避免模糊匹配
        let skillKeywords: [AISkill: [String]] = [
            .screenshot: ["截图", "屏幕", "拍照", "capture", "screen", "snapshot", "图像识别"],
            .analyzeDisk: ["磁盘", "硬盘", "存储", "空间", "容量", "disk", "storage", "清理", "大文件"],
            .codeReview: ["代码", "审查", "review", "code", "质量", "优化建议"],
            .explainSelection: ["解释", "选中", "selection", "说明", "含义"],
            .translateText: ["翻译", "translate", "语言", "英文", "中文", "转换"],
            .summarizeText: ["总结", "摘要", "summarize", "概括", "核心内容"]
        ]
        
        for skill in AISkill.allCases {
            // 使用预定义的关键词，避免提取出模糊词汇
            let keywords = skillKeywords[skill] ?? extractKeywords(from: skill.name + " " + skill.description)
            // 向量化时优先使用关键词，让语义更精准
            let vectorText = skill.name + " " + keywords.joined(separator: " ")
            let vector = embeddingService.embed(vectorText)
            
            capabilityRegistry.append(CapabilityVector(
                id: "skill_\(skill.rawValue)",
                name: skill.name,
                description: skill.description,
                keywords: keywords,
                vector: vector,
                type: .skill
            ))
        }
    }
    
    @MainActor
    func refreshAgentCapabilities() async {
        let agentStore = AgentStore.shared
        
        // 移除旧的 Agent 能力
        capabilityRegistry.removeAll { $0.type == .agent }
        
        // 添加当前所有 Agent
        for agent in agentStore.agents {
            let desc = "\(agent.name): \(agent.description)"
            let capabilities = agent.capabilities.map { $0.rawValue }.joined(separator: " ")
            let vector = embeddingService.embed(desc + " " + capabilities)
            
            capabilityRegistry.append(CapabilityVector(
                id: "agent_\(agent.id)",
                name: agent.name,
                description: agent.description,
                keywords: agent.capabilities.map { $0.rawValue },
                vector: vector,
                type: .agent
            ))
        }
        
        LogInfo("IntentMatcher: 已注册 \(capabilityRegistry.count) 个能力")
    }
    
    // MARK: - 意图匹配
    
    /// 匹配用户输入到最合适的能力
    func matchIntent(_ userInput: String, threshold: Double = 0.5) -> [IntentMatch] {
        let inputVector = embeddingService.embed(userInput)
        let inputTokens = tokenize(userInput)
        
        var matches: [IntentMatch] = []
        
        for capability in capabilityRegistry {
            // 1. 计算语义向量相似度（使用统一服务）
            let semanticScore = cosineSimilarity(inputVector, capability.vector)
            
            // 2. 计算关键词匹配分数
            let keywordScore = calculateKeywordMatch(inputTokens, capability.keywords)
            
            // 3. 加权组合
            let finalScore = semanticScore * 0.6 + keywordScore * 0.4
            
            if finalScore >= threshold {
                let matchedKeywords = capability.keywords.filter { keyword in
                    inputTokens.contains { $0.contains(keyword) || keyword.contains($0) }
                }
                
                matches.append(IntentMatch(
                    capability: capability,
                    score: finalScore,
                    matchedKeywords: matchedKeywords
                ))
            }
        }
        
        return matches.sorted(by: >)
    }
    
    /// 匹配单个最佳能力
    func matchBestIntent(_ userInput: String, threshold: Double = 0.5) -> IntentMatch? {
        matchIntent(userInput, threshold: threshold).first
    }
    
    /// 匹配多个相关能力（用于任务拆解）
    /// - 提高阈值避免无关匹配
    /// - 去重避免同类技能重复执行
    func matchMultipleIntents(_ userInput: String, maxResults: Int = 2, threshold: Double = 0.55) -> [IntentMatch] {
        let allMatches = matchIntent(userInput, threshold: threshold)
        
        // 去重：同一 domain 的技能只保留得分最高的
        var seenDomains: Set<String> = []
        var uniqueMatches: [IntentMatch] = []
        
        for match in allMatches {
            let domain = extractDomain(from: match.capability.id)
            if !seenDomains.contains(domain) {
                seenDomains.insert(domain)
                uniqueMatches.append(match)
                
                if uniqueMatches.count >= maxResults {
                    break
                }
            }
        }
        
        return uniqueMatches
    }
    
    /// 提取 domain 用于去重
    private func extractDomain(from capabilityID: String) -> String {
        // disk_manager_analyze -> disk
        // resource_analyzer -> resource
        // skill_screenshot -> screenshot
        if capabilityID.hasPrefix("skill_") {
            return capabilityID.replacingOccurrences(of: "skill_", with: "")
        }
        if capabilityID.hasPrefix("agent_") {
            return "agent"
        }
        // 提取前缀作为 domain
        let components = capabilityID.split(separator: "_")
        if components.count >= 1 {
            return String(components[0])
        }
        return capabilityID
    }
    
    // MARK: - 辅助方法
    
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
    
    private func calculateKeywordMatch(_ inputTokens: [String], _ keywords: [String]) -> Double {
        if keywords.isEmpty { return 0 }
        
        var matchCount = 0
        for keyword in keywords {
            let keywordLower = keyword.lowercased()
            if inputTokens.contains(keywordLower) {
                matchCount += 1
            } else {
                // 模糊匹配
                for token in inputTokens {
                    if token.contains(keywordLower) || keywordLower.contains(token) {
                        matchCount += 1
                        break
                    }
                }
            }
        }
        
        return Double(matchCount) / Double(keywords.count)
    }
    
    private func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count, !v1.isEmpty else { return 0 }
        
        let dotProduct = zip(v1, v2).map { $0 * $1 }.reduce(0, +)
        let mag1 = sqrt(v1.map { $0 * $0 }.reduce(0, +))
        let mag2 = sqrt(v2.map { $0 * $0 }.reduce(0, +))
        
        return mag1 == 0 || mag2 == 0 ? 0 : dotProduct / (mag1 * mag2)
    }
    
    private func extractKeywords(from text: String) -> [String] {
        let tokens = tokenize(text)
        let stopWords = Set(["的", "了", "在", "是", "我", "有", "和", "就", "不", "人", "都", "一", "一个", "上", "也", "很", "到", "说", "要", "去", "你", "会", "着", "没有", "看", "好", "自己", "这"])
        return tokens.filter { !$0.isEmpty && !stopWords.contains($0) }
    }
}

// MARK: - 扩展 SubtaskCoordinator 使用意图匹配

extension SubtaskCoordinator {
    
    /// 基于向量意图匹配的智能任务拆解
    /// - 只在高置信度匹配时才拆解
    /// - 避免过度拆分简单请求
    @MainActor
    func analyzeAndDecomposeWithIntentMatching(request: String) -> [Subtask] {
        let matcher = IntentMatcher.shared
        
        // 先尝试单一最佳匹配
        if let bestMatch = matcher.matchBestIntent(request, threshold: 0.7) {
            // 如果最佳匹配置信度足够高，不拆解，直接执行
            let parentID = UUID().uuidString
            let subtask = createSubtaskFromMatch(bestMatch, index: 0, parentID: parentID, request: request)
            addSubtasks([subtask])
            LogInfo("意图匹配: 单一高置信度匹配 \(bestMatch.capability.name) (\(String(format: "%.2f", bestMatch.score)))")
            return [subtask]
        }
        
        // 否则尝试多意图匹配（需要多个相关能力）
        let matches = matcher.matchMultipleIntents(request, maxResults: 2, threshold: 0.55)
        
        guard !matches.isEmpty else {
            return [createGenericSubtask(request: request)]
        }
        
        // 如果只有一个匹配，不拆解
        if matches.count == 1 {
            let parentID = UUID().uuidString
            let subtask = createSubtaskFromMatch(matches[0], index: 0, parentID: parentID, request: request)
            addSubtasks([subtask])
            return [subtask]
        }
        
        // 多个匹配时才拆解
        let parentID = UUID().uuidString
        var subtasks: [Subtask] = []
        
        for (index, match) in matches.enumerated() {
            let subtask = createSubtaskFromMatch(match, index: index, parentID: parentID, request: request)
            subtasks.append(subtask)
        }
        
        addSubtasks(subtasks)
        
        LogInfo("意图匹配: 拆解为 \(matches.count) 个子任务")
        for match in matches {
            LogInfo("  - \(match.capability.name): \(String(format: "%.2f", match.score))")
        }
        
        return subtasks
    }
    
    private func createSubtaskFromMatch(
        _ match: IntentMatch,
        index: Int,
        parentID: String,
        request: String
    ) -> Subtask {
        let capability = match.capability
        
        // 根据能力类型确定子任务类型和策略
        let (type, strategy): (SubtaskType, SubtaskStrategy) = {
            switch capability.type {
            case .builtin:
                if capability.id.contains("disk") {
                    return (.diskAnalysis, .useBuiltin(.diskManager))
                } else if capability.id.contains("cleanup") {
                    return (.fileOperation, .useBuiltin(.localCLI))
                } else {
                    return (.custom, .useBuiltin(.localCLI))
                }
            case .skill:
                let skillName = capability.id.replacingOccurrences(of: "skill_", with: "")
                return (.custom, .useSkill(skillName))
            case .agent:
                let agentID = capability.id.replacingOccurrences(of: "agent_", with: "")
                return (.codeAnalysis, .useAgent(agentID))
            case .openClawSkill:
                let skillName = capability.id.replacingOccurrences(of: "openclaw_", with: "")
                return (.securityScan, .useOpenClaw(skillName))
            }
        }()
        
        return Subtask(
            id: "\(parentID)-subtask-\(index)",
            type: type,
            title: "\(index + 1). \(capability.name)",
            description: capability.description,
            parentTaskID: parentID,
            strategy: strategy,
            inputContext: request
        )
    }
    
    private func createGenericSubtask(request: String) -> Subtask {
        return Subtask(
            type: .custom,
            title: "处理请求",
            description: "分析并处理用户请求",
            strategy: .custom,
            inputContext: request
        )
    }
}
