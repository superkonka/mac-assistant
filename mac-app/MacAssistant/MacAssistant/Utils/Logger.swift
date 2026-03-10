//
//  Logger.swift
//  文件日志系统
//

import Foundation
import os.log

/// 日志级别
enum LogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"
    
    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .critical: return "🚨"
        }
    }
    
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .critical: return .fault
        }
    }
}

/// 日志条目
struct LogEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let level: String
    let message: String
    let file: String
    let function: String
    let line: Int
    let thread: String
    let additionalData: String?
}

/// 文件日志管理器
class FileLogger {
    static let shared = FileLogger()
    
    // 日志文件目录
    private let logsDirectory: URL
    private let currentLogFile: URL
    private let archiveDirectory: URL
    
    // 文件句柄
    private var fileHandle: FileHandle?
    private let writeQueue = DispatchQueue(label: "com.mac-assistant.logger", qos: .utility)
    
    // 日志级别过滤
    var minimumLevel: LogLevel = .debug
    
    // 缓存（用于批量写入）
    private var logBuffer: [String] = []
    private let bufferSize = 10
    private let maxLogFileSize: UInt64 = 10 * 1024 * 1024 // 10MB
    
    private init() {
        // 创建日志目录
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logsDirectory = documentsPath.appendingPathComponent("MacAssistant/Logs")
        archiveDirectory = logsDirectory.appendingPathComponent("Archive")
        currentLogFile = logsDirectory.appendingPathComponent("mac-assistant-current.log")
        
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        
        // 初始化日志文件
        initializeLogFile()
        
        // 启动定时刷新
        startAutoFlush()
        
        // 记录启动日志
        log("🚀 Mac Assistant AutoAgent 启动", level: .info)
        log("📁 日志目录: \(logsDirectory.path)", level: .debug)
    }
    
    deinit {
        flushBuffer()
        fileHandle?.closeFile()
    }
    
    // MARK: - 初始化
    
    private func initializeLogFile() {
        // 如果当前日志文件存在且超过大小限制，归档它
        if FileManager.default.fileExists(atPath: currentLogFile.path) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: currentLogFile.path)
            let fileSize = attributes?[.size] as? UInt64 ?? 0
            
