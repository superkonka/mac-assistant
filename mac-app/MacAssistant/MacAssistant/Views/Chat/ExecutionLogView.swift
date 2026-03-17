//
//  ExecutionLogView.swift
//  MacAssistant
//
//  执行链路CLI日志视图 - 实时展示链路详细信息
//

import SwiftUI

struct ExecutionLogView: View {
    let sessionID: String
    @StateObject private var logger = ExecutionLogger.shared
    @State private var selectedLevel: ExecutionLogLevel? = nil
    @State private var autoScroll = true
    @State private var showTimestamps = true
    @State private var isCompactMode = false
    @Environment(\.dismiss) private var dismiss
    
    private var session: ExecutionSession? {
        logger.getSession(sessionID)
    }
    
    private var filteredEntries: [ExecutionLogEntry] {
        guard let session = session else { return [] }
        if let level = selectedLevel {
            return session.entries.filter { $0.level >= level }
        }
        return session.entries
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            headerView
            
            Divider()
            
            // 会话信息
            sessionInfoView
            
            Divider()
            
            // 工具栏
            toolbarView
            
            Divider()
            
            // 日志列表
            logListView
            
            Divider()
            
            // 底部状态
            footerView
        }
        .frame(width: 700, height: 500)
        .background(Color.black.opacity(0.02))
    }
    
    // MARK: - 子视图
    
    private var headerView: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            VStack(spacing: 2) {
                Text("执行链路日志")
                    .font(.system(size: 14, weight: .semibold))
                
                if let session = session {
                    Text("Session: \(session.id.prefix(8))...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button(action: { 
                if let session = session {
                    let pasteboard = NSPasteboard.general
                    let logText = session.entries.map { $0.cliFormatted }.joined(separator: "\n")
                    pasteboard.clearContents()
                    pasteboard.setString(logText, forType: .string)
                }
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("复制全部日志")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.05))
    }
    
    private var sessionInfoView: some View {
        HStack(spacing: 16) {
            // 状态指示器
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                
                Text(session?.status.rawValue.uppercased() ?? "UNKNOWN")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(statusColor)
            }
            
            Divider()
                .frame(height: 16)
            
            // 时长
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                Text(session?.formattedDuration ?? "--")
                    .font(.system(size: 11))
            }
            .foregroundColor(.secondary)
            
            Divider()
                .frame(height: 16)
            
            // 日志数量
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                Text("\(session?.entries.count ?? 0) 条")
                    .font(.system(size: 11))
            }
            .foregroundColor(.secondary)
            
            Spacer()
            
            // 当前Agent
            if let agent = session?.currentAgent {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                    Text(agent)
                        .font(.system(size: 11))
                }
                .foregroundColor(.blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.03))
    }
    
    private var toolbarView: some View {
        HStack(spacing: 12) {
            // 日志级别筛选
            Menu {
                Button("全部") { selectedLevel = nil }
                Divider()
                ForEach([ExecutionLogLevel.success, .info, .warning, .error, .debug], id: \.self) { level in
                    Button(level.icon + " " + level.rawValue) {
                        selectedLevel = level
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 11))
                    Text(selectedLevel?.rawValue ?? "全部")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            
            // 自动滚动开关
            Toggle(isOn: $autoScroll) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 10))
                    Text("自动滚动")
                        .font(.system(size: 11))
                }
            }
            .toggleStyle(.checkbox)
            
            // 时间戳开关
            Toggle(isOn: $showTimestamps) {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text("时间戳")
                        .font(.system(size: 11))
                }
            }
            .toggleStyle(.checkbox)
            
            // 紧凑模式
            Toggle(isOn: $isCompactMode) {
                HStack(spacing: 4) {
                    Image(systemName: "text.compress")
                        .font(.system(size: 10))
                    Text("紧凑")
                        .font(.system(size: 11))
                }
            }
            .toggleStyle(.checkbox)
            
            Spacer()
            
            // 清除按钮
            Button(action: { logger.clearHistory() }) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("清除历史")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.03))
    }
    
    private var logListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: isCompactMode ? 2 : 4) {
                    ForEach(filteredEntries) { entry in
                        ExecutionLogEntryRow(
                            entry: entry,
                            showTimestamp: showTimestamps,
                            isCompact: isCompactMode
                        )
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color.black.opacity(0.02))
            .onChange(of: filteredEntries.count) { _ in
                if autoScroll, let last = filteredEntries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .font(.system(size: isCompactMode ? 11 : 12, design: .monospaced))
    }
    
    private var footerView: some View {
        HStack {
            Text("按 ⌘+C 复制选中日志")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            
            Spacer()
            
            if let session = session {
                HStack(spacing: 8) {
                    // 各级别日志计数
                    ForEach([ExecutionLogLevel.error, .warning, .info], id: \.self) { level in
                        let count = session.entries.filter { $0.level == level }.count
                        if count > 0 {
                            HStack(spacing: 2) {
                                Text(level.icon)
                                    .font(.system(size: 9))
                                Text("\(count)")
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(level == .error ? .red : (level == .warning ? .orange : .blue))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.03))
    }
    
    // MARK: - 辅助属性
    
    private var statusColor: Color {
        guard let session = session else { return .gray }
        switch session.status {
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

// MARK: - 日志条目行

struct ExecutionLogEntryRow: View {
    let entry: ExecutionLogEntry
    let showTimestamp: Bool
    let isCompact: Bool
    @State private var isHovered = false
    @State private var showDetails = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 0 : 2) {
            HStack(alignment: .top, spacing: 8) {
                // 级别图标
                Text(entry.level.icon)
                    .font(.system(size: isCompact ? 10 : 12))
                    .frame(width: 16, alignment: .center)
                
                // 时间戳
                if showTimestamp {
                    Text(entry.formattedTime)
                        .font(.system(size: isCompact ? 9 : 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 70, alignment: .leading)
                }
                
                // 组件名
                Text("[\(entry.component)]")
                    .font(.system(size: isCompact ? 10 : 11, design: .monospaced))
                    .foregroundColor(.blue.opacity(0.8))
                    .frame(minWidth: 80, alignment: .leading)
                
                // 消息
                Text(entry.message)
                    .font(.system(size: isCompact ? 10 : 11))
                    .foregroundColor(.primary)
                    .lineLimit(showDetails ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // 详情展开
            if showDetails, let details = entry.details, !details.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(details.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                        HStack(spacing: 4) {
                            Text("  →")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            Text(key)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(":")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(value)
                                .font(.system(size: 10))
                                .foregroundColor(.primary.opacity(0.8))
                                .lineLimit(3)
                        }
                    }
                }
                .padding(.leading, showTimestamp ? 94 : 24)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, isCompact ? 1 : 3)
        .padding(.horizontal, 4)
        .background(isHovered ? Color.secondary.opacity(0.08) : Color.clear)
        .cornerRadius(4)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            showDetails.toggle()
        }
        .contextMenu {
            Button("复制") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(entry.cliFormatted, forType: .string)
            }
            Button("查看详情") {
                showDetails.toggle()
            }
        }
    }
}

// MARK: - 入口按钮

struct ExecutionLogButton: View {
    let sessionID: String
    @State private var showLogView = false
    @StateObject private var logger = ExecutionLogger.shared
    
    private var unreadCount: Int {
        logger.getSession(sessionID)?.entries.count ?? 0
    }
    
    var body: some View {
        Button(action: { showLogView = true }) {
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                Text("日志")
                    .font(.system(size: 11))
                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(PlainButtonStyle())
        .help("查看执行链路日志")
        .sheet(isPresented: $showLogView) {
            ExecutionLogView(sessionID: sessionID)
        }
    }
}

#Preview {
    ExecutionLogView(sessionID: "preview-session")
}
