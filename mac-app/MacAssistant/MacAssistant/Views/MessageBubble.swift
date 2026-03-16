//
//  MessageBubble.swift
//  MacAssistant
//
//  深度优化的消息气泡组件 - v2.0
//

import SwiftUI

struct MessageBubble: View, Equatable {
    let message: ChatMessage
    var availableWidth: CGFloat? = nil
    var taskSession: AgentTaskSession? = nil
    var detectedSkillSuggestion: DetectedSkillSuggestion? = nil
    var onToggleTaskSession: (() -> Void)? = nil
    var onResumeTaskSession: (() -> Void)? = nil
    var onDetectedSkillSuggestionAction: ((DetectedSkillSuggestionAction) -> Void)? = nil
    @State private var showCopied = false
    @State private var isHovered = false
    @State private var showFullContent = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM月dd日 HH:mm"
        return formatter
    }()

    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message &&
        lhs.taskSession == rhs.taskSession &&
        lhs.detectedSkillSuggestion == rhs.detectedSkillSuggestion &&
        lhs.availableWidth == rhs.availableWidth
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 40)
            }
            
            HStack(alignment: .top, spacing: 10) {
                // AI 头像（左侧）
                if message.role != .user {
                    avatarView
                }
                
                // 消息内容区
                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                    // 头部信息：名称和时间
                    headerView
                    
                    // 气泡主体
                    messageContent
                        .background(
                            BubbleShape(isUser: message.role == .user)
                                .fill(bubbleBackground)
                                .shadow(
                                    color: shadowColor,
                                    radius: message.role == .user ? 1 : 2,
                                    x: 0,
                                    y: message.role == .user ? 0.5 : 1
                                )
                        )
                        .overlay(
                            BubbleShape(isUser: message.role == .user)
                                .stroke(borderColor, lineWidth: 0.5)
                        )
                    
                    // 底部状态栏（仅AI消息）
                    if message.role != .user {
                        footerView
                    }
                }
                
                // 用户头像（右侧）
                if message.role == .user {
                    avatarView
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            
            if message.role != .user {
                Spacer(minLength: 40)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            contextMenuContent
        }
    }
    
    // MARK: - 子视图
    
    /// 头像视图
    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(avatarBackground)
                .frame(width: 36, height: 36)
            
            Image(systemName: avatarIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(avatarForeground)
        }
        .overlay(
            // 在线状态指示器
            Circle()
                .fill(message.role == .user ? Color.clear : Color.green)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .offset(x: 12, y: 12)
                .opacity(message.role == .user ? 0 : 1)
        )
    }
    
    /// 头部视图（名称和时间）
    private var headerView: some View {
        HStack(spacing: 6) {
            if message.role == .user {
                Spacer()
            }
            
            // 发送者名称
            Text(senderName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(nameColor)
            
            // 时间戳
            Text(formattedTime)
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.6))
            
            // 编辑标记
            if message.metadata?["edited"] == "true" {
                Text("(已编辑)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            
            if message.role != .user {
                Spacer()
            }
        }
        .padding(.horizontal, 4)
    }
    
    /// 消息内容区域
    private var messageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let taskSession {
                TaskSessionCardView(
                    session: taskSession,
                    onToggle: onToggleTaskSession,
                    onResume: onResumeTaskSession
                )
                .padding(8)
            } else if let detectedSkillSuggestion {
                DetectedSkillSuggestionCardView(
                    suggestion: detectedSkillSuggestion,
                    onAction: onDetectedSkillSuggestionAction
                )
                .padding(8)
            } else {
                // 根据内容长度选择渲染方式
                contentView
            }
        }
        .frame(
            maxWidth: bubbleMaxWidth,
            alignment: .leading
        )
    }
    
    /// 内容视图（根据长度优化）
    @ViewBuilder
    private var contentView: some View {
        let content = message.content
        let isLongContent = content.count > 3000
        let isVeryLongContent = content.count > 8000
        
        if isVeryLongContent {
            // 超长内容：折叠显示
            VStack(alignment: .leading, spacing: 8) {
                Text(showFullContent ? content : String(content.prefix(2000)))
                    .font(.system(size: 14))
                    .lineLimit(showFullContent ? nil : 30)
                    .padding(.horizontal, message.role == .user ? 14 : 16)
                    .padding(.vertical, message.role == .user ? 10 : 12)
                
                Button(action: { showFullContent.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: showFullContent ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                        Text(showFullContent ? "收起内容" : "展开全部 (还有 \(content.count - 2000) 字符)")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.blue)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .buttonStyle(PlainButtonStyle())
            }
        } else if isLongContent {
            // 长内容：简化渲染
            Text(content)
                .font(.system(size: 14))
                .lineLimit(40)
                .padding(.horizontal, message.role == .user ? 14 : 16)
                .padding(.vertical, message.role == .user ? 10 : 12)
        } else {
            // 正常内容：富文本渲染
            RichTextView(
                text: content,
                availableWidth: richContentWidth
            )
                .equatable()
                .padding(.horizontal, message.role == .user ? 14 : 16)
                .padding(.vertical, message.role == .user ? 10 : 12)
        }
    }
    
    /// 底部视图（状态栏）
    private var footerView: some View {
        HStack(spacing: 8) {
            if isHovered {
                Button(action: copyToClipboard) {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(showCopied ? .green : .secondary)
                }
                .buttonStyle(PlainButtonStyle())
                
                Button(action: {}) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("引用回复")
                
                Spacer()
            }
            
            // 复制成功提示
            if showCopied {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text("已复制")
                        .font(.system(size: 10))
                }
                .foregroundColor(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.1))
                .cornerRadius(4)
            }
        }
        .frame(height: 20)
        .padding(.horizontal, 4)
    }
    
    /// 上下文菜单
    private var contextMenuContent: some View {
        Group {
            Button("复制文本") {
                copyToClipboard()
            }
            
            Button("引用回复") {
                // TODO: 实现引用回复
            }
            
            Divider()
            
            if message.role == .user {
                Button("编辑消息") {
                    // TODO: 实现编辑
                }
            }
            
            Button("删除消息") {
                // TODO: 实现删除
            }
        }
    }
    
    // MARK: - 计算属性
    
    private var senderName: String {
        if message.role == .user {
            return message.agentName ?? "你"
        } else {
            return message.agentName ?? "AI 助手"
        }
    }
    
    private var nameColor: Color {
        if message.role == .user {
            return Color.blue.opacity(0.9)
        } else {
            // 根据 agent 名称生成不同的颜色
            let colors: [Color] = [.green, .purple, .orange, .pink, .teal]
            let hash = abs(message.agentName?.hashValue ?? 0)
            return colors[hash % colors.count].opacity(0.9)
        }
    }
    
    private var bubbleBackground: Color {
        if message.role == .user {
            return Color.blue.opacity(0.08)
        } else {
            return Color(NSColor.controlBackgroundColor)
        }
    }
    
    private var borderColor: Color {
        if message.role == .user {
            return Color.blue.opacity(0.2)
        } else {
            return Color.gray.opacity(0.2)
        }
    }
    
    private var shadowColor: Color {
        if message.role == .user {
            return Color.blue.opacity(0.05)
        } else {
            return Color.black.opacity(0.08)
        }
    }
    
    private var avatarBackground: Color {
        if message.role == .user {
            return Color.blue.opacity(0.15)
        } else {
            return nameColor.opacity(0.15)
        }
    }
    
    private var avatarForeground: Color {
        if message.role == .user {
            return .blue
        } else {
            return nameColor
        }
    }
    
    private var avatarIcon: String {
        if message.role == .user {
            return "person.fill"
        } else {
            // 根据 agent 名称返回不同图标
            let name = message.agentName?.lowercased() ?? ""
            if name.contains("code") || name.contains("程序") {
                return "chevron.left.forwardslash.chevron.right"
            } else if name.contains("write") || name.contains("写作") {
                return "text.quote"
            } else if name.contains("search") || name.contains("搜索") {
                return "magnifyingglass"
            } else if name.contains("shell") || name.contains("终端") {
                return "terminal.fill"
            }
            return "bubble.fill"
        }
    }

    private var bubbleMaxWidth: CGFloat {
        let fallbackWidth: CGFloat = message.role == .user ? 380 : 520
        
        guard let availableWidth else {
            return fallbackWidth
        }
        
        let safeAvailableWidth = max(availableWidth, 320)
        let reservedChrome: CGFloat = message.role == .user ? 140 : 160
        
        let safeWidth = max(safeAvailableWidth - reservedChrome, 260)
        let preferredWidth = safeAvailableWidth * (message.role == .user ? 0.7 : 0.75)
        let hardCap: CGFloat = message.role == .user ? 600 : 720
        
        return min(safeWidth, preferredWidth, hardCap)
    }

    private var richContentWidth: CGFloat {
        let horizontalPadding: CGFloat = message.role == .user ? 28 : 32
        return max(bubbleMaxWidth - horizontalPadding, 220)
    }
    
    private var formattedTime: String {
        let calendar = Calendar.current
        let now = Date()
        
        if calendar.isDateInToday(message.timestamp) {
            return Self.timeFormatter.string(from: message.timestamp)
        } else if calendar.isDateInYesterday(message.timestamp) {
            return "昨天 " + Self.timeFormatter.string(from: message.timestamp)
        } else {
            return Self.dateFormatter.string(from: message.timestamp)
        }
    }
    
    // MARK: - 操作
    
    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        
        withAnimation(.easeInOut(duration: 0.2)) {
            showCopied = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopied = false
            }
        }
    }
}

