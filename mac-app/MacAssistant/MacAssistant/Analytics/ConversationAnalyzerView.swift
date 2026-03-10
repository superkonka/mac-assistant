//
//  ConversationAnalyzerView.swift
//  MacAssistant
//
//  对话分析视图 - 可视化展示日志和分析结果
//

import SwiftUI

struct ConversationAnalyzerView: View {
    @StateObject private var logger = ConversationLogger.shared
    @StateObject private var analyzer = ConversationAnalyzer.shared
    
    @State private var selectedSession: SessionStats?
    @State private var events: [ConversationEvent] = []
    @State private var report: AnalysisReport?
    @State private var isAnalyzing = false
    
    var body: some View {
        NavigationView {
            // 左侧：会话列表
            sessionList
                .frame(minWidth: 200)
            
            // 中间：事件时间线
            eventTimeline
                .frame(minWidth: 400)
            
            // 右侧：分析报告
            analysisPanel
                .frame(minWidth: 300)
        }
        .frame(minWidth: 1000, minHeight: 600)
        .onAppear {
            loadSessions()
        }
    }
    
    // MARK: - 子视图
    
    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("会话列表")
                    .font(.headline)
                Spacer()
                Button(action: { logger.startNewSession(); loadSessions() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding()
            
            Divider()
            
            List(logger.getSessions(), selection: $selectedSession) { session in
                SessionRow(session: session)
            }
        }
    }
    
    private var eventTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedSession?.sessionId ?? "选择一个会话")
                    .font(.headline)
                Spacer()
                if selectedSession != nil {
                    Button(action: analyzeCurrentSession) {
                        Image(systemName: "play.circle")
                        Text("分析")
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isAnalyzing)
                }
            }
            .padding()
            
            Divider()
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(events) { event in
                        EventRow(event: event)
                    }
                }
                .padding()
            }
        }
    }
    
    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("分析报告")
                .font(.headline)
                .padding()
            
            Divider()
            
            if let report = report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // 摘要
                        SummarySection(report: report)
                        
                        // 指标
                        MetricsSection(metrics: report.metrics)
                        
                        // 严重问题
                        if !report.criticalIssues.isEmpty {
                            IssuesSection(title: "严重问题", issues: report.criticalIssues, color: .red)
                        }
                        
                        // 重要问题
                        if !report.majorIssues.isEmpty {
                            IssuesSection(title: "重要问题", issues: report.majorIssues, color: .orange)
                        }
                        
                        // 轻微问题
                        if !report.minorIssues.isEmpty {
                            IssuesSection(title: "轻微问题", issues: report.minorIssues, color: .yellow)
                        }
                        
                        // 建议
                        if !report.suggestions.isEmpty {
                            IssuesSection(title: "优化建议", issues: report.suggestions, color: .blue)
                        }
                    }
                    .padding()
                }
            } else {
                Spacer()
                Text("点击"分析"生成报告")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
        }
    }
    
    // MARK: - 动作
    
    private func loadSessions() {
        // 刷新列表
    }
    
    private func analyzeCurrentSession() {
        guard let session = selectedSession else { return }
        
        isAnalyzing = true
        events = logger.loadSession(session.sessionId)
        
        DispatchQueue.global().async {
            let newReport = analyzer.generateReport(sessionId: session.sessionId)
            
            DispatchQueue.main.async {
                report = newReport
                isAnalyzing = false
            }
        }
    }
}

// MARK: - 子组件

