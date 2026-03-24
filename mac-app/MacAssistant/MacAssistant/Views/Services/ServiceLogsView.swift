//
//  ServiceLogsView.swift
//  MacAssistant
//
//  服务日志查看视图
//

import SwiftUI

struct ServiceLogsView: View {
    let service: ServiceDefinition
    
    @StateObject private var logManager = ServiceLogManager.shared
    @State private var searchText = ""
    @State private var selectedLevel: ServiceLogEntry.LogLevel?
    @State private var isRealtime = false
    @State private var autoScroll = true
    @State private var showingExportSheet = false
    
    private var filteredLogs: [ServiceLogEntry] {
        guard let logs = logManager.logs[service.id] else { return [] }
        
        return logs.filter { entry in
            // 级别过滤
            if let selectedLevel = selectedLevel, entry.level != selectedLevel {
                return false
            }
            
            // 搜索过滤
            if !searchText.isEmpty {
                return entry.message.lowercased().contains(searchText.lowercased())
            }
            
            return true
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            logList
        }
        .background(Color(.windowBackgroundColor))
        .onAppear {
            loadLogs()
        }
        .onDisappear {
            if isRealtime {
                logManager.stopRealtimeLogs(for: service.id)
            }
        }
    }
    
    // MARK: - Header
    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(service.name) 日志")
                    .font(.system(size: 16, weight: .semibold))
                Text(logManager.isLoading[service.id] == true ? "加载中..." : "\(filteredLogs.count) 条日志")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // 实时模式切换
            Toggle(isOn: $isRealtime) {
                HStack(spacing: 4) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 10))
                    Text("实时")
                        .font(.system(size: 11))
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .onChange(of: isRealtime) { newValue in
                if newValue {
                    startRealtimeLogs()
                } else {
                    logManager.stopRealtimeLogs(for: service.id)
                }
            }
            
            // 导出按钮
            Button {
                showingExportSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("导出日志")
            .disabled(filteredLogs.isEmpty)
        }
        .padding()
    }
    
    // MARK: - Toolbar
    private var toolbar: some View {
        HStack(spacing: 12) {
            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索日志...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: 200)
            
            // 级别筛选
            Picker("级别", selection: $selectedLevel) {
                Text("全部").tag(nil as ServiceLogEntry.LogLevel?)
                ForEach(ServiceLogEntry.LogLevel.allCases, id: \.self) { level in
                    Text(level.rawValue).tag(level as ServiceLogEntry.LogLevel?)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 300)
            
            Spacer()
            
            // 自动滚动
            Toggle(isOn: $autoScroll) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 10))
                    Text("自动滚动")
                        .font(.system(size: 11))
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            
            // 刷新按钮
            Button {
                loadLogs()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("刷新")
            .disabled(logManager.isLoading[service.id] == true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
    }
    
    // MARK: - Log List
    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredLogs) { entry in
                        ServiceLogEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: filteredLogs.count) { _ in
                if autoScroll, let last = filteredLogs.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    // MARK: - Methods
    @MainActor
    private func loadLogs() {
        Task {
            // 尝试通过运行时信息获取日志路径
            var logPath: String? = nil
            
            // 常见日志路径模式
            let patterns = [
                "~/Library/Logs/\(service.name)/\(service.name).log",
                "~/Library/Logs/\(service.id)/\(service.id).log",
                "\(service.path ?? "~")/logs/\(service.id).log",
                "\(service.path ?? "~")/log/\(service.id).log",
                "\(service.path ?? "~")/\(service.id).log"
            ]
            
            let fileManager = FileManager.default
            for pattern in patterns {
                let expanded = pattern.replacingOccurrences(of: "~", with: NSHomeDirectory())
                if fileManager.fileExists(atPath: expanded) {
                    logPath = expanded
                    break
                }
            }
            
            if let path = logPath {
                await logManager.loadLogs(
                    for: service.id,
                    from: path,
                    maxLines: 500
                )
            } else if let pid = UnifiedServiceState.shared.runtimeInfos[service.id]?.pid {
                await logManager.loadLogsFromProcess(
                    for: service.id,
                    pid: pid,
                    maxLines: 500
                )
            }
        }
    }
    
    private func startRealtimeLogs() {
        Task {
            // 获取日志路径
            var logPath: String? = nil
            let patterns = [
                "~/Library/Logs/\(service.name)/\(service.name).log",
                "~/Library/Logs/\(service.id)/\(service.id).log",
                "\(service.path ?? "~")/logs/\(service.id).log",
                "\(service.path ?? "~")/log/\(service.id).log"
            ]
            
            let fileManager = FileManager.default
            for pattern in patterns {
                let expanded = pattern.replacingOccurrences(of: "~", with: NSHomeDirectory())
                if fileManager.fileExists(atPath: expanded) {
                    logPath = expanded
                    break
                }
            }
            
            guard let path = logPath else { return }
            
            logManager.startRealtimeLogs(for: service.id, from: path) { newEntry in
                // 新日志条目会自动添加到 logManager.logs 中
            }
        }
    }
}

