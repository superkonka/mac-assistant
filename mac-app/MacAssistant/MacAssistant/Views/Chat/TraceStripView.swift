//
//  TraceStripView.swift
//  MacAssistant
//

import SwiftUI

struct TraceStripView: View, Equatable {
    let trace: ExecutionTrace
    var availableWidth: CGFloat? = nil

    static func == (lhs: TraceStripView, rhs: TraceStripView) -> Bool {
        lhs.trace == rhs.trace && lhs.availableWidth == rhs.availableWidth
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            contentCard
                .frame(maxWidth: cardMaxWidth, alignment: .leading)

            Spacer(minLength: 60)
        }
        .padding(.leading, 52)
        .padding(.trailing, 72)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var contentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            topRow
            titleBlock
            liveStatusBlock
            progressBlock
            chips
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var topRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Group {
                    if trace.state.isActive {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: trace.state.symbolName)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 12, height: 12)
                    }
                }
                .foregroundColor(accentColor)

                Text(statusLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(accentColor)
            }

            if let transitionLabel = trace.transitionLabel, !transitionLabel.isEmpty {
                statusPill(
                    label: transitionLabel,
                    accent: .orange.opacity(0.78),
                    textColor: .orange.opacity(0.95)
                )
            }

            Spacer(minLength: 8)

            ElapsedTimeView(trace: trace)
            
            // 日志入口按钮
            ExecutionLogButton(sessionID: trace.id.uuidString)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.primary.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            Text(detail)
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let nextStep {
                Text(nextStep)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(accentColor.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var liveStatusBlock: some View {
        TraceTickerView(
            entries: liveStatusEntries,
            accentColor: accentColor,
            isActive: trace.state.isActive
        )
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(progressLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.secondary)

                Spacer(minLength: 8)

                if trace.state.isActive {
                    Text("处理中")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(accentColor.opacity(0.92))
                }
            }

            HStack(spacing: 6) {
                ForEach(progressSteps.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule()
                            .fill(colorForStep(at: index))
                            .frame(height: 6)

                        Text(progressSteps[index])
                            .font(.system(size: 10))
                            .foregroundColor(labelColorForStep(at: index))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            TraceChip(label: trace.runtimeName, accent: .gray)
            TraceChip(label: trace.agentName, accent: accentColor.opacity(0.8))
            TraceChip(label: trace.intentName, accent: .blue.opacity(0.65))
        }
    }

    private var headline: String {
        switch trace.state {
        case .routing:
            return "正在为这次请求选择最合适的处理线路"
        case .running:
            return "\(trace.agentName) 正在处理你的请求"
        case .fallback:
            return "\(trace.agentName) 正在接管并继续处理"
        case .synthesizing:
            return "正在把执行结果整理成最终答复"
        case .completed:
            return "结果已经返回到当前对话"
        case .failed:
            return "这次请求没有顺利完成"
        }
    }

    private var detail: String {
        switch trace.state {
        case .routing:
            return trace.summary.isEmpty ? "系统会先判断意图和能力，再决定由哪个 Agent 执行。" : trace.summary
        case .running:
            return trace.summary.isEmpty ? "请求已经提交，正在等待返回第一段有效结果。" : trace.summary
        case .fallback:
            return trace.summary.isEmpty ? "原处理线路不可用，系统正在自动切换到备用 Agent。" : trace.summary
        case .synthesizing:
            return trace.summary.isEmpty ? "子任务已经完成，正在收拢信息并生成适合当前对话的答复。" : trace.summary
        case .completed:
            return trace.summary.isEmpty ? "你现在可以继续追问，或者基于结果发起下一步操作。" : trace.summary
        case .failed:
            return trace.summary.isEmpty ? "你可以直接重试，也可以切换 Agent 后再试一次。" : trace.summary
        }
    }

    private var nextStep: String? {
        switch trace.state {
        case .routing:
            return "下一步：建立会话并把请求发给目标 Agent"
        case .running:
            return "下一步：等待结果流返回并写入聊天气泡"
        case .fallback:
            return "下一步：验证备用线路并自动重试"
        case .synthesizing:
            return "下一步：压缩整理执行结果，生成最终回复"
        case .completed:
            return nil
        case .failed:
            return "下一步：可重试当前请求，或手动切换 Agent"
        }
    }

    private var statusLabel: String {
        switch trace.state {
        case .routing:
            return "路由中"
        case .running:
            return "处理中"
        case .fallback:
            return "自动恢复中"
        case .synthesizing:
            return "整合中"
        case .completed:
            return "已完成"
        case .failed:
            return "处理中断"
        }
    }

    private var progressLabel: String {
        switch trace.state {
        case .completed:
            return "流程完成"
        case .failed:
            return "流程中断"
        default:
            return "阶段 \(currentStepIndex + 1)/\(progressSteps.count)"
        }
    }

    private var liveStatusEntries: [TraceTickerEntry] {
        var entries: [TraceTickerEntry] = []

        if !trace.summary.isEmpty {
            entries.append(
                TraceTickerEntry(
                    symbolName: "text.bubble",
                    text: trace.summary
                )
            )
        }

        switch trace.state {
        case .routing:
            entries.append(
                TraceTickerEntry(
                    symbolName: "arrow.triangle.branch",
                    text: "正在匹配最合适的能力和会话线路。"
                )
            )
            entries.append(
                TraceTickerEntry(
                    symbolName: "person.crop.circle.badge.checkmark",
                    text: "\(trace.agentName) 会作为当前主执行 Agent。"
                )
            )
            entries.append(
                TraceTickerEntry(
                    symbolName: "paperplane",
                    text: "会话建立后，请求会立即发往 \(trace.runtimeName)。"
                )
            )

        case .running:
            entries.append(
                TraceTickerEntry(
                    symbolName: "paperplane",
                    text: "请求已经提交给 \(trace.agentName)，正在等待首段有效结果。"
                )
            )
            entries.append(
                TraceTickerEntry(
                    symbolName: "server.rack",
                    text: "\(trace.runtimeName) 正在保持会话并等待返回。"
                )
            )
            entries.append(
                TraceTickerEntry(
                    symbolName: "bubble.left.and.text.bubble.right",
                    text: "一旦收到流式输出，会直接写回当前聊天气泡。"
                )
            )
            entries.append(
                TraceTickerEntry(
                    symbolName: "arrow.triangle.merge",
                    text: "如果触发工具或子任务，进度会继续在这里更新。"
                )
            )

        case .fallback:
            entries.append(
                TraceTickerEntry(
                    symbolName: "arrow.uturn.left.circle",
                    text: "主线路不可用，系统正在切换到备用 Agent。"
                )
            )
            entries.append(
                TraceTickerEntry(
                    symbolName: "checkmark.shield",
                    text: "切换完成后会自动继续，不需要你重新发送。"
                )
            )

        case .synthesizing:
            entries.append(
                TraceTickerEntry(
                    symbolName: "square.stack.3d.down.right",
                    text: "执行结果已经回流，正在压缩整理成最终答复。"
                )
            )
            entries.append(
                TraceTickerEntry(
                    symbolName: "doc.text.magnifyingglass",
                    text: "系统会优先保留结论、行动项和关键状态。"
                )
            )

        case .completed:
            entries.append(
                TraceTickerEntry(
                    symbolName: "checkmark.circle",
                    text: "结果已经写回主对话，可以继续追问或发下一步指令。"
                )
            )

        case .failed:
            entries.append(
                TraceTickerEntry(
                    symbolName: "exclamationmark.triangle",
                    text: "这次流程中断了，但你可以直接重试或切换 Agent。"
                )
            )
        }

        if let transitionLabel = trace.transitionLabel, !transitionLabel.isEmpty {
            entries.append(
                TraceTickerEntry(
                    symbolName: "point.topleft.down.curvedto.point.bottomright.up",
                    text: "当前切换：\(transitionLabel)"
                )
            )
        }

        return deduplicatedEntries(entries)
    }

    private var progressSteps: [String] {
        ["路由", "执行", "整合", "完成"]
    }

    private var currentStepIndex: Int {
        switch trace.state {
        case .routing:
            return 0
        case .running, .fallback:
            return 1
        case .synthesizing:
            return 2
        case .completed, .failed:
            return 3
        }
    }

    private func colorForStep(at index: Int) -> Color {
        if trace.state == .failed && index == currentStepIndex {
            return Color.orange.opacity(0.65)
        }

        if index < currentStepIndex {
            return accentColor.opacity(0.32)
        }

        if index == currentStepIndex {
            return accentColor.opacity(0.9)
        }

        return Color.gray.opacity(0.12)
    }

    private func labelColorForStep(at index: Int) -> Color {
        if trace.state == .failed && index == currentStepIndex {
            return .orange.opacity(0.95)
        }

        if index <= currentStepIndex {
            return .primary.opacity(index == currentStepIndex ? 0.92 : 0.68)
        }

        return .secondary.opacity(0.72)
    }

    private func deduplicatedEntries(_ entries: [TraceTickerEntry]) -> [TraceTickerEntry] {
        var seen: Set<String> = []
        return entries.filter { entry in
            let normalized = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !seen.contains(normalized) else {
                return false
            }
            seen.insert(normalized)
            return true
        }
    }

    private var cardMaxWidth: CGFloat {
        guard let availableWidth else { return 560 }
        let safeWidth = max(availableWidth, 320)
        return min(max(safeWidth - 170, 320), 820)
    }

    private var accentColor: Color {
        switch trace.state {
        case .routing:
            return .secondary
        case .running:
            return .blue
        case .fallback:
            return .orange
        case .synthesizing:
            return .teal
        case .completed:
            return .green
        case .failed:
            return .orange
        }
    }

    private var backgroundColor: Color {
        switch trace.state {
        case .routing:
            return Color.secondary.opacity(0.06)
        case .running:
            return Color.blue.opacity(0.05)
        case .fallback:
            return Color.orange.opacity(0.07)
        case .synthesizing:
            return Color.teal.opacity(0.06)
        case .completed:
            return Color.green.opacity(0.05)
        case .failed:
            return Color.orange.opacity(0.08)
        }
    }

    private var borderColor: Color {
        switch trace.state {
        case .routing:
            return Color.secondary.opacity(0.18)
        case .running:
            return Color.blue.opacity(0.18)
        case .fallback:
            return Color.orange.opacity(0.22)
        case .synthesizing:
            return Color.teal.opacity(0.2)
        case .completed:
            return Color.green.opacity(0.18)
        case .failed:
            return Color.orange.opacity(0.24)
        }
    }

    private func statusPill(label: String, accent: Color, textColor: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(accent.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .stroke(accent.opacity(0.22), lineWidth: 0.8)
            )
    }
}

private struct TraceTickerEntry: Identifiable, Equatable {
    let id: String
    let symbolName: String
    let text: String

    init(symbolName: String, text: String) {
        self.id = "\(symbolName)|\(text)"
        self.symbolName = symbolName
        self.text = text
    }
}

private struct ElapsedTimeView: View {
    let trace: ExecutionTrace

    var body: some View {
        TimelineView(.periodic(from: trace.startedAt, by: 1)) { context in
            Text(labelText(at: context.date))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.92))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.55))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.gray.opacity(0.14), lineWidth: 0.8)
                )
        }
    }

    private func labelText(at date: Date) -> String {
        let endDate = trace.finishedAt ?? date
        let interval = max(endDate.timeIntervalSince(trace.startedAt), 0)
        let seconds = Int(interval.rounded(.down))

        if seconds < 60 {
            return trace.state.isActive ? "已耗时 \(seconds)s" : "用时 \(seconds)s"
        }

        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return trace.state.isActive
            ? String(format: "已耗时 %d:%02d", minutes, remainingSeconds)
            : String(format: "用时 %d:%02d", minutes, remainingSeconds)
    }
}

