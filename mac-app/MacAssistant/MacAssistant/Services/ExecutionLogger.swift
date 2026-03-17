//
//  ExecutionLogger.swift
//  MacAssistant
//
//  执行链路日志服务 - 实时收集和展示链路详细信息
//

import Foundation
import Combine

/// 日志级别
enum ExecutionLogLevel: String, Codable, Comparable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
    case success = "SUCCESS"
    
    var icon: String {
        switch self {
        case .debug: return "⚪️"
        case .info: return "🔵"
        case .warning: return "🟡"
        case .error: return "🔴"
        case .success: return "🟢"
        }
    }
    
    var color: String {
        switch self {
        case .debug: return "gray"
        case .info: return "blue"
        case .warning: return "orange"
        case .error: return "red"
        case .success: return "green"
        }
    }
    
    static func < (lhs: ExecutionLogLevel, rhs: ExecutionLogLevel) -> Bool {
        let order: [ExecutionLogLevel] = [.debug, .info, .warning, .error, .success]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else { return false }
        return lhsIndex < rhsIndex
    }
}

/// 执行日志条目
struct ExecutionLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let level: ExecutionLogLevel
    let component: String
    let message: String
    let details: [String: String]?
    let sessionID: String?
    let traceID: String?
    
    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: ExecutionLogLevel,
        component: String,
        message: String,
        details: [String: String]? = nil,
        sessionID: String? = nil,
        traceID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.component = component
        self.message = message
        self.details = details
        self.sessionID = sessionID
        self.traceID = traceID
    }
    
    /// 格式化时间
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
    
    /// 格式化为CLI风格
    var cliFormatted: String {
        var parts = ["[\(formattedTime)]", level.icon, "[\(component)]", message]
        if let details = details, !details.isEmpty {
            let detailStr = details.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            parts.append("{\(detailStr)}")
        }
        return parts.joined(separator: " ")
    }
}

/// 执行链路会话
struct ExecutionSession: Identifiable, Codable {
    let id: String
    let startTime: Date
    var endTime: Date?
    var status: ExecutionSessionStatus
    var entries: [ExecutionLogEntry]
    let userRequest: String
    var currentAgent: String?
    var currentStage: String?
    
    enum ExecutionSessionStatus: String, Codable {
        case running = "running"
        case completed = "completed"
        case failed = "failed"
        case cancelled = "cancelled"
    }
    
    var duration: TimeInterval {
        let end = endTime ?? Date()
        return end.timeIntervalSince(startTime)
    }
    
    var formattedDuration: String {
        let seconds = Int(duration)
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            return "\(seconds / 60)m\(seconds % 60)s"
        }
    }
}

@MainActor
final class ExecutionLogger: ObservableObject {
    static let shared = ExecutionLogger()
    
    /// 当前活跃的会话
    @Published private(set) var activeSessions: [String: ExecutionSession] = [:]
    
    /// 历史会话（保留最近20个）
    @Published private(set) var historySessions: [ExecutionSession] = []
    
    /// 日志更新通知
    let logUpdatePublisher = PassthroughSubject<(sessionID: String, entry: ExecutionLogEntry), Never>()
    
    /// 最大历史会话数
    private let maxHistorySessions = 20
    
    /// 是否启用详细日志
    var isDetailedLoggingEnabled = true
    
    private init() {}
    
    // MARK: - 会话管理
    
    /// 开始新会话
    func startSession(id: String, userRequest: String) -> ExecutionSession {
        let session = ExecutionSession(
            id: id,
            startTime: Date(),
            endTime: nil,
            status: .running,
            entries: [],
            userRequest: userRequest,
            currentAgent: nil,
            currentStage: nil
        )
        activeSessions[id] = session
        
        // 添加启动日志
        log(
            sessionID: id,
            level: .info,
            component: "Session",
            message: "开始执行链路",
            details: ["request": userRequest.prefix(50).description]
        )
        
        return session
    }
    