// MARK: - Log Entry Row
struct ServiceLogEntryRow: View {
    let entry: ServiceLogEntry
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // 时间戳
                Text(timeString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                
                // 级别标签
                LevelBadge(level: entry.level)
                    .frame(width: 50, alignment: .leading)
                
                // 消息
                Text(entry.message)
                    .font(.system(size: 11))
                    .lineLimit(isExpanded ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // 展开按钮（如果消息较长）
                if entry.message.count > 100 {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(backgroundColor.opacity(0.05))
        .contentShape(Rectangle())
        .onTapGesture {
            isExpanded.toggle()
        }
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: entry.timestamp)
    }
    
    private var backgroundColor: Color {
        switch entry.level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .fatal: return .purple
        }
    }
}

// MARK: - Level Badge
struct LevelBadge: View {
    let level: ServiceLogEntry.LogLevel
    
    var body: some View {
        Text(level.rawValue)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .cornerRadius(3)
    }
    
    private var color: Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .fatal: return .purple
        }
    }
}

// MARK: - Export Sheet
struct LogExportSheet: View {
    let service: ServiceDefinition
    let logs: [ServiceLogEntry]
    
    @Environment(\.dismiss) private var dismiss
    @State private var exportPath = ""
    @State private var includeTimestamp = true
    @State private var includeLevel = true
    @State private var isExporting = false
    
    var body: some View {
        VStack(spacing: 16) {
            Text("导出日志")
                .font(.system(size: 16, weight: .semibold))
            
            VStack(alignment: .leading, spacing: 8) {
                Text("导出路径")
                    .font(.system(size: 12))
                
                HStack {
                    TextField("选择保存位置", text: $exportPath)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("选择...") {
                        selectExportPath()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("导出选项")
                    .font(.system(size: 12))
                
                Toggle("包含时间戳", isOn: $includeTimestamp)
                Toggle("包含日志级别", isOn: $includeLevel)
            }
            
            HStack {
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("导出") {
                    exportLogs()
                }
                .buttonStyle(.borderedProminent)
                .disabled(exportPath.isEmpty || isExporting)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
    
    private func selectExportPath() {
        // 这里应该打开文件选择对话框
        // 简化实现，使用默认路径
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateString = dateFormatter.string(from: Date())
        
        exportPath = "\(NSHomeDirectory())/Downloads/\(service.id)_logs_\(dateString).txt"
    }
    
    private func exportLogs() {
        isExporting = true
        
        let content = logs.map { entry in
            var parts: [String] = []
            if includeTimestamp {
                parts.append("[\(entry.timestamp)]")
            }
            if includeLevel {
                parts.append("[\(entry.level.rawValue)]")
            }
            parts.append(entry.message)
            return parts.joined(separator: " ")
        }.joined(separator: "\n")
        
        do {
            try content.write(toFile: exportPath, atomically: true, encoding: .utf8)
            dismiss()
        } catch {
            // 显示错误
            isExporting = false
        }
    }
}

// MARK: - Preview
struct ServiceLogsView_Previews: PreviewProvider {
    static var previews: some View {
        ServiceLogsView(service: ServiceManager.shared.services.first!)
            .frame(width: 800, height: 600)
    }
}
