//
//  LogDiagnostics.swift
//  日志诊断分析工具
//

import Foundation
import SwiftUI

/// 诊断结果
struct DiagnosticReport {
    let timestamp: Date
    let summary: String
    let issues: [DiagnosticIssue]
    let recommendations: [String]
    let logStats: LogStatistics
    
    struct DiagnosticIssue: Identifiable {
        let id = UUID()
        let severity: IssueSeverity
        let category: IssueCategory
        let message: String
        let details: String
        let timestamp: Date?
    }
    
    enum IssueSeverity: String {
        case critical = "严重"
        case high = "高"
        case medium = "中"
        case low = "低"
        
        var emoji: String {
            switch self {
            case .critical: return "🚨"
            case .high: return "❌"
            case .medium: return "⚠️"
            case .low: return "ℹ️"
            }
        }
    }
    
    enum IssueCategory: String {
        case error = "错误"
        case performance = "性能"
        case permission = "权限"
        case network = "网络"
        case cli = "CLI工具"
        case system = "系统"
        case unknown = "未知"
    }
}

struct LogStatistics {
    let totalLines: Int
    let errorCount: Int
    let warningCount: Int
    let infoCount: Int
    let debugCount: Int
    let timeRange: (start: Date, end: Date)?
}

/// 日志诊断分析器
class LogDiagnostics {
    static let shared = LogDiagnostics()
    
    private init() {}
    
    /// 分析日志文件并生成诊断报告
    func analyzeLogs(entries: [LogEntry]) -> DiagnosticReport {
        let stats = calculateStatistics(entries: entries)
        var issues: [DiagnosticReport.DiagnosticIssue] = []
        var recommendations: [String] = []
        
        // 1. 分析错误日志
        let errors = entries.filter { $0.level == "ERROR" || $0.level == "CRITICAL" }
        for error in errors {
            if let issue = analyzeErrorEntry(error) {
                issues.append(issue)
            }
        }
        
        // 2. 分析警告日志
        let warnings = entries.filter { $0.level == "WARNING" }
        for warning in warnings {
            if let issue = analyzeWarningEntry(warning) {
                issues.append(issue)
            }
        }
        
        // 3. 检测特定问题模式
        issues.append(contentsOf: detectPatterns(in: entries))
        
        // 4. 生成建议
        recommendations = generateRecommendations(issues: issues, stats: stats)
        
        // 5. 生成总结
        let summary = generateSummary(issues: issues, stats: stats)
        
        return DiagnosticReport(
            timestamp: Date(),
            summary: summary,
            issues: issues.sorted { severityRank($0.severity) > severityRank($1.severity) },
            recommendations: recommendations,
            logStats: stats
        )
    }
    
    /// 导出诊断报告为文本
    func exportReport(_ report: DiagnosticReport) -> String {
        var text = """
        =========================================
        Mac Assistant 日志诊断报告
        生成时间: \(report.timestamp.logFormat)
        =========================================\n\n
        """
        
        text += "【总结】\n\(report.summary)\n\n"
        
        text += "【日志统计】\n"
        text += "- 总日志数: \(report.logStats.totalLines)\n"
        text += "- DEBUG: \(report.logStats.debugCount)\n"
        text += "- INFO: \(report.logStats.infoCount)\n"
        text += "- WARNING: \(report.logStats.warningCount)\n"
        text += "- ERROR: \(report.logStats.errorCount)\n"
        if let range = report.logStats.timeRange {
            text += "- 时间范围: \(range.start.logFormat) 至 \(range.end.logFormat)\n"
        }
        text += "\n"
        
        if !report.issues.isEmpty {
            text += "【发现问题 (\(report.issues.count)个)】\n\n"
            for (index, issue) in report.issues.enumerated() {
                text += "\(index + 1). \(issue.severity.emoji) [\(issue.severity.rawValue)] \(issue.category.rawValue)\n"
                text += "   问题: \(issue.message)\n"
                text += "   详情: \(issue.details)\n"
                if let time = issue.timestamp {
                    text += "   时间: \(time.logFormat)\n"
                }
                text += "\n"
            }
        } else {
            text += "【发现问题】\n未发现明显问题 ✅\n\n"
        }
        
        if !report.recommendations.isEmpty {
            text += "【建议】\n"
            for (index, rec) in report.recommendations.enumerated() {
                text += "\(index + 1). \(rec)\n"
            }
            text += "\n"
        }
        
        text += "=========================================\n"
        text += "报告生成完成\n"
        text += "=========================================\n"
        
        return text
    }
    