    /// 结束会话
    func endSession(id: String, status: ExecutionSession.ExecutionSessionStatus) {
        guard var session = activeSessions[id] else { return }
        session.endTime = Date()
        session.status = status
        activeSessions[id] = session
        
        log(
            sessionID: id,
            level: status == .completed ? .success : .info,
            component: "Session",
            message: "执行链路结束",
            details: ["status": status.rawValue, "duration": session.formattedDuration]
        )
        
        // 移到历史
        historySessions.append(session)
        if historySessions.count > maxHistorySessions {
            historySessions.removeFirst(historySessions.count - maxHistorySessions)
        }
        
        // 延迟从活跃会话移除（保留一段时间供查看）
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.activeSessions.removeValue(forKey: id)
        }
    }
    
    // MARK: - 日志记录
    
    func log(
        sessionID: String,
        level: ExecutionLogLevel,
        component: String,
        message: String,
        details: [String: String]? = nil,
        traceID: String? = nil
    ) {
        guard isDetailedLoggingEnabled else { return }
        
        let entry = ExecutionLogEntry(
            level: level,
            component: component,
            message: message,
            details: details,
            sessionID: sessionID,
            traceID: traceID
        )
        
        // 添加到会话
        if var session = activeSessions[sessionID] {
            session.entries.append(entry)
            activeSessions[sessionID] = session
        }
        
        // 发送通知
        logUpdatePublisher.send((sessionID: sessionID, entry: entry))
        
        // 同时输出到系统日志
        LogInfo("[\(component)] \(message)")
    }
    
    // MARK: - 快捷方法
    
    func logPlannerDecision(
        sessionID: String,
        action: String,
        reason: String,
        confidence: String
    ) {
        log(
            sessionID: sessionID,
            level: .info,
            component: "Planner",
            message: "决策: \(action)",
            details: ["reason": reason, "confidence": confidence]
        )
    }
    
    func logAgentSwitch(
        sessionID: String,
        from: String,
        to: String,
        reason: String
    ) {
        log(
            sessionID: sessionID,
            level: .warning,
            component: "AgentRouter",
            message: "Agent切换: \(from) → \(to)",
            details: ["reason": reason]
        )
    }
    
    func logStreamEvent(
        sessionID: String,
        event: String,
        data: String? = nil
    ) {
        var details: [String: String] = ["event": event]
        if let data = data {
            details["data_preview"] = String(data.prefix(100))
        }
        log(
            sessionID: sessionID,
            level: .debug,
            component: "Stream",
            message: "流事件: \(event)",
            details: details
        )
    }
    
    func logError(
        sessionID: String,
        component: String,
        error: Error,
        context: String? = nil
    ) {
        var details: [String: String] = ["error": error.localizedDescription]
        if let context = context {
            details["context"] = context
        }
        log(
            sessionID: sessionID,
            level: .error,
            component: component,
            message: "错误: \(error.localizedDescription)",
            details: details
        )
    }
    
    func logMemoryOperation(
        sessionID: String,
        operation: String,
        result: String
    ) {
        log(
            sessionID: sessionID,
            level: .debug,
            component: "Memory",
            message: "记忆操作: \(operation)",
            details: ["result": result]
        )
    }
    
    func logRecoveryAttempt(
        sessionID: String,
        attempt: Int,
        strategy: String,
        result: String
    ) {
        log(
            sessionID: sessionID,
            level: .warning,
            component: "Recovery",
            message: "恢复尝试 #\(attempt): \(strategy)",
            details: ["result": result]
        )
    }
    
    // MARK: - 查询方法
    
    func getSession(_ id: String) -> ExecutionSession? {
        activeSessions[id] ?? historySessions.first { $0.id == id }
    }
    
    func getAllSessions() -> [ExecutionSession] {
        Array(activeSessions.values) + historySessions
    }
    
    func getEntriesForSession(_ id: String, level: ExecutionLogLevel? = nil) -> [ExecutionLogEntry] {
        guard let session = getSession(id) else { return [] }
        if let level = level {
            return session.entries.filter { $0.level >= level }
        }
        return session.entries
    }
    
    // MARK: - 清理
    
    func clearHistory() {
        historySessions.removeAll()
    }
    
    func clearAll() {
        activeSessions.removeAll()
        historySessions.removeAll()
    }
}

// MARK: - 便捷扩展

extension ExecutionLogger {
    /// 为当前请求创建日志上下文
    static func withSession(_ sessionID: String, request: String) -> ExecutionSession {
        shared.startSession(id: sessionID, userRequest: request)
    }
}
