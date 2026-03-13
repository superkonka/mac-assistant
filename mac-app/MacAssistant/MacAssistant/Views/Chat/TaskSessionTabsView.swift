import AppKit
import SwiftUI

struct TaskSessionTabsView: View {
    let sessions: [AgentTaskSession]
    let selectedSessionID: String?
    let onToggleSelection: (String) -> Void
    let onDismissSession: (String) -> Void

    @State private var hoveredSessionID: String?
    @State private var isShelfHovered = false

    private var isShelfExpanded: Bool {
        isShelfHovered || hoveredSessionID != nil || selectedSessionID != nil
    }

    private var shelfWidth: CGFloat {
        isShelfExpanded ? 338 : 164
    }

    private var displaySessions: [AgentTaskSession] {
        Array(sessions.prefix(isShelfExpanded ? 8 : 5))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: isShelfExpanded ? 12 : -14) {
            shelfBadge
            shelfCards
        }
        .frame(width: shelfWidth, alignment: .trailing)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isShelfExpanded)
        .onHover { hovering in
            isShelfHovered = hovering
            if !hovering && hoveredSessionID != nil {
                hoveredSessionID = nil
            }
        }
    }

    @ViewBuilder
    private var shelfCards: some View {
        if isShelfExpanded && sessions.count > 5 {
            ScrollView(.vertical, showsIndicators: false) {
                shelfCardRows
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: min(CGFloat(displaySessions.count) * 84 + 12, 500))
        } else {
            shelfCardRows
        }
    }

    private var shelfCardRows: some View {
        VStack(alignment: .trailing, spacing: isShelfExpanded ? 12 : -18) {
            ForEach(Array(displaySessions.enumerated()), id: \.element.id) { index, session in
                TaskSessionTabItem(
                    session: session,
                    stackIndex: index,
                    isSelected: session.id == selectedSessionID,
                    isShelfExpanded: isShelfExpanded,
                    isHovered: hoveredSessionID == session.id,
                    onTap: { onToggleSelection(session.id) },
                    onDismiss: session.status == .completed ? { onDismissSession(session.id) } : nil,
                    onHoverChange: { hovering in
                        hoveredSessionID = hovering ? session.id : (hoveredSessionID == session.id ? nil : hoveredSessionID)
                    }
                )
                .zIndex(hoveredSessionID == session.id ? 3 : (session.id == selectedSessionID ? 2 : Double(displaySessions.count - index)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var shelfBadge: some View {
        HStack(spacing: 8) {
            if isShelfExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    Text("任务悬层")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(shelfSubtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)
            }
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                sessionGlowColor.opacity(0.24),
                                sessionGlowColor.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 24, height: 24)

                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(sessionGlowColor)
            }

            Text("\(sessions.count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(sessionGlowColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(sessionGlowColor.opacity(0.12))
                )

            if runningCount > 0 && isShelfExpanded {
                Text("\(runningCount) 进行中")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.52))
                    )
            }
        }
        .padding(.horizontal, isShelfExpanded ? 14 : 10)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.72), lineWidth: 1)
                )
        )
        .shadow(color: sessionGlowColor.opacity(0.14), radius: 16, y: 8)
        .shadow(color: Color.black.opacity(0.06), radius: 10, y: 4)
    }

    private var runningCount: Int {
        sessions.filter { $0.status == .running }.count
    }

    private var sessionGlowColor: Color {
        sessions.first(where: { $0.status == .running })?.status.taskAccentColor
            ?? sessions.first?.status.taskAccentColor
            ?? .blue
    }

    private var shelfSubtitle: String {
        if runningCount > 0 {
            return "右侧浮层查看后台流转"
        }
        return "悬停展开，点击查看详情"
    }
}

struct TaskSessionInspectorPanel: View {
    let session: AgentTaskSession
    var onClose: (() -> Void)? = nil
    var onResume: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summarySection

                    if session.canResume {
                        actionsSection
                    }