    // MARK: - 私有方法
    
    private func calculateStatistics(entries: [LogEntry]) -> LogStatistics {
        let errors = entries.filter { $0.level == "ERROR" || $0.level == "CRITICAL" }.count
        let warnings = entries.filter { $0.level == "WARNING" }.count
        let infos = entries.filter { $0.level == "INFO" }.count
        let debugs = entries.filter { $0.level == "DEBUG" }.count
        
        let timeRange: (Date, Date)?
        if let first = entries.first?.timestamp, let last = entries.last?.timestamp {
            timeRange = (first, last)
        } else {
            timeRange = nil
        }
        
        return LogStatistics(
            totalLines: entries.count,
            errorCount: errors,
            warningCount: warnings,
            infoCount: infos,
            debugCount: debugs,
            timeRange: timeRange
        )
    }
    
    private func analyzeErrorEntry(_ entry: LogEntry) -> DiagnosticReport.DiagnosticIssue? {
        let message = entry.message.lowercased()
        
        if message.contains("not found") || message.contains("未找到") {
            return DiagnosticReport.DiagnosticIssue(
                severity: .high,
                category: .cli,
                message: "CLI 工具未找到",
                details: entry.message,
                timestamp: entry.timestamp
            )
        }
        
        if message.contains("permission") || message.contains("权限") || message.contains("denied") {
            return DiagnosticReport.DiagnosticIssue(
                severity: .high,
                category: .permission,
                message: "权限被拒绝",
                details: entry.message,
                timestamp: entry.timestamp
            )
        }
        
        if message.contains("timeout") || message.contains("超时") {
            return DiagnosticReport.DiagnosticIssue(
                severity: .medium,
                category: .network,
                message: "操作超时",
                details: entry.message,
                timestamp: entry.timestamp
            )
        }
        
        if message.contains("kimi") {
            return DiagnosticReport.DiagnosticIssue(
                severity: .high,
                category: .cli,
                message: "Kimi CLI 错误",
                details: entry.message,
                timestamp: entry.timestamp
            )
        }
        
        if message.contains("openclaw") {
            return DiagnosticReport.DiagnosticIssue(
                severity: .medium,
                category: .cli,
                message: "OpenClaw 错误",
                details: entry.message,
                timestamp: entry.timestamp
            )
        }
        
        return DiagnosticReport.DiagnosticIssue(
            severity: .medium,
            category: .error,
            message: "一般错误",
            details: entry.message,
            timestamp: entry.timestamp
        )
    }
    
    private func analyzeWarningEntry(_ entry: LogEntry) -> DiagnosticReport.DiagnosticIssue? {
        let message = entry.message.lowercased()
        
        if message.contains("cpu") && (message.contains("high") || message.contains("90")) {
            return DiagnosticReport.DiagnosticIssue(
                severity: .medium,
                category: .performance,
                message: "CPU 使用率过高",
                details: entry.message,
                timestamp: entry.timestamp
            )
        }
        
        if message.contains("memory") || message.contains("内存") {
            return DiagnosticReport.DiagnosticIssue(
                severity: .medium,
                category: .performance,
                message: "内存压力",
                details: entry.message,
                timestamp: entry.timestamp
            )
        }
        
        if message.contains("fail") || message.contains("失败") {
            return DiagnosticReport.DiagnosticIssue(
                severity: .low,
                category: .unknown,
                message: "操作可能失败",
                details: entry.message,
                timestamp: entry.timestamp
            )
        }
        
        return nil
    }
    