            if fileSize > maxLogFileSize {
                archiveCurrentLog()
            }
        }
        
        // 创建或打开日志文件
        if !FileManager.default.fileExists(atPath: currentLogFile.path) {
            FileManager.default.createFile(atPath: currentLogFile.path, contents: nil, attributes: nil)
        }
        
        fileHandle = try? FileHandle(forWritingTo: currentLogFile)
        fileHandle?.seekToEndOfFile()
        
        // 写入日志头
        let header = """
        \n========================================
        Mac Assistant AutoAgent Log
        Started at: \(Date())
        Version: \(getAppVersion())
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Device: \(ProcessInfo.processInfo.machineHardwareName)
        ========================================\n\n
        """
        appendToFile(header)
    }
    
    private func archiveCurrentLog() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let archiveName = "mac-assistant-\(dateFormatter.string(from: Date())).log"
        let archivePath = archiveDirectory.appendingPathComponent(archiveName)
        
        try? FileManager.default.moveItem(at: currentLogFile, to: archivePath)
        
        // 清理旧归档（保留最近30天）
        cleanOldArchives()
    }
    
    private func cleanOldArchives() {
        let cutoffDate = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: [.creationDateKey])
            for file in files {
                if let creationDate = try? FileManager.default.attributesOfItem(atPath: file.path)[.creationDate] as? Date,
                   creationDate < cutoffDate {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        } catch {
            print("清理旧日志失败: \(error)")
        }
    }
    
    // MARK: - 日志记录
    
    func log(_ message: String, 
             level: LogLevel = .info,
             file: String = #file,
             function: String = #function,
             line: Int = #line,
             additionalData: [String: Any]? = nil) {
        
        guard levelPriority(level) >= levelPriority(minimumLevel) else { return }
        
        let timestamp = Date()
        let thread = Thread.current.isMainThread ? "main" : "bg-\(Thread.current)"
        let filename = (file as NSString).lastPathComponent
        
        // 格式化消息
        let additionalString = additionalData?.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        let logLine = "[\(timestamp.logFormat)] [\(level.rawValue)] [\(thread)] \(filename):\(line) \(function) - \(message)\(additionalString != nil ? " | \(additionalString!)" : "")\n"
        
        // 同时输出到系统日志
        os_log("%{public}@", log: OSLog.default, type: level.osLogType, message)
        
        // 加入缓冲区
        writeQueue.async { [weak self] in
            self?.logBuffer.append(logLine)
            
            // 立即写入关键错误
            if level == .error || level == .critical {
                self?.flushBuffer()
            }
            
            // 缓冲区满了也写入
            if self?.logBuffer.count ?? 0 >= self?.bufferSize ?? 10 {
                self?.flushBuffer()
            }
        }
    }
    
    // MARK: - 缓冲区管理
    
    private func startAutoFlush() {
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.flushBuffer()
        }
    }
    
    private func flushBuffer() {
        writeQueue.async { [weak self] in
            guard let self = self, !self.logBuffer.isEmpty else { return }
            
            let content = self.logBuffer.joined()
            self.appendToFile(content)
            self.logBuffer.removeAll()
        }
    }
    
    private func appendToFile(_ content: String) {
        guard let data = content.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }
    
    // MARK: - 日志查询
    
    func getRecentLogs(lines: Int = 100) -> [String] {
        flushBuffer()
        
        guard let data = try? Data(contentsOf: currentLogFile),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        
        let allLines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return Array(allLines.suffix(lines).map(String.init))
    }
    
    func getLogsForLast(hours: Int) -> [LogEntry] {
        flushBuffer()
        
        let cutoffDate = Date().addingTimeInterval(-Double(hours * 3600))
        var entries: [LogEntry] = []
        
        // 读取当前日志
        entries.append(contentsOf: parseLogFile(currentLogFile, after: cutoffDate))
        
        // 读取今天的归档日志
        do {
            let files = try FileManager.default.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: nil)
            for file in files where file.lastPathComponent.contains("mac-assistant-") {
                entries.append(contentsOf: parseLogFile(file, after: cutoffDate))
            }
        } catch {}
        
        return entries.sorted { $0.timestamp > $1.timestamp }
    }
    
    func searchLogs(keyword: String, level: LogLevel? = nil) -> [LogEntry] {
        flushBuffer()
        
        let allLogs = getLogsForLast(hours: 24 * 7) // 搜索最近7天
        
        return allLogs.filter { entry in
            let matchKeyword = entry.message.lowercased().contains(keyword.lowercased())
            let matchLevel = level == nil || entry.level == level!.rawValue
            return matchKeyword && matchLevel
        }
    }
    
    func getLogFilePath() -> String {
        return currentLogFile.path
    }
    
    func exportLogs() -> URL? {
        flushBuffer()
        
        let exportName = "mac-assistant-logs-\(Date().logFileFormat).txt"
        let exportPath = logsDirectory.appendingPathComponent(exportName)
        
        do {
            // 合并所有日志
            var allLogs = ""
            
            // 添加当前日志
            if let currentData = try? Data(contentsOf: currentLogFile),
               let currentContent = String(data: currentData, encoding: .utf8) {
                allLogs += "=== 当前日志 ===\n\n" + currentContent + "\n\n"
            }
            
            // 添加最近3个归档
            let archives = try FileManager.default.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: [.creationDateKey])
                .sorted { url1, url2 in
                    let date1 = (try? FileManager.default.attributesOfItem(atPath: url1.path)[.creationDate] as? Date) ?? Date.distantPast
                    let date2 = (try? FileManager.default.attributesOfItem(atPath: url2.path)[.creationDate] as? Date) ?? Date.distantPast
                    return date1 > date2
                }
            
            for archive in archives.prefix(3) {
                if let data = try? Data(contentsOf: archive),
                   let content = String(data: data, encoding: .utf8) {
                    allLogs += "=== \(archive.lastPathComponent) ===\n\n" + content + "\n\n"
                }
            }
            
            try allLogs.write(to: exportPath, atomically: true, encoding: .utf8)
            return exportPath
        } catch {
            log("导出日志失败: \(error)", level: .error)
            return nil
        }
    }
    
    // MARK: - 辅助方法
    
    private func parseLogFile(_ url: URL, after date: Date) -> [LogEntry] {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        
        var entries: [LogEntry] = []
        let lines = content.split(separator: "\n")
        
        for line in lines {
            if let entry = parseLogLine(String(line)), entry.timestamp > date {
                entries.append(entry)
            }
        }
        
        return entries
    }
    
    private func parseLogLine(_ line: String) -> LogEntry? {
        // 解析格式: [2024-01-15 10:30:45] [INFO] [main] File.swift:10 function - message
        let pattern = "\\[(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2})\\] \\[(\\w+)\\] \\[(\\w+)\\] ([^:]+):(" + "\\d+) (\\w+) - (.+)$"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        
        guard let dateRange = Range(match.range(at: 1), in: line),
              let timestamp = dateFormatter.date(from: String(line[dateRange])),
              let levelRange = Range(match.range(at: 2), in: line),
              let threadRange = Range(match.range(at: 3), in: line),
              let fileRange = Range(match.range(at: 4), in: line),
              let lineRange = Range(match.range(at: 5), in: line),
              let functionRange = Range(match.range(at: 6), in: line),
              let messageRange = Range(match.range(at: 7), in: line) else {
            return nil
        }
        
        return LogEntry(
            id: UUID(),
            timestamp: timestamp,
            level: String(line[levelRange]),
            message: String(line[messageRange]),
            file: String(line[fileRange]),
            function: String(line[functionRange]),
            line: Int(line[lineRange]) ?? 0,
            thread: String(line[threadRange]),
            additionalData: nil
        )
    }
    
    private func levelPriority(_ level: LogLevel) -> Int {
        switch level {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        case .critical: return 4
        }
    }
    
    private func getAppVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

// MARK: - 便捷方法

func LogDebug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    FileLogger.shared.log(message, level: .debug, file: file, function: function, line: line)
}

func LogInfo(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    FileLogger.shared.log(message, level: .info, file: file, function: function, line: line)
}

func LogWarning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    FileLogger.shared.log(message, level: .warning, file: file, function: function, line: line)
}

func LogError(_ message: String, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    var additionalData: [String: Any]?
    if let error = error {
        additionalData = ["error": error.localizedDescription]
    }
    FileLogger.shared.log(message, level: .error, file: file, function: function, line: line, additionalData: additionalData)
}

func LogCritical(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    FileLogger.shared.log(message, level: .critical, file: file, function: function, line: line)
}

// MARK: - 扩展

extension Date {
    var logFormat: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: self)
    }
    
    var logFileFormat: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: self)
    }
}

extension ProcessInfo {
    var machineHardwareName: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let data = Data(bytes: &sysinfo.machine, count: Int(_SYS_NAMELEN))
        return String(data: data, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) ?? "unknown"
    }
}
