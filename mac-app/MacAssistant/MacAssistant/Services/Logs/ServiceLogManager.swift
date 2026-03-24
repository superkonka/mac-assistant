//
//  ServiceLogManager.swift
//  MacAssistant
//
//  服务日志管理器 - 管理服务日志的读取和监控
//

import Foundation

// MARK: - 日志条目
struct ServiceLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let source: String
    let message: String
    
    enum LogLevel: String, CaseIterable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
        case fatal = "FATAL"
        
        var color: String {
            switch self {
            case .debug: return "gray"
            case .info: return "blue"
            case .warning: return "orange"
            case .error: return "red"
            case .fatal: return "purple"
            }
        }
        
        var priority: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            case .fatal: return 4
            }
        }
    }
}

// MARK: - 日志源
enum LogSource {
    case file(path: String)
    case process(pid: Int)
    case command(cmd: String, args: [String])
}

// MARK: - 日志配置
struct LogConfig {
    let serviceID: String
    let source: LogSource
    let maxLines: Int
    let refreshInterval: TimeInterval?
    let filters: [LogFilter]
    
    struct LogFilter {
        let level: ServiceLogEntry.LogLevel?
        let keyword: String?
        let timeRange: ClosedRange<Date>?
    }
}

// MARK: - 服务日志管理器
@MainActor
final class ServiceLogManager: ObservableObject {
    static let shared = ServiceLogManager()
    
    // MARK: - Published
    @Published var logs: [String: [ServiceLogEntry]] = [:]  // serviceID -> logs
    @Published var isLoading: [String: Bool] = [:]
    @Published var hasMoreLogs: [String: Bool] = [:]
    
    // MARK: - Private
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var lastReadOffsets: [String: UInt64] = [:]
    
    // MARK: - 日志读取
    