    private func detectPatterns(in entries: [LogEntry]) -> [DiagnosticReport.DiagnosticIssue] {
        var issues: [DiagnosticReport.DiagnosticIssue] = []
        
        // 检测重复错误
        let errorMessages = entries
            .filter { $0.level == "ERROR" }
            .map { $0.message }
        
        var messageCounts: [String: Int] = [:]
        for msg in errorMessages {
            messageCounts[msg, default: 0] += 1
        }
        
        for (msg, count) in messageCounts where count > 3 {
            issues.append(DiagnosticReport.DiagnosticIssue(
                severity: .high,
                category: .error,
                message: "重复错误发生 \(count) 次",
                details: "错误: \(msg.prefix(100))...",
                timestamp: nil
            ))
        }
        
        // 检测启动问题
        let startErrors = entries.filter { 
            $0.level == "ERROR" && $0.function.contains("init") 
        }
        if !startErrors.isEmpty {
            issues.append(DiagnosticReport.DiagnosticIssue(
                severity: .critical,
                category: .system,
                message: "启动时发生错误",
                details: "发现 \(startErrors.count) 个初始化错误",
                timestamp: startErrors.first?.timestamp
            ))
        }
        
        // 检测通知权限问题
        let notificationErrors = entries.filter {
            $0.message.lowercased().contains("notification") ||
            $0.message.contains("通知")
        }
        if !notificationErrors.isEmpty {
            issues.append(DiagnosticReport.DiagnosticIssue(
                severity: .medium,
                category: .permission,
                message: "通知权限问题",
                details: "检测到通知相关错误，请检查系统通知权限",
                timestamp: notificationErrors.first?.timestamp
            ))
        }
        
        return issues
    }
    
    private func generateRecommendations(issues: [DiagnosticReport.DiagnosticIssue], stats: LogStatistics) -> [String] {
        var recommendations: [String] = []
        
        // 按问题类型生成建议
        let categories = Set(issues.map { $0.category })
        
        if categories.contains(.cli) {
            recommendations.append("确保 kimi 和 openclaw CLI 工具已正确安装并在 PATH 中")
            recommendations.append("运行 'which kimi' 和 'which openclaw' 检查工具可用性")
        }
        
        if categories.contains(.permission) {
            recommendations.append("检查应用的通知权限和文件访问权限")
            recommendations.append("在系统设置 > 隐私与安全中检查相关权限")
        }
        
        if categories.contains(.performance) {
            recommendations.append("关闭不必要的应用程序以释放系统资源")
            recommendations.append("考虑重启应用或系统")
        }
        
        if categories.contains(.network) {
            recommendations.append("检查网络连接状态")
            recommendations.append("如果使用了代理/VPN，请检查配置")
        }
        
        if stats.errorCount > 10 {
            recommendations.append("错误较多，建议重启应用")
        }
        
        if recommendations.isEmpty && stats.errorCount == 0 {
            recommendations.append("日志看起来正常，无需特殊处理 ✅")
        }
        
        return recommendations
    }
    
    private func generateSummary(issues: [DiagnosticReport.DiagnosticIssue], stats: LogStatistics) -> String {
        let criticalCount = issues.filter { $0.severity == .critical }.count
        let highCount = issues.filter { $0.severity == .high }.count
        
        if criticalCount > 0 {
            return "发现 \(criticalCount) 个严重问题，需要立即处理。建议查看详细报告并修复问题。"
        } else if highCount > 0 {
            return "发现 \(highCount) 个高优先级问题，建议尽快处理。"
        } else if !issues.isEmpty {
            return "发现 \(issues.count) 个中低优先级问题，可根据需要进行处理。"
        } else if stats.errorCount == 0 {
            return "未发现问题，应用运行正常 ✅"
        } else {
            return "日志分析完成，发现 \(stats.errorCount) 个错误。"
        }
    }
    
    private func severityRank(_ severity: DiagnosticReport.IssueSeverity) -> Int {
        switch severity {
        case .critical: return 4
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }
}

// MARK: - 诊断报告视图

import SwiftUI

struct DiagnosticReportView: View {
    let report: DiagnosticReport
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("🔍 日志诊断报告")
                    .font(.headline)
                
