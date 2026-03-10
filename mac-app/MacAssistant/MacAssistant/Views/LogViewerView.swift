//
//  LogViewerView.swift
//  日志查看器
//

import SwiftUI
import Combine

struct LogViewerView: View {
    @StateObject private var viewModel = LogViewerViewModel()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("📋 日志查看器")
                    .font(.headline)
                
                Spacer()
                
                // 日志文件路径
                Text(viewModel.logFilePath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300)
                
                Button("📂 打开目录") {
                    viewModel.openLogDirectory()
                }
                .buttonStyle(.borderless)
                
                Divider()
                    .frame(height: 20)
                
                Button("🔄 刷新") {
                    viewModel.refreshLogs()
                }
                .buttonStyle(.borderless)
                
                Button("💾 导出") {
                    viewModel.exportLogs()
                }
                .buttonStyle(.borderless)
                
                Button("🔍 诊断分析") {
                    viewModel.showDiagnostics()
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
            
            // 搜索和过滤
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索日志...", text: $viewModel.searchKeyword)
                        .textFieldStyle(.plain)
                    if !viewModel.searchKeyword.isEmpty {
                        Button(action: { viewModel.searchKeyword = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                
                Picker("级别", selection: $viewModel.selectedLevel) {
                    Text("全部").tag(nil as LogLevel?)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text("\(level.emoji) \(level.rawValue)").tag(level as LogLevel?)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
                
                Picker("时间", selection: $viewModel.timeRange) {
                    Text("最近100行").tag(LogTimeRange.last100)
                    Text("最近1小时").tag(LogTimeRange.lastHour)
                    Text("最近24小时").tag(LogTimeRange.lastDay)
                    Text("最近7天").tag(LogTimeRange.lastWeek)
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                
                Toggle("自动刷新", isOn: $viewModel.autoRefresh)
                    .toggleStyle(.checkbox)
            }
            .padding()
            
            Divider()
            
            // 统计信息
            HStack(spacing: 16) {
                StatBadge(
                    icon: "🔍",
                    label: "DEBUG",
                    count: viewModel.stats.debugCount,
                    color: .gray
                )
                StatBadge(
                    icon: "ℹ️",
                    label: "INFO",
                    count: viewModel.stats.infoCount,
                    color: .blue
                )
                StatBadge(
                    icon: "⚠️",
                    label: "WARNING",
                    count: viewModel.stats.warningCount,
                    color: .orange
                )
                StatBadge(
                    icon: "❌",
                    label: "ERROR",
                    count: viewModel.stats.errorCount,
                    color: .red
                )
                StatBadge(
                    icon: "🚨",
                    label: "CRITICAL",
                    count: viewModel.stats.criticalCount,
                    color: .purple
                )
                
                Spacer()
                
                Text("共 \(viewModel.filteredEntries.count) 条")
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            // 日志列表
            List(viewModel.filteredEntries) { entry in
                LogEntryRow(entry: entry)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .contextMenu {
                        Button("复制") {
                            viewModel.copyEntry(entry)
                        }
                        Button("搜索相同级别") {
                            viewModel.selectedLevel = LogLevel(rawValue: entry.level)
                        }
                    }
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: $viewModel.showDiagnosticSheet) {
            if let report = viewModel.diagnosticReport {
                DiagnosticReportView(report: report)
            }
        }
        .onAppear {
            viewModel.refreshLogs()
        }
    }
}

// MARK: - 日志条目行

struct LogEntryRow: View {
    let entry: LogEntry
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                // 级别图标
                Text(levelEmoji)
                    .font(.caption)
                
                // 时间
                Text(entry.timestamp.logFormat)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 140, alignment: .leading)
                
                // 级别标签
                Text(entry.level)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(levelColor.opacity(0.2))
                    .foregroundColor(levelColor)
                    .cornerRadius(4)
                    .frame(width: 70, alignment: .center)
                
                // 线程
                Text(entry.thread)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .leading)
                
                // 消息
                Text(entry.message)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(isExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // 展开时显示文件信息
            if isExpanded {
                HStack {
                    Text("\(entry.file):\(entry.line) \(entry.function)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.leading, 220)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            isExpanded.toggle()
        }
    }
    
    private var levelEmoji: String {
        LogLevel(rawValue: entry.level)?.emoji ?? "📝"
    }
    
    private var levelColor: Color {
        switch entry.level {
        case "DEBUG": return .gray
        case "INFO": return .blue
        case "WARNING": return .orange
        case "ERROR": return .red
        case "CRITICAL": return .purple
        default: return .primary
        }
    }
}

// MARK: - 统计徽章

struct StatBadge: View {
    let icon: String
    let label: String
    let count: Int
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Text(icon)
            Text("\(label):")
                .font(.caption)
            Text("\(count)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }
}

// MARK: - ViewModel

@MainActor
class LogViewerViewModel: ObservableObject {
    @Published var entries: [LogEntry] = []
    @Published var filteredEntries: [LogEntry] = []
    @Published var searchKeyword = ""
    @Published var selectedLevel: LogLevel?
    @Published var timeRange: LogTimeRange = .last100
    @Published var autoRefresh = false
    @Published var logFilePath = ""
    @Published var stats = LogStats()
    @Published var diagnosticReport: DiagnosticReport?
    @Published var showDiagnosticSheet = false
    
    private var refreshTimer: Timer?
    
    init() {
        logFilePath = FileLogger.shared.getLogFilePath()
        
        // 监听搜索和过滤变化
        Publishers.CombineLatest3($searchKeyword, $selectedLevel, $timeRange)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] (_: String, _: LogLevel?, _: LogTimeRange) in
                self?.applyFilters()
            }
            .store(in: &cancellables)
        
        // 监听自动刷新
        $autoRefresh
            .sink { [weak self] enabled in
                if enabled {
                    self?.startAutoRefresh()
                } else {
                    self?.stopAutoRefresh()
                }
            }
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    func refreshLogs() {
        Task {
            let logs: [LogEntry]
            switch timeRange {
            case .last100:
                logs = FileLogger.shared.getLogsForLast(hours: 24)
                    .sorted { $0.timestamp > $1.timestamp }
                    .prefix(100)
                    .map { $0 }
            case .lastHour:
                logs = FileLogger.shared.getLogsForLast(hours: 1)
            case .lastDay:
                logs = FileLogger.shared.getLogsForLast(hours: 24)
            case .lastWeek:
                logs = FileLogger.shared.getLogsForLast(hours: 24 * 7)
            }
            
            await MainActor.run {
                self.entries = logs
                self.applyFilters()
                self.calculateStats()
            }
        }
    }
    
    func applyFilters() {
        filteredEntries = entries.filter { entry in
            // 级别过滤
            if let level = selectedLevel, entry.level != level.rawValue {
                return false
            }
            
            // 关键词搜索
            if !searchKeyword.isEmpty {
                let keyword = searchKeyword.lowercased()
                return entry.message.lowercased().contains(keyword) ||
                       entry.file.lowercased().contains(keyword) ||
                       entry.function.lowercased().contains(keyword)
            }
            
            return true
        }
    }
    
    func calculateStats() {
        stats = LogStats(
            debugCount: entries.filter { $0.level == "DEBUG" }.count,
            infoCount: entries.filter { $0.level == "INFO" }.count,
            warningCount: entries.filter { $0.level == "WARNING" }.count,
            errorCount: entries.filter { $0.level == "ERROR" }.count,
            criticalCount: entries.filter { $0.level == "CRITICAL" }.count
        )
    }
    
    func copyEntry(_ entry: LogEntry) {
        let text = "[\(entry.timestamp.logFormat)] [\(entry.level)] \(entry.file):\(entry.line) - \(entry.message)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    func openLogDirectory() {
        let url = URL(fileURLWithPath: logFilePath).deletingLastPathComponent()
        NSWorkspace.shared.open(url)
    }
    
    func exportLogs() {
        if let exportURL = FileLogger.shared.exportLogs() {
            NSWorkspace.shared.selectFile(exportURL.path, inFileViewerRootedAtPath: "")
        }
    }
    
    func showDiagnostics() {
        LogInfo("🔍 用户请求诊断分析")
        let report = LogDiagnostics.shared.analyzeLogs(entries: entries)
        diagnosticReport = report
        showDiagnosticSheet = true
    }
    
    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLogs()
            }
        }
    }
    
    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - 辅助类型

enum LogTimeRange {
    case last100
    case lastHour
    case lastDay
    case lastWeek
}

struct LogStats {
    var debugCount = 0
    var infoCount = 0
    var warningCount = 0
    var errorCount = 0
    var criticalCount = 0
}

// MARK: - Preview

#Preview {
    LogViewerView()
}
