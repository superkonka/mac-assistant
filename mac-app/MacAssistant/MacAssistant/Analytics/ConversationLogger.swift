//
//  ConversationLogger.swift
//  MacAssistant
//
//  对话日志记录器 - 完整记录会话流程
//

import Foundation
import Combine

/// 对话事件类型
enum ConversationEventType: String, Codable {
    case userInput           // 用户输入
    case systemResponse      // 系统响应
    case agentSwitch         // Agent 切换
    case skillExecuted       // Skill 执行
    case skillDetected       // Skill 意图检测
    case agentSuggested      // Agent 建议
    case agentMentioned      // @Agent 提及
    case skillCommanded      // /Skill 命令
    case capabilityGap       // 能力缺口检测
    case agentCreation       // Agent 创建流程
    case error               // 错误
    case performance         // 性能指标
}

/// 对话事件
struct ConversationEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let type: ConversationEventType
    let sessionId: String
    
    // 事件详情
    var input: String?              // 用户原始输入
    var parsedInput: ParsedInputLog? // 解析后的输入
    var response: String?           // 系统响应
    var agentId: String?            // 相关 Agent
    var agentName: String?          // Agent 名称
    var skillId: String?            // Skill ID
    var skillName: String?          // Skill 名称
    var metadata: [String: String]? // 额外元数据
    var duration: TimeInterval?     // 处理耗时
    var error: String?              // 错误信息
    
    init(
        type: ConversationEventType,
        sessionId: String,
        input: String? = nil,
        parsedInput: ParsedInputLog? = nil,
        response: String? = nil,
        agentId: String? = nil,
        agentName: String? = nil,
        skillId: String? = nil,
        skillName: String? = nil,
        metadata: [String: String]? = nil,
        duration: TimeInterval? = nil,
        error: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.type = type
        self.sessionId = sessionId
        self.input = input
        self.parsedInput = parsedInput
        self.response = response
        self.agentId = agentId
        self.agentName = agentName
        self.skillId = skillId
        self.skillName = skillName
        self.metadata = metadata
        self.duration = duration
        self.error = error
    }
}

/// 解析输入日志
struct ParsedInputLog: Codable {
    let original: String
    let cleanText: String
    let hasAgentMention: Bool
    let agentMention: String?
    let hasSkillCommand: Bool
    let skillCommand: String?
    let detectedSkill: String?
    let suggestedAgent: String?
}

/// 会话统计
struct SessionStats: Codable {
    let sessionId: String
    let startTime: Date
    var endTime: Date?
    var eventCount: Int = 0
    var userMessageCount: Int = 0
    var agentSwitchCount: Int = 0
    var skillExecutionCount: Int = 0
    var errorCount: Int = 0
    var totalDuration: TimeInterval = 0
    var avgResponseTime: TimeInterval = 0
    var activeAgent: String?
}

/// 对话日志记录器
class ConversationLogger: ObservableObject {
    static let shared = ConversationLogger()
    
    @Published var currentSessionId: String = ""
    @Published var events: [ConversationEvent] = []
    @Published var isRecording = false
    
    private var stats: SessionStats?
    private var responseStartTime: Date?
    private let fileManager = FileManager.default
    private let logsDirectory: URL
    
    init() {
        // 创建日志目录
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        logsDirectory = docsDir.appendingPathComponent("MacAssistant/ConversationLogs")
        try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        
        startNewSession()
    }
    
    // MARK: - 会话管理
    
    func startNewSession() {
        currentSessionId = "session-\(UUID().uuidString.prefix(8))"
        events = []
        stats = SessionStats(
            sessionId: currentSessionId,
            startTime: Date(),
            activeAgent: AgentOrchestrator.shared.currentAgent?.name
        )
        isRecording = true
        
        log(.systemResponse, response: "=== 新会话开始: \(currentSessionId) ===")
    }
    
    func endSession() {
        stats?.endTime = Date()
        saveSessionLog()
        isRecording = false
    }
    
    // MARK: - 日志记录方法
    
    /// 记录用户输入
    func logUserInput(_ input: String, parsed: ParsedInput) {
        let parsedLog = ParsedInputLog(
            original: parsed.original,
            cleanText: parsed.cleanText,
            hasAgentMention: parsed.agentMention != nil,
            agentMention: parsed.agentMention?.agentName,
            hasSkillCommand: parsed.skillCommand != nil,
            skillCommand: parsed.skillCommand?.command,
            detectedSkill: parsed.detectedSkill?.name,
            suggestedAgent: parsed.suggestedAgent?.reason
        )
        
        log(.userInput, input: input, parsedInput: parsedLog)
        stats?.userMessageCount += 1
        
        // 记录特殊事件
        if parsed.agentMention != nil {
            log(.agentMentioned, input: input, metadata: [
                "agent": parsed.agentMention?.agentName ?? ""
            ])
        }
        
        if parsed.skillCommand != nil {
            log(.skillCommanded, input: input, metadata: [
                "skill": parsed.skillCommand?.command ?? ""
            ])
        }
        
        if parsed.detectedSkill != nil {
            log(.skillDetected, input: input, metadata: [
                "skill": parsed.detectedSkill?.name ?? "",
                "confidence": "medium"
            ])
        }
        
        if parsed.suggestedAgent != nil {
            log(.agentSuggested, input: input, metadata: [
                "reason": parsed.suggestedAgent?.reason ?? ""
            ])
        }
        
        responseStartTime = Date()
    }
    
    /// 记录 Agent 切换
    func logAgentSwitch(from: Agent?, to: Agent, reason: String) {
        log(.agentSwitch, agentId: to.id, agentName: to.name, metadata: [
            "from": from?.name ?? "none",
            "to": to.name,
            "reason": reason
        ])
        stats?.agentSwitchCount += 1
        stats?.activeAgent = to.name
    }
    
