//
//  AgentOrchestrator.swift
//  MacAssistant
//
//  智能编排器：意图分析、路由决策、能力发现
//

import Foundation
import Combine

/// AgentOrchestrator - 核心编排器
/// 
/// 职责：
/// 1. 分析用户意图
/// 2. 路由到合适的 Agent
/// 3. 发现能力缺口并引导创建
class AgentOrchestrator: ObservableObject {
    static let shared = AgentOrchestrator()
    
    @Published var currentAgent: Agent?
    @Published var isAnalyzing = false
    @Published var lastGap: CapabilityGap?
    
    private var agentStore = AgentStore()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // 初始化时加载默认 Agent
        currentAgent = agentStore.agents.first { $0.isDefault }
    }
    
    // MARK: - 意图分析
    
    /// 分析用户意图
    func analyzeIntent(_ input: String) async -> Intent {
        isAnalyzing = true
        defer { isAnalyzing = false }
        
        LogInfo("🔍 分析意图: \(input.prefix(50))...")
        
        // 1. 关键词匹配（快速路径）
        if let intent = keywordMatchIntent(input) {
            LogInfo("✅ 关键词匹配意图: \(intent.displayName)")
            return intent
        }
        
        // 2. 使用 Core Agent 进行深度分析
        let intent = await analyzeWithCoreAgent(input)
        LogInfo("🤖 AI 分析意图: \(intent.displayName)")
        return intent
    }
    
    /// 关键词快速匹配
    private func keywordMatchIntent(_ input: String) -> Intent? {
        let lowerInput = input.lowercased()
        
        // 图片分析
        let imageKeywords = ["分析图片", "分析截图", "看图", "识别图片", "ocr", "图片里", "截图中", "这张照片", "这张图片"]
        if imageKeywords.contains(where: { lowerInput.contains($0) }) {
            return .imageAnalysis
        }
        
        // 代码分析
        let codeKeywords = ["分析代码", "代码 review", "review 代码", "优化代码", "这段代码", "debug", "调试代码", "swift 代码", "python 代码"]
        if codeKeywords.contains(where: { lowerInput.contains($0) }) {
            let language = detectLanguage(lowerInput)
            return .codeAnalysis(language)
        }
        
        // 文档分析
        let docKeywords = ["分析 pdf", "分析文档", "总结 pdf", "总结文档", "pdf 内容", "word 文档", "docx"]
        if docKeywords.contains(where: { lowerInput.contains($0) }) {
            let fileType = detectFileType(lowerInput)
            return .documentAnalysis(fileType)
        }
        
        // 系统操作
        let systemKeywords = ["截图", "清理磁盘", "查看系统", "关闭应用", "启动", "打开", "关闭"]
        if systemKeywords.contains(where: { lowerInput.contains($0) }) {
            return .systemOperation("general")
        }
        
        // 网络搜索
        let searchKeywords = ["搜索", "查找", "google", "百度", "最新", "新闻", "今天发生了什么"]
        if searchKeywords.contains(where: { lowerInput.contains($0) }) {
            return .webSearch(input)
        }
        
        return nil
    }
    
    /// 使用 Core Agent 深度分析意图
    private func analyzeWithCoreAgent(_ input: String) async -> Intent {
        // 简化版：基于上下文判断
        // 实际实现可以调用轻量级模型进行分类
        
        // 检查是否包含文件路径
        if input.contains("/") && (input.contains(".pdf") || input.contains(".doc") || input.contains(".txt")) {
            return .documentAnalysis("pdf")
        }
        
        // 检查是否包含图片相关描述
        if input.contains("图片") || input.contains("照片") || input.contains("截图") {
            return .imageAnalysis
        }
        
        // 默认文本对话
        return .textChat
    }
    
    private func detectLanguage(_ input: String) -> String {
        if input.contains("swift") { return "swift" }
        if input.contains("python") { return "python" }
        if input.contains("javascript") || input.contains("js") { return "javascript" }
        if input.contains("typescript") || input.contains("ts") { return "typescript" }
        if input.contains("java") { return "java" }
        if input.contains("go") { return "go" }
        if input.contains("rust") { return "rust" }
        return "unknown"
    }
    
    private func detectFileType(_ input: String) -> String {
        if input.contains("pdf") { return "pdf" }
        if input.contains("docx") || input.contains("word") { return "docx" }
        if input.contains("txt") { return "txt" }
        if input.contains("md") || input.contains("markdown") { return "md" }
        return "unknown"
    }
    
    // MARK: - 路由决策
    
    /// 路由用户请求到合适的 Agent
    func route(_ input: String, intent: Intent? = nil) async -> RoutingResult {
        let analyzedIntent: Intent
        if let providedIntent = intent {
            analyzedIntent = providedIntent
        } else {
            analyzedIntent = await analyzeIntent(input)
        }
        
        LogInfo("🚦 路由决策: \(analyzedIntent.displayName)")
        
        // 1. 检查当前 Agent 是否满足需求
        if let current = currentAgent,
           current.capabilities.contains(all: analyzedIntent.requiredCapabilities) {
            LogInfo("✅ 当前 Agent 满足需求")
            return .success(current)
        }
        
        // 2. 查找能满足需求的 Agent
        let candidates = agentStore.agents.filter { agent in
            agent.capabilities.contains(all: analyzedIntent.requiredCapabilities)
        }
        
        if candidates.count == 1 {
            LogInfo("✅ 找到匹配的 Agent: \(candidates[0].name)")
            return .success(candidates[0])
        } else if candidates.count > 1 {
            LogInfo("⚠️ 多个 Agent 匹配，需要用户选择")
            return .ambiguous(candidates)
        }
        
        // 3. 无匹配的 Agent，发现能力缺口
        LogInfo("❌ 无匹配的 Agent，发现能力缺口")
        let missingCapabilities = analyzedIntent.requiredCapabilities.filter { req in
            !agentStore.allCapabilities.contains(req)
        }
        
        if let missing = missingCapabilities.first {
            let gap = CapabilityGap.gap(for: missing, intent: analyzedIntent)
            lastGap = gap
            return .missingAgent(gap)
        }
        
        // 4. 默认使用 Core Agent
        if let defaultAgent = agentStore.agents.first(where: { $0.isDefault }) {
            return .success(defaultAgent)
        }
        
        return .failed("没有可用的 Agent")
    }
    
    /// 切换当前 Agent
    func switchToAgent(_ agent: Agent) {
        currentAgent = agent
        agentStore.updateLastUsed(agent)
        LogInfo("🔄 切换到 Agent: \(agent.name)")
    }
    
    /// 处理用户输入（完整流程）
    func processInput(_ input: String) async -> ProcessResult {
        // 1. 分析意图
        let intent = await analyzeIntent(input)
        
        // 2. 路由决策
        let routingResult = await route(input, intent: intent)
        
        switch routingResult {
        case .success(let agent):
            // 使用选定的 Agent 处理
            if agent.id != currentAgent?.id {
                await MainActor.run {
                    switchToAgent(agent)
                }
            }
            return .success(agent, intent)
            
        case .missingAgent(let gap):
            // 需要创建新 Agent
            return .needConfiguration(gap)
            
        case .ambiguous(let agents):
            // 需要用户选择
            return .needSelection(agents, intent)
            
        case .failed(let error):
            return .failed(error)
        }
    }
}

// MARK: - 处理结果

enum ProcessResult {
    case success(Agent, Intent)      // 成功找到 Agent 和意图
    case needConfiguration(CapabilityGap)  // 需要配置新 Agent
    case needSelection([Agent], Intent)    // 需要用户选择 Agent
    case failed(String)              // 处理失败
}

// MARK: - 数组扩展

extension Array where Element == Capability {
    func contains(all elements: [Capability]) -> Bool {
        Set(elements).isSubset(of: Set(self))
    }
}