    /// 读取服务日志文件
    func loadLogs(
        for serviceID: String,
        from path: String,
        maxLines: Int = 100,
        filters: [LogConfig.LogFilter] = []
    ) async {
        isLoading[serviceID] = true
        defer { isLoading[serviceID] = false }
        
        let task = Process()
        task.launchPath = "/usr/bin/tail"
        task.arguments = ["-n", String(maxLines), path]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let entries = parseLogLines(output.components(separatedBy: .newlines), source: path)
            
            // 应用过滤器
            let filtered = applyFilters(entries, filters: filters)
            
            logs[serviceID] = filtered
            
            LogInfo("[ServiceLogManager] 加载 \(serviceID) 日志: \(filtered.count) 条")
        } catch {
            LogError("[ServiceLogManager] 读取日志失败: \(error)")
            logs[serviceID] = [ServiceLogEntry(
                timestamp: Date(),
                level: .error,
                source: "log_manager",
                message: "无法读取日志文件: \(error.localizedDescription)"
            )]
        }
    }
    
    /// 实时读取日志（使用 tail -f）
    func startRealtimeLogs(
        for serviceID: String,
        from path: String,
        onNewLine: @escaping (ServiceLogEntry) -> Void
    ) {
        stopRealtimeLogs(for: serviceID)
        
        let task = Process()
        task.launchPath = "/usr/bin/tail"
        task.arguments = ["-f", "-n", "0", path]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        refreshTasks[serviceID] = Task {
            do {
                try task.run()
                
                let handle = pipe.fileHandleForReading
                for try await line in handle.bytes.lines {
                    guard !Task.isCancelled else { break }
                    
                    if let entry = parseLogLine(line, source: path) {
                        await MainActor.run {
                            onNewLine(entry)
                            if logs[serviceID] == nil {
                                logs[serviceID] = []
                            }
                            logs[serviceID]?.append(entry)
                            
                            // 限制内存中的日志数量
                            if logs[serviceID]!.count > 1000 {
                                logs[serviceID] = Array(logs[serviceID]!.suffix(500))
                            }
                        }
                    }
                }
            } catch {
                LogError("[ServiceLogManager] 实时日志错误: \(error)")
            }
        }
    }
    
    /// 停止实时日志
    func stopRealtimeLogs(for serviceID: String) {
        refreshTasks[serviceID]?.cancel()
        refreshTasks.removeValue(forKey: serviceID)
    }
    
    /// 从进程读取日志
    func loadLogsFromProcess(
        for serviceID: String,
        pid: Int,
        maxLines: Int = 100
    ) async {
        isLoading[serviceID] = true
        defer { isLoading[serviceID] = false }
        
        // 使用 log 命令读取进程日志
        let task = Process()
        task.launchPath = "/usr/bin/log"
        task.arguments = [
            "show",
            "--predicate", "processID == \(pid)",
            "--last", "1h",
            "--style", "compact"
        ]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let lines = output.components(separatedBy: .newlines)
            let entries = Array(parseLogLines(lines, source: "process:\(pid)").suffix(maxLines))
            
            logs[serviceID] = entries
        } catch {
            LogError("[ServiceLogManager] 读取进程日志失败: \(error)")
        }
    }
    
    /// 搜索日志
    func searchLogs(
        for serviceID: String,
        keyword: String,
        caseSensitive: Bool = false
    ) -> [ServiceLogEntry] {
        guard let serviceLogs = logs[serviceID] else { return [] }
        
        return serviceLogs.filter { entry in
            if caseSensitive {
                return entry.message.contains(keyword)
            } else {
                return entry.message.lowercased().contains(keyword.lowercased())
            }
        }
    }
    
    /// 清除日志缓存
    func clearLogs(for serviceID: String) {
        logs.removeValue(forKey: serviceID)
        stopRealtimeLogs(for: serviceID)
    }
    
    /// 导出日志
    func exportLogs(for serviceID: String, to path: String) -> Bool {
        guard let serviceLogs = logs[serviceID] else { return false }
        
        let content = serviceLogs.map { entry in
            "[\(entry.timestamp)] [\(entry.level.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
        
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            LogError("[ServiceLogManager] 导出日志失败: \(error)")
            return false
        }
    }
    
    // MARK: - 私有方法
    
    private func parseLogLines(_ lines: [String], source: String) -> [ServiceLogEntry] {
        return lines.compactMap { parseLogLine($0, source: source) }
    }
    
    private func parseLogLine(_ line: String, source: String) -> ServiceLogEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        // 尝试解析常见日志格式
        // 格式1: [2024-01-15 10:30:45] [INFO] message
        // 格式2: 2024-01-15T10:30:45Z [INFO] message
        // 格式3: [INFO] 2024-01-15 10:30:45 message
        
        var timestamp = Date()
        var level: ServiceLogEntry.LogLevel = .info
        var message = trimmed
        
        // 尝试提取时间戳
        let datePatterns = [
            #"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]"#,
            #"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})"#,
            #"(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})"#
        ]
        
        for pattern in datePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)),
               let range = Range(match.range(at: 1), in: trimmed) {
                let dateString = String(trimmed[range])
                if let date = parseDate(dateString) {
                    timestamp = date
                    message = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        
        // 尝试提取日志级别
        let levelPatterns: [(pattern: String, level: ServiceLogEntry.LogLevel)] = [
            (#"(?i)\[(DEBUG|DBG)\]"#, .debug),
            (#"(?i)\[(INFO|INF)\]"#, .info),
            (#"(?i)\[(WARN|WARNING|WRN)\]"#, .warning),
            (#"(?i)\[(ERROR|ERR)\]"#, .error),
            (#"(?i)\[(FATAL|FTL)\]"#, .fatal)
        ]
        
        for (pattern, lvl) in levelPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)) != nil {
                level = lvl
                // 从消息中移除级别标记
                if let match = regex.firstMatch(in: message, range: NSRange(location: 0, length: message.utf16.count)),
                   let range = Range(match.range, in: message) {
                    message = String(message[..<range.lowerBound]) + String(message[range.upperBound...])
                    message = message.trimmingCharacters(in: .whitespaces)
                }
                break
            }
        }
        
        // 从消息中提取实际的日志内容（移除文件名和行号等）
        message = message.replacingOccurrences(of: #"^\s*"#, with: "", options: .regularExpression)
        
        return ServiceLogEntry(
            timestamp: timestamp,
            level: level,
            source: source,
            message: message
        )
    }
    
    private func parseDate(_ string: String) -> Date? {
        let formatters = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        ]
        
        for format in formatters {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            if let date = formatter.date(from: string) {
                return date
            }
        }
        
        // 尝试 ISO8601
        let isoFormatter = ISO8601DateFormatter()
        return isoFormatter.date(from: string)
    }
    
    private func applyFilters(_ entries: [ServiceLogEntry], filters: [LogConfig.LogFilter]) -> [ServiceLogEntry] {
        return entries.filter { entry in
            for filter in filters {
                // 级别过滤
                if let level = filter.level, entry.level.priority < level.priority {
                    return false
                }
                
                // 关键词过滤
                if let keyword = filter.keyword,
                   !entry.message.lowercased().contains(keyword.lowercased()) {
                    return false
                }
                
                // 时间范围过滤
                if let timeRange = filter.timeRange,
                   !timeRange.contains(entry.timestamp) {
                    return false
                }
            }
            return true
        }
    }
    
    /// 猜测服务的日志文件路径
    func guessLogPath(for service: ServiceDefinition) -> String? {
        // 常见日志路径模式
        let patterns = [
            "~/Library/Logs/\(service.name)/\(service.name).log",
            "~/Library/Logs/\(service.id)/\(service.id).log",
            "\(service.path ?? "~")/logs/\(service.id).log",
            "\(service.path ?? "~")/log/\(service.id).log",
            "\(service.path ?? "~")/\(service.id).log",
            "/var/log/\(service.id).log",
            "/usr/local/var/log/\(service.id).log"
        ]
        
        let fileManager = FileManager.default
        
        for pattern in patterns {
            let expanded = pattern.replacingOccurrences(of: "~", with: NSHomeDirectory())
            if fileManager.fileExists(atPath: expanded) {
                return expanded
            }
        }
        
        return nil
    }
}

// MARK: - 扩展
@MainActor
extension ServiceDefinition {
    /// 获取日志路径
    var logPath: String? {
        get async {
            await ServiceLogManager.shared.guessLogPath(for: self)
        }
    }
    
    /// 是否有日志
    var hasLogs: Bool {
        get async {
            await logPath != nil
        }
    }
}