    /// 记录 Skill 执行
    func logSkillExecution(_ skill: AISkill, result: SkillResult, duration: TimeInterval) {
        var metadata: [String: String] = [
            "duration": String(format: "%.2f", duration)
        ]
        
        switch result {
        case .success:
            metadata["status"] = "success"
        case .requiresInput:
            metadata["status"] = "requires_input"
        case .requiresAgentCreation:
            metadata["status"] = "requires_agent"
        case .error(let error):
            metadata["status"] = "error"
            metadata["error"] = error
        }
        
        log(.skillExecuted, skillId: skill.rawValue, skillName: skill.name, metadata: metadata)
        stats?.skillExecutionCount += 1
    }
    
    /// 记录能力缺口
    func logCapabilityGap(_ gap: CapabilityGap, context: String) {
        log(.capabilityGap, input: context, metadata: [
            "missing_capability": gap.missingCapability.rawValue,
            "suggested_providers": gap.suggestedProviders.map { $0.rawValue }.joined(separator: ",")
        ])
    }
    
    /// 记录 Agent 创建
    func logAgentCreation(agent: Agent, provider: ProviderType, success: Bool, error: String? = nil) {
        log(.agentCreation, agentId: agent.id, agentName: agent.name, metadata: [
            "provider": provider.rawValue,
            "model": agent.model,
            "success": success ? "true" : "false"
        ], error: error)
    }
    
    /// 记录系统响应
    func logSystemResponse(_ response: String, agent: Agent? = nil) {
        let duration: TimeInterval?
        if let start = responseStartTime {
            duration = Date().timeIntervalSince(start)
            responseStartTime = nil
        } else {
            duration = nil
        }
        
        log(.systemResponse, response: response, agentId: agent?.id, agentName: agent?.name, duration: duration)
    }
    
    /// 记录错误
    func logError(_ error: Error, context: String) {
        log(.error, input: context, error: error.localizedDescription)
        stats?.errorCount += 1
    }
    
    /// 记录性能指标
    func logPerformance(operation: String, duration: TimeInterval) {
        log(.performance, metadata: [
            "operation": operation,
            "duration_ms": String(format: "%.2f", duration * 1000)
        ])
    }
    
    // MARK: - 私有方法
    
    private func log(
        _ type: ConversationEventType,
        input: String? = nil,
        parsedInput: ParsedInputLog? = nil,
        response: String? = nil,
        agentId: String? = nil,
        agentName: String? = nil,
        skillId: String? = nil,
        skillName: String? = nil,
        metadata: [String: String]? = nil,
        duration: TimeInterval? = nil,
        error: String? = nil
    ) {
        guard isRecording else { return }
        
        let event = ConversationEvent(
            type: type,
            sessionId: currentSessionId,
            input: input,
            parsedInput: parsedInput,
            response: response,
            agentId: agentId,
            agentName: agentName,
            skillId: skillId,
            skillName: skillName,
            metadata: metadata,
            duration: duration,
            error: error
        )
        
        events.append(event)
        stats?.eventCount += 1
        
        // 实时保存
        appendEventToFile(event)
    }
    
    private func appendEventToFile(_ event: ConversationEvent) {
        let fileURL = logsDirectory.appendingPathComponent("\(currentSessionId).jsonl")
        
        do {
            let data = try JSONEncoder().encode(event)
            let json = String(data: data, encoding: .utf8)!
            
            if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write((json + "\n").data(using: .utf8)!)
                fileHandle.closeFile()
            } else {
                try json.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("日志写入失败: \(error)")
        }
    }
    
    private func saveSessionLog() {
        guard var stats = stats else { return }
        
        // 计算统计
        let durations = events.compactMap { $0.duration }
        if !durations.isEmpty {
            stats.avgResponseTime = durations.reduce(0, +) / Double(durations.count)
        }
        
        // 保存统计
        let statsURL = logsDirectory.appendingPathComponent("\(currentSessionId)-stats.json")
        do {
            let data = try JSONEncoder().encode(stats)
            try data.write(to: statsURL)
        } catch {
            print("统计保存失败: \(error)")
        }
    }
    
    // MARK: - 查询方法
    
    /// 获取会话列表
    func getSessions() -> [SessionStats] {
        do {
            let files = try fileManager.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: nil)
            let statsFiles = files.filter { $0.lastPathComponent.hasSuffix("-stats.json") }
            
            return try statsFiles.compactMap { url in
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(SessionStats.self, from: data)
            }.sorted { $0.startTime > $1.startTime }
        } catch {
            return []
        }
    }
    
    /// 加载会话事件
    func loadSession(_ sessionId: String) -> [ConversationEvent] {
        let fileURL = logsDirectory.appendingPathComponent("\(sessionId).jsonl")
        
        guard let content = try? String(contentsOf: fileURL) else {
            return []
        }
        
        let lines = content.split(separator: "\n")
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ConversationEvent.self, from: data)
        }
    }
    
    /// 导出会话日志
    func exportSession(_ sessionId: String) -> URL? {
        let events = loadSession(sessionId)
        guard !events.isEmpty else { return nil }
        
        let exportURL = logsDirectory.appendingPathComponent("\(sessionId)-export.json")
        
        do {
            let data = try JSONEncoder().encode(events)
            try data.write(to: exportURL)
            return exportURL
        } catch {
            return nil
        }
    }
    
    /// 清除所有日志
    func clearAllLogs() {
        try? fileManager.removeItem(at: logsDirectory)
        try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }
}