struct SessionRow: View {
    let session: SessionStats
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.sessionId)
                .font(.system(size: 12, weight: .medium))
            
            HStack {
                Text(formatDate(session.startTime))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(session.userMessageCount) 消息")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            if session.errorCount > 0 {
                Text("⚠️ \(session.errorCount) 错误")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

struct EventRow: View {
    let event: ConversationEvent
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 时间戳
            Text(formatTime(event.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            
            // 类型图标
            Image(systemName: iconForEvent(event.type))
                .font(.system(size: 12))
                .foregroundColor(colorForEvent(event.type))
                .frame(width: 20)
            
            // 内容
            VStack(alignment: .leading, spacing: 4) {
                Text(titleForEvent(event))
                    .font(.system(size: 12, weight: .medium))
                
                if let input = event.input, !input.isEmpty {
                    Text("输入: \(input)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                if let response = event.response, !response.isEmpty {
                    Text("响应: \(response.prefix(100))...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                if let duration = event.duration {
                    Text("⏱️ \(String(format: "%.2f", duration))s")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                }
                
                if let error = event.error {
                    Text("❌ \(error)")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .background(backgroundForEvent(event.type))
        .cornerRadius(4)
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
    
    private func iconForEvent(_ type: ConversationEventType) -> String {
        switch type {
        case .userInput: return "person.fill"
        case .systemResponse: return "bubble.left.fill"
        case .agentSwitch: return "arrow.left.arrow.right"
        case .skillExecuted: return "bolt.fill"
        case .skillDetected: return "magnifyingglass"
        case .agentSuggested: return "lightbulb"
        case .agentMentioned: return "at"
        case .skillCommanded: return "slash"
        case .capabilityGap: return "exclamationmark.triangle"
        case .agentCreation: return "person.badge.plus"
        case .error: return "xmark.octagon"
        case .performance: return "stopwatch"
        }
    }
    
    private func colorForEvent(_ type: ConversationEventType) -> Color {
        switch type {
        case .userInput: return .blue
        case .systemResponse: return .green
        case .agentSwitch: return .orange
        case .skillExecuted: return .purple
        case .skillDetected: return .yellow
        case .agentSuggested: return .cyan
        case .agentMentioned: return .pink
        case .skillCommanded: return .indigo
        case .capabilityGap: return .red
        case .agentCreation: return .teal
        case .error: return .red
        case .performance: return .gray
        }
    }
    
    private func backgroundForEvent(_ type: ConversationEventType) -> Color {
        switch type {
        case .error: return Color.red.opacity(0.1)
        case .agentSwitch: return Color.orange.opacity(0.05)
        default: return Color.clear
        }
    }
    
    private func titleForEvent(_ event: ConversationEvent) -> String {
        switch event.type {
        case .userInput:
            return "用户输入"
        case .systemResponse:
            return event.agentName != nil ? "\(event.agentName!) 响应" : "系统响应"
        case .agentSwitch:
            return "Agent 切换"
        case .skillExecuted:
            return "执行 Skill: \(event.skillName ?? "")"
        case .skillDetected:
            return "检测到 Skill 意图"
        case .agentSuggested:
            return "建议 Agent"
        case .agentMentioned:
            return "@Agent: \(event.metadata?["agent"] ?? "")"
        case .skillCommanded:
            return "/Skill: \(event.metadata?["skill"] ?? "")"
        case .capabilityGap:
            return "能力缺口: \(event.metadata?["missing_capability"] ?? "")"
        case .agentCreation:
            return "创建 Agent: \(event.agentName ?? "")"
        case .error:
            return "错误"
        case .performance:
            return "性能: \(event.metadata?["operation"] ?? "")"
        }
    }
}

struct SummarySection: View {
    let report: AnalysisReport
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("会话摘要")
                .font(.system(size: 14, weight: .bold))
            
            Text(report.summary)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            // 问题统计
            HStack(spacing: 16) {
                IssueBadge(count: report.criticalIssues.count, label: "严重", color: .red)
                IssueBadge(count: report.majorIssues.count, label: "重要", color: .orange)
                IssueBadge(count: report.minorIssues.count, label: "轻微", color: .yellow)
                IssueBadge(count: report.suggestions.count, label: "建议", color: .blue)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

struct MetricsSection: View {
    let metrics: UXMetrics
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("体验指标")
                .font(.system(size: 14, weight: .bold))
            
            VStack(spacing: 8) {
                MetricRow(label: "总交互轮数", value: "\(metrics.totalTurns)")
                MetricRow(label: "成功率", value: "\(Int(metrics.successRate * 100))%", 
                         valueColor: metrics.successRate > 0.8 ? .green : .orange)
                MetricRow(label: "平均响应时间", value: "\(String(format: "%.2f", metrics.avgResponseTime))s",
                         valueColor: metrics.avgResponseTime < 2 ? .green : .orange)
                MetricRow(label: "Agent 切换次数", value: "\(metrics.agentSwitchCount)")
                MetricRow(label: "确认提示次数", value: "\(metrics.confirmationCount)")
                MetricRow(label: "用户确认率", value: "\(Int(metrics.userConfirmationRate * 100))%")
                MetricRow(label: "Skill 成功率", value: "\(Int(metrics.skillExecutionSuccessRate * 100))%",
                         valueColor: metrics.skillExecutionSuccessRate > 0.8 ? .green : .red)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(valueColor)
        }
    }
}

struct IssuesSection: View {
    let title: String
    let issues: [ConversationIssue]
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(title) (\(issues.count))")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(color)
            
            ForEach(issues) { issue in
                IssueCard(issue: issue)
            }
        }
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct IssueCard: View {
    let issue: ConversationIssue
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(issue.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(issue.category)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }
            
            Text(issue.description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("💡 建议:")
                        .font(.system(size: 11, weight: .medium))
                    Text(issue.suggestion)
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.white.opacity(0.5))
        .cornerRadius(6)
        .onTapGesture {
            isExpanded.toggle()
        }
    }
}

struct IssueBadge: View {
    let count: Int
    let label: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(label): \(count)")
                .font(.system(size: 11))
        }
    }
}

// MARK: - 扩展

extension UXMetrics {
    var successRate: Double {
        totalTurns > 0 ? Double(successfulTurns) / Double(totalTurns) : 0
    }
}

#Preview {
    ConversationAnalyzerView()
}