                    detailsGrid
                    requestSection
                    attachmentsSection
                    runtimeSection
                    transcriptSection
                    resultSection
                }
                .padding(16)
            }
            .frame(maxHeight: 380)
        }
        .background(panelBackground)
        .overlay(panelOutline)
        .shadow(color: session.status.taskAccentColor.opacity(0.18), radius: 28, y: 10)
        .shadow(color: Color.black.opacity(0.12), radius: 22, y: 8)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .transition(.move(edge: .top).combined(with: .scale(scale: 0.96)).combined(with: .opacity))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(session.status.taskAccentColor.opacity(0.14))
                    .frame(width: 34, height: 34)

                Image(systemName: session.status.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(session.status.taskAccentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(session.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(1)

                    Text(session.status.displayName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(session.status.taskAccentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(session.status.taskAccentColor.opacity(0.12))
                        )
                }

                Text("更新时间 \(session.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if session.status == .running {
                ProgressView()
                    .controlSize(.small)
            }

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.7))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [
                    session.status.taskAccentColor.opacity(0.06),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("状态摘要")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            Text(session.statusSummary)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(session.status.taskBackgroundColor)
                )
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 10) {
            if let onResume {
                Button(action: onResume) {
                    Text(session.status == .waitingUser ? "重新检查" : "继续处理")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Text(resumeDescription)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var detailsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("任务信息")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 180), spacing: 12, alignment: .top)
                ],
                alignment: .leading,
                spacing: 12
            ) {
                TaskSessionDetailField(title: "任务 ID", value: session.id)
                TaskSessionDetailField(title: "意图", value: session.intentName)
                TaskSessionDetailField(title: "主会话 Agent", value: session.mainAgentName ?? "未记录")
                TaskSessionDetailField(title: "执行 Agent", value: session.delegateAgentName ?? "未记录")
                TaskSessionDetailField(title: "执行 Agent ID", value: session.delegateAgentID ?? "未记录")
                TaskSessionDetailField(title: "创建时间", value: formatted(session.createdAt))
                TaskSessionDetailField(title: "更新时间", value: formatted(session.updatedAt))
                TaskSessionDetailField(title: "主消息 ID", value: session.linkedMainMessageID?.uuidString ?? "未关联")
                TaskSessionDetailField(title: "消息数", value: "\(session.messages.count)")
                TaskSessionDetailField(title: "详情展开状态", value: session.isExpanded ? "已展开" : "已折叠")
                TaskSessionDetailField(title: "可恢复", value: session.canResume ? "是" : "否")
                TaskSessionDetailField(title: "上次回查", value: session.lastReconciledAt.map(formatted) ?? "未回查")
            }
        }
    }

    private var requestSection: some View {
        TaskSessionDetailBlock(
            title: "原始请求",
            content: session.originalRequest
        )
    }

    @ViewBuilder
    private var attachmentsSection: some View {
        let images = session.inputImages ?? []
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("输入附件")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(images, id: \.self) { path in
                        TaskSessionPathRow(path: path)
                    }
                }
            }
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("运行上下文")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 180), spacing: 12, alignment: .top)
                ],
                alignment: .leading,
                spacing: 12
            ) {
                TaskSessionDetailField(title: "Gateway Session Key", value: session.gatewaySessionKey ?? "未记录")
                TaskSessionDetailField(title: "Gateway Run ID", value: session.gatewayRunID ?? "未记录")
                TaskSessionDetailField(title: "Conversation Session ID", value: session.gatewayConversationSessionID ?? "未记录")
                TaskSessionDetailField(title: "请求启动时间", value: session.requestStartedAt.map(formatted) ?? "未记录")
            }

            TaskSessionDetailBlock(
                title: "最近一次 Assistant 输出",
                content: session.latestAssistantText ?? "未记录"
            )
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("任务详情")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            if session.messages.isEmpty {
                Text("当前还没有写入子任务详情。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.03))
                    )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.messages) { message in
                        TaskSessionInspectorMessageRow(message: message)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let resultSummary = session.resultSummary, !resultSummary.isEmpty {
            TaskSessionDetailBlock(
                title: "结果摘要",
                content: resultSummary,
                accent: .green,
                backgroundOpacity: 0.09
            )
        }

        if let errorMessage = session.errorMessage, !errorMessage.isEmpty {
            TaskSessionDetailBlock(
                title: session.status == .failed ? "失败原因" : "状态补充",
                content: errorMessage,
                accent: session.status == .waitingUser ? .yellow : .orange,
                backgroundOpacity: 0.09
            )
        }
    }

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            session.status.taskAccentColor.opacity(0.13),
                            Color.white.opacity(0.7),
                            AppColors.controlBackground.opacity(0.88)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var panelOutline: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [
                        session.status.taskBorderColor.opacity(0.95),
                        Color.white.opacity(0.68)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    private var resumeDescription: String {
        if let lastReconciledAt = session.lastReconciledAt {
            return "上次检查 \(lastReconciledAt.formatted(date: .omitted, time: .shortened))"
        }
        return "本地已保留上下文，可继续回查"
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct TaskSessionTabItem: View {
    let session: AgentTaskSession
    let stackIndex: Int
    let isSelected: Bool
    let isShelfExpanded: Bool
    let isHovered: Bool
    let onTap: () -> Void
    let onDismiss: (() -> Void)?
    let onHoverChange: (Bool) -> Void

    private var isExpanded: Bool {
        isShelfExpanded || isHovered || isSelected
    }

    private var labelWidth: CGFloat {
        isExpanded ? 224 : 94
    }

    private var tileSize: CGFloat {
        isExpanded ? 56 : 46
    }

    private var collapsedOffsetX: CGFloat {
        isExpanded ? 0 : -CGFloat(min(stackIndex, 4)) * 18
    }

    private var collapsedTilt: Double {
        guard !isExpanded else { return 0 }

        switch stackIndex % 3 {
        case 0: return -6
        case 1: return 4
        default: return -3
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    labelBubble
                    previewTile
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.plain)

            if isExpanded, let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.8))
                        )
                }
                .buttonStyle(.plain)
                .help("关闭此已完成任务")
                .offset(x: 8, y: -8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .offset(x: collapsedOffsetX, y: isHovered ? -4 : 0)
        .rotationEffect(.degrees(collapsedTilt))
        .scaleEffect(isSelected ? 1.03 : (isExpanded ? 1.01 : 1))
        .shadow(color: session.status.taskAccentColor.opacity(isSelected ? 0.18 : (isExpanded ? 0.12 : 0.06)), radius: isExpanded ? 18 : 10, y: 8)
        .shadow(color: Color.black.opacity(isExpanded ? 0.09 : 0.05), radius: 14, y: 6)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isExpanded)
        .onHover(perform: onHoverChange)
        .help(session.originalRequest)
    }

    private var labelBubble: some View {
        VStack(alignment: .trailing, spacing: isExpanded ? 6 : 2) {
            HStack(spacing: 8) {
                if isExpanded {
                    Text(session.status.displayName)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundColor(session.status.taskAccentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(session.status.taskAccentColor.opacity(0.12))
                        )
                }

                Text(session.shelfPrimaryText)
                    .font(.system(size: isExpanded ? 12 : 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            if isExpanded {
                Text(session.shelfSecondaryText)
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                HStack(spacing: 6) {
                    ForEach(session.railTags.filter { $0 != session.status.displayName }, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.black.opacity(0.04))
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(session.railKeyword)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundColor(isSelected ? session.status.taskAccentColor : .secondary)
                        .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, isExpanded ? 16 : 14)
        .padding(.vertical, isExpanded ? 12 : 10)
        .frame(width: labelWidth, alignment: .trailing)
        .background(labelBubbleBackground)
        .overlay(labelBubbleOutline)
    }

    private var labelBubbleBackground: some View {
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                session.status.taskAccentColor.opacity(isSelected ? 0.16 : 0.08),
                                Color.white.opacity(isExpanded ? 0.34 : 0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
    }

    private var labelBubbleOutline: some View {
        Capsule(style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [
                        isSelected ? session.status.taskBorderColor : Color.white.opacity(0.72),
                        isSelected ? session.status.taskAccentColor.opacity(0.22) : Color.black.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: isSelected ? 1.2 : 1
            )
    }

    private var previewTile: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    session.status.taskAccentColor.opacity(0.16),
                                    Color.white.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

            if let previewImage = session.previewNSImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: tileSize, height: tileSize)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                VStack(spacing: 3) {
                    Image(systemName: session.status.symbolName)
                        .font(.system(size: isExpanded ? 17 : 15, weight: .semibold))
                        .foregroundColor(session.status.taskAccentColor)

                    if isExpanded {
                        Text(session.railKeyword)
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Group {
                if session.status == .running {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: session.status == .completed ? "checkmark" : session.status.symbolName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .padding(6)
            .background(
                Circle()
                    .fill(session.status.taskAccentColor.opacity(0.92))
            )
            .offset(x: 5, y: 5)
        }
        .frame(width: tileSize, height: tileSize)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
        )
    }
}

private struct TaskSessionMarqueeText: View {
    let text: String

    private let fontSize: CGFloat = 10.5
    private let gap: CGFloat = 24
    private let speed: CGFloat = 26

    var body: some View {
        GeometryReader { proxy in
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let textWidth = measuredWidth(using: font)

            if textWidth <= proxy.size.width {
                Text(text)
                    .font(.system(size: fontSize))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let cycle = textWidth + gap
                    let elapsed = CGFloat(context.date.timeIntervalSinceReferenceDate) * speed
                    let offset = elapsed.truncatingRemainder(dividingBy: cycle)

                    HStack(spacing: gap) {
                        marqueeLabel
                        marqueeLabel
                    }
                    .offset(x: -offset)
                }
            }
        }
        .frame(height: 14)
        .clipped()
    }

    private var marqueeLabel: some View {
        Text(text)
            .font(.system(size: fontSize))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func measuredWidth(using font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

private extension AgentTaskSession {
    var shelfPrimaryText: String {
        let titleCandidate = title
            .replacingOccurrences(of: "·", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !titleCandidate.isEmpty {
            return titleCandidate
        }

        return railKeyword
    }

    var shelfSecondaryText: String {
        let candidates = [
            resultSummary ?? "",
            latestAssistantText ?? "",
            errorMessage ?? "",
            statusSummary,
            originalRequest
        ]

        for candidate in candidates {
            let compact = candidate
                .replacingOccurrences(of: "\n", with: "  ·  ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !compact.isEmpty {
                return compact
            }
        }

        return "点击查看任务详情"
    }

    var previewNSImage: NSImage? {
        guard let firstPath = inputImages?.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) else {
            return nil
        }

        return NSImage(contentsOfFile: firstPath)
    }

    var railKeyword: String {
        let candidates = [
            intentName,
            delegateAgentName ?? "",
            title,
            originalRequest
        ]

        for candidate in candidates {
            let compact = sanitizedRailToken(from: candidate)
            if compact.count >= 2 {
                return String(compact.prefix(min(3, compact.count)))
            }
        }

        return "任务"
    }

    var railTags: [String] {
        var tags: [String] = [status.displayName]

        if !intentName.isEmpty {
            tags.append(intentName)
        }

        if let delegateAgentName, !delegateAgentName.isEmpty {
            tags.append(delegateAgentName)
        }

        let requestKeyword = sanitizedRailToken(from: originalRequest)
        if requestKeyword.count >= 2 {
            tags.append(String(requestKeyword.prefix(min(6, requestKeyword.count))))
        }

        var unique: [String] = []
        for tag in tags where !tag.isEmpty && !unique.contains(tag) {
            unique.append(tag)
        }
        return Array(unique.prefix(3))
    }

    var railPreviewLine: String {
        let previewSource = latestAssistantText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? latestAssistantText ?? ""
            : originalRequest

        return previewSource
            .replacingOccurrences(of: "\n", with: "  ·  ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizedRailToken(from source: String) -> String {
        source
            .replacingOccurrences(of: "子会话", with: "")
            .replacingOccurrences(of: "独立处理", with: "")
            .replacingOccurrences(of: "业务工作流设计", with: "工作流")
            .filter { character in
                if character.isWhitespace || character.isNewline {
                    return false
                }
                return !character.unicodeScalars.allSatisfy {
                    CharacterSet.punctuationCharacters.contains($0) ||
                    CharacterSet.symbols.contains($0)
                }
            }
    }
}

private struct TaskSessionDetailField: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.03))
        )
    }
}

private struct TaskSessionDetailBlock: View {
    let title: String
    let content: String
    var accent: Color = .secondary
    var backgroundOpacity: Double = 0.06

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent)

            Text(content)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(accent.opacity(backgroundOpacity))
                )
        }
    }
}