private struct TraceChip: View {
    let label: String
    let accent: Color

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.primary.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(accent.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .stroke(accent.opacity(0.18), lineWidth: 0.8)
            )
            .fixedSize(horizontal: true, vertical: true)
    }
}

private struct TraceTickerView: View {
    let entries: [TraceTickerEntry]
    let accentColor: Color
    let isActive: Bool

    @State private var currentIndex = 0
    @State private var isResetting = false

    private let rowHeight: CGFloat = 22
    private let rotationInterval: TimeInterval = 3.2
    private let wrapResetDelay: TimeInterval = 0.34

    private var renderedEntries: [TraceTickerEntry] {
        guard entries.count > 1, let first = entries.first else { return entries }
        return entries + [first]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("实时进展")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)

                if isActive && entries.count > 1 {
                    Text("自动滚动")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(accentColor.opacity(0.92))
                }
            }

            tickerRows
                .frame(height: rowHeight, alignment: .top)
                .clipped()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accentColor.opacity(0.12), lineWidth: 0.8)
        )
        .onAppear {
            currentIndex = 0
        }
        .onReceive(
            Timer.publish(every: rotationInterval, on: .main, in: .common).autoconnect()
        ) { _ in
            advanceTickerIfNeeded()
        }
        .onChange(of: entriesSignature) { _ in
            currentIndex = 0
            isResetting = false
        }
        .onChange(of: isActive) { active in
            if !active {
                currentIndex = 0
                isResetting = false
            }
        }
    }

    private var tickerRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(renderedEntries.enumerated()), id: \.offset) { _, entry in
                row(for: entry)
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            }
        }
        .offset(y: -CGFloat(currentIndex) * rowHeight)
        .transaction { transaction in
            if isResetting {
                transaction.animation = nil
            } else {
                transaction.animation = .spring(response: 0.4, dampingFraction: 0.88)
            }
        }
    }

    private func row(for entry: TraceTickerEntry) -> some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: entry.symbolName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(accentColor.opacity(0.92))
                .frame(width: 12, height: 12)

            Text(entry.text)
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private var entriesSignature: String {
        entries.map(\.id).joined(separator: "\n")
    }

    private func advanceTickerIfNeeded() {
        guard isActive, entries.count > 1, !isResetting else { return }

        let nextIndex = currentIndex + 1
        if nextIndex < renderedEntries.count {
            currentIndex = nextIndex
        }

        guard nextIndex == renderedEntries.count - 1 else { return }
        isResetting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wrapResetDelay) {
            currentIndex = 0
            isResetting = false
        }
    }
}