// MARK: - 气泡形状

struct BubbleShape: Shape {
    let isUser: Bool
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r: CGFloat = 14
        let tailW: CGFloat = 8
        let tailH: CGFloat = 12
        let tailY: CGFloat = rect.minY + 18
        
        if isUser {
            let bubbleRight = rect.maxX - tailW

            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: bubbleRight - r, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: bubbleRight, y: rect.minY + r),
                control: CGPoint(x: bubbleRight, y: rect.minY)
            )
            // 右侧小尾巴
            path.addCurve(
                to: CGPoint(x: rect.maxX - 2, y: tailY),
                control1: CGPoint(x: bubbleRight + tailW * 0.2, y: rect.minY + r),
                control2: CGPoint(x: rect.maxX - tailW * 0.3, y: tailY - tailH * 0.4)
            )
            path.addQuadCurve(
                to: CGPoint(x: bubbleRight, y: tailY + tailH - 2),
                control: CGPoint(x: rect.maxX - 2, y: tailY + tailH * 0.3)
            )
            path.addLine(to: CGPoint(x: bubbleRight, y: rect.maxY - r))
            path.addQuadCurve(
                to: CGPoint(x: bubbleRight - r, y: rect.maxY),
                control: CGPoint(x: bubbleRight, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - r),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + r, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        } else {
            let bubbleLeft = rect.minX + tailW

            path.move(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addLine(to: CGPoint(x: bubbleLeft + r, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: bubbleLeft, y: rect.minY + r),
                control: CGPoint(x: bubbleLeft, y: rect.minY)
            )
            // 左侧小尾巴
            path.addCurve(
                to: CGPoint(x: rect.minX + 2, y: tailY),
                control1: CGPoint(x: bubbleLeft - tailW * 0.2, y: rect.minY + r),
                control2: CGPoint(x: rect.minX + tailW * 0.3, y: tailY - tailH * 0.4)
            )
            path.addQuadCurve(
                to: CGPoint(x: bubbleLeft, y: tailY + tailH - 2),
                control: CGPoint(x: rect.minX + 2, y: tailY + tailH * 0.3)
            )
            path.addLine(to: CGPoint(x: bubbleLeft, y: rect.maxY - r))
            path.addQuadCurve(
                to: CGPoint(x: bubbleLeft + r, y: rect.maxY),
                control: CGPoint(x: bubbleLeft, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY - r),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - r, y: rect.minY),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
        }
        
        path.closeSubpath()
        return path
    }
}

// MARK: - 预览

#Preview {
    VStack(spacing: 20) {
        MessageBubble(
            message: ChatMessage(
                role: .assistant,
                content: "你好！我是 AI 助手，很高兴为你服务。有什么我可以帮助你的吗？",
                agentName: "智能助手"
            ),
            availableWidth: 600
        )
        
        MessageBubble(
            message: ChatMessage(
                role: .user,
                content: "请帮我写一个 Swift 函数，用来计算斐波那契数列。",
                agentName: "用户"
            ),
            availableWidth: 600
        )
    }
    .padding()
    .frame(width: 700)
}