private struct TaskSessionInspectorMessageRow: View {
    let message: TaskSessionMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(roleTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(roleColor)

                if let agentName = message.agentName, !agentName.isEmpty {
                    Text(agentName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Text(message.content)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.03))
        )
    }

    private var roleTitle: String {
        switch message.role {
        case .user:
            return "请求"
        case .assistant:
            return "执行"
        case .system:
            return "状态"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .user:
            return .blue
        case .assistant:
            return .green
        case .system:
            return .secondary
        }
    }
}

private struct TaskSessionPathRow: View {
    let path: String

    var body: some View {
        Text(path)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.primary)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.03))
            )
    }
}

private extension TaskSessionStatus {
    var taskAccentColor: Color {
        switch self {
        case .queued:
            return .secondary
        case .running:
            return .blue
        case .partial:
            return .teal
        case .waitingUser:
            return .yellow
        case .completed:
            return .green
        case .failed:
            return .orange
        }
    }

    var taskBackgroundColor: Color {
        switch self {
        case .queued:
            return Color.gray.opacity(0.08)
        case .running:
            return Color.blue.opacity(0.09)
        case .partial:
            return Color.teal.opacity(0.1)
        case .waitingUser:
            return Color.yellow.opacity(0.12)
        case .completed:
            return Color.green.opacity(0.09)
        case .failed:
            return Color.orange.opacity(0.12)
        }
    }

    var taskBorderColor: Color {
        switch self {
        case .queued:
            return Color.gray.opacity(0.22)
        case .running:
            return Color.blue.opacity(0.28)
        case .partial:
            return Color.teal.opacity(0.3)
        case .waitingUser:
            return Color.yellow.opacity(0.34)
        case .completed:
            return Color.green.opacity(0.26)
        case .failed:
            return Color.orange.opacity(0.32)
        }
    }
}
