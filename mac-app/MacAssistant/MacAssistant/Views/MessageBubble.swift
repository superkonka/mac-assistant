//
//  MessageBubble.swift
//  MacAssistant
//
//  深度优化的消息气泡组件
//

import SwiftUI

struct MessageBubble: View, Equatable {
    let message: ChatMessage
    var availableWidth: CGFloat? = nil
    var taskSession: AgentTaskSession? = nil
    var onToggleTaskSession: (() -> Void)? = nil
    var onResumeTaskSession: (() -> Void)? = nil
    @State private var showCopied = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message &&
        lhs.taskSession == rhs.taskSession &&
        lhs.availableWidth == rhs.availableWidth
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 60)
            }
            
            // 消息容器
            HStack(alignment: .top, spacing: 8) {
                // AI 头像（左侧）
                if message.role != .user {
                    avatarView
                }
                
                // 消息内容区
                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                    // 头部：名称和时间
                    HStack(spacing: 6) {
                        if message.role == .user {
                            Spacer()
                        }
                        
                        Text(message.role == .user ? "你" : "AI 助手")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(nameColor)
                        
                        Text(formattedTime)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))

                        if taskSession == nil && message.role != .user {
                            copyButton
                        }

                        if message.role != .user {
                            Spacer()
                        }
                    }
                    
                    // 气泡主体
                    messageContent
                        .background(
                            BubbleShape(isUser: message.role == .user)
                                .fill(bubbleBackground)
                                .shadow(
                                    color: shadowColor,
                                    radius: message.role == .user ? 2 : 4,
                                    x: 0,
                                    y: message.role == .user ? 1 : 2
                                )
                        )
                        .overlay(
                            BubbleShape(isUser: message.role == .user)
                                .stroke(borderColor, lineWidth: 0.5)
                        )
                }
                
                // 用户头像（右侧）
                if message.role == .user {
                    avatarView
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            
            if message.role != .user {
                Spacer(minLength: 60)
            }
        }
        .contextMenu {
            if taskSession == nil {
                Button("复制") {
                    copyToClipboard()
                }
            }
        }
    }
    
    // MARK: - 子视图
    
    /// 头像视图
    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(avatarBackground)
                .frame(width: 32, height: 32)
            
            Image(systemName: avatarIcon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(avatarForeground)
        }
    }
    
    /// 消息内容（支持富文本）
    private var messageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let taskSession {
                TaskSessionCardView(
                    session: taskSession,
                    onToggle: onToggleTaskSession,
                    onResume: onResumeTaskSession
                )
                .padding(8)
            } else {
                RichTextView(text: message.content)
                    .equatable()
                    .padding(.horizontal, message.role == .user ? 14 : 16)
                    .padding(.vertical, message.role == .user ? 10 : 12)
            }
        }
        .frame(
            maxWidth: bubbleMaxWidth,
            alignment: .leading
        )
        .overlay(
            // 复制按钮（悬停时显示）
            copyOverlay,
            alignment: .topTrailing
        )
    }
    
    /// 复制按钮覆盖层
    @ViewBuilder
    private var copyOverlay: some View {
        EmptyView()
    }

    private var copyButton: some View {
        Button(action: copyToClipboard) {
            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(showCopied ? .green : .secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - 样式属性
    
    private var nameColor: Color {
        message.role == .user ? Color.blue.opacity(0.8) : Color.green.opacity(0.8)
    }
    
    private var bubbleBackground: Color {
        if message.role == .user {
            return AppColors.userMessageBackground
        } else {
            return AppColors.assistantMessageBackground
        }
    }
    
    private var borderColor: Color {
        message.role == .user ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15)
    }
    
    private var shadowColor: Color {
        message.role == .user ? Color.blue.opacity(0.05) : Color.black.opacity(0.05)
    }
    
    private var avatarBackground: Color {
        message.role == .user ? Color.blue.opacity(0.15) : Color.green.opacity(0.15)
    }
    
    private var avatarForeground: Color {
        message.role == .user ? .blue : .green
    }
    
    private var avatarIcon: String {
        message.role == .user ? "person.fill" : "cpu"
    }

    private var bubbleMaxWidth: CGFloat {
        let fallbackWidth: CGFloat
        if taskSession != nil {
            fallbackWidth = 460
        } else {
            fallbackWidth = message.role == .user ? 400 : 500
        }

        guard let availableWidth else {
            return fallbackWidth
        }

        let safeAvailableWidth = max(availableWidth, 320)
        let reservedChrome: CGFloat = message.role == .user ? 150 : 170
        let preferredFraction: CGFloat
        let hardCap: CGFloat

        if taskSession != nil {
            preferredFraction = 0.8
            hardCap = 980
        } else if message.role == .user {
            preferredFraction = 0.72
            hardCap = 780
        } else {
            preferredFraction = 0.84
            hardCap = 980
        }

        let safeWidth = max(safeAvailableWidth - reservedChrome, 280)
        let preferredWidth = safeAvailableWidth * preferredFraction
        return min(safeWidth, preferredWidth, hardCap)
    }
    
    private var formattedTime: String {
        Self.timeFormatter.string(from: message.timestamp)
    }
    
    // MARK: - 操作
    
    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        
        showCopied = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }
}

// MARK: - 气泡形状

struct BubbleShape: Shape {
    let isUser: Bool
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cornerRadius: CGFloat = 16
        let tailSize: CGFloat = 8
        
        if isUser {
            // 用户气泡：右侧有小尾巴
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY),
                              control: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - cornerRadius - tailSize, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - tailSize, y: rect.minY + cornerRadius),
                              control: CGPoint(x: rect.maxX - tailSize, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - tailSize, y: rect.maxY - cornerRadius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - tailSize - 4, y: rect.maxY - 4))
            path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius),
                              control: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            // AI 气泡：左侧有小尾巴
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY + cornerRadius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY),
                              control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + cornerRadius + tailSize, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.minX + tailSize, y: rect.minY + cornerRadius),
                              control: CGPoint(x: rect.minX + tailSize, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + tailSize, y: rect.maxY - cornerRadius))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY),
                              control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + tailSize + 4, y: rect.maxY - 4))
            path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        
        path.closeSubpath()
        return path
    }
}