                Spacer()
                
                Button("📋 复制报告") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(LogDiagnostics.shared.exportReport(report), forType: .string)
                }
                .buttonStyle(.borderless)
                
                Button("💾 导出") {
                    exportReport()
                }
                .buttonStyle(.borderless)
                
                Divider()
                    .frame(height: 20)
                
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 总结
            HStack {
                Image(systemName: summaryIcon)
                    .foregroundColor(summaryColor)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.summary)
                        .font(.system(size: 13))
                    Text("生成于 \(report.timestamp.logFormat)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    StatBadge2(icon: "❌", value: report.logStats.errorCount, color: .red)
                    StatBadge2(icon: "⚠️", value: report.logStats.warningCount, color: .orange)
                }
            }
            .padding()
            .background(summaryColor.opacity(0.1))
            
            Divider()
            
            // 问题列表
            if report.issues.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)
                    Text("未发现明显问题")
                        .font(.headline)
                    Text("应用运行正常")
                        .foregroundColor(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                List(report.issues) { issue in
                    IssueRow(issue: issue)
                }
                .listStyle(.plain)
            }
            
            Divider()
            
            // 建议
            VStack(alignment: .leading, spacing: 8) {
                Text("💡 建议")
                    .font(.headline)
                
                ForEach(report.recommendations, id: \.self) { rec in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                        Text(rec)
                            .font(.system(size: 12))
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(minWidth: 700, minHeight: 500)
    }
    
    private var summaryIcon: String {
        let critical = report.issues.filter { $0.severity == .critical }.count
        let high = report.issues.filter { $0.severity == .high }.count
        
        if critical > 0 { return "xmark.octagon.fill" }
        if high > 0 { return "exclamationmark.triangle.fill" }
        if !report.issues.isEmpty { return "exclamationmark.circle.fill" }
        return "checkmark.circle.fill"
    }
    
    private var summaryColor: Color {
        let critical = report.issues.filter { $0.severity == .critical }.count
        let high = report.issues.filter { $0.severity == .high }.count
        
        if critical > 0 { return .red }
        if high > 0 { return .orange }
        if !report.issues.isEmpty { return .yellow }
        return .green
    }
    
    private func exportReport() {
        let text = LogDiagnostics.shared.exportReport(report)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "诊断报告-\(Date().logFileFormat).txt"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        }
    }
}

struct IssueRow: View {
    let issue: DiagnosticReport.DiagnosticIssue
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(issue.severity.emoji)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(issue.message)
                        .font(.system(size: 13, weight: .medium))
                    
                    Spacer()
                    
                    Text(issue.category.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(categoryColor.opacity(0.2))
                        .foregroundColor(categoryColor)
                        .cornerRadius(4)
                }
                
                Text(issue.details)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                
                if let time = issue.timestamp {
                    Text(time.logFormat)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var categoryColor: Color {
        switch issue.category {
        case .error: return .red
        case .performance: return .orange
        case .permission: return .purple
        case .network: return .blue
        case .cli: return .green
        case .system: return .gray
        case .unknown: return .secondary
        }
    }
}

struct StatBadge2: View {
    let icon: String
    let value: Int
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Text(icon)
            Text("\(value)")
                .fontWeight(.bold)
                .foregroundColor(color)
        }
        .font(.caption)
    }
}

#Preview {
    DiagnosticReportView(report: DiagnosticReport(
        timestamp: Date(),
        summary: "测试报告总结",
        issues: [
            DiagnosticReport.DiagnosticIssue(
                severity: .high,
                category: .cli,
                message: "Kimi 工具未找到",
                details: "请在终端运行 'brew install kimi-cli' 安装",
                timestamp: Date()
            )
        ],
        recommendations: ["安装 Kimi CLI 工具"],
        logStats: LogStatistics(
            totalLines: 100,
            errorCount: 2,
            warningCount: 5,
            infoCount: 80,
            debugCount: 13,
            timeRange: (Date().addingTimeInterval(-3600), Date())
        )
    ))
}
